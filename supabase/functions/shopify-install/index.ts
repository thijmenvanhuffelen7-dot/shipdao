// Starts the Shopify install for the signed-in client.
// POST { shop: "mystore.myshopify.com" }  ->  { url }  (redirect the browser to url)
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

const SCOPES = "read_orders,read_products,read_merchant_managed_fulfillment_orders,write_merchant_managed_fulfillment_orders";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  const apiKey = Deno.env.get("SHOPIFY_API_KEY");
  if (!apiKey || !Deno.env.get("SHOPIFY_API_SECRET")) return json({ error: "Shopify app is not configured yet (SHOPIFY_API_KEY / SHOPIFY_API_SECRET missing)." }, 500);
  if (!Deno.env.get("APP_URL")) return json({ error: "APP_URL secret is missing (the address of your portal)." }, 500);

  const { shop } = await req.json().catch(() => ({ shop: "" }));
  const domain = String(shop ?? "").trim().toLowerCase().replace(/^https?:\/\//, "").replace(/\/.*$/, "");
  if (!/^[a-z0-9][a-z0-9-]*\.myshopify\.com$/.test(domain)) return json({ error: "Use your .myshopify.com address" }, 400);

  const userClient = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } },
  });
  const { data: state, error } = await userClient.rpc("create_shopify_state", { p_shop: domain });
  if (error) return json({ error: error.message }, 400);

  const redirectUri = `${Deno.env.get("SUPABASE_URL")}/functions/v1/shopify-callback`;
  const url = `https://${domain}/admin/oauth/authorize?client_id=${encodeURIComponent(apiKey)}` +
    `&scope=${encodeURIComponent(SCOPES)}&redirect_uri=${encodeURIComponent(redirectUri)}&state=${state}`;
  return json({ url });
});
