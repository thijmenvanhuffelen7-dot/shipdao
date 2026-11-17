// Manual Shopify connection, for stores that created their own app in the Shopify admin
// (Settings -> Apps -> Develop apps -> Build apps in Dev Dashboard). No Shopify app review needed.
// POST { shop, client_id, client_secret }  (logged-in client)
// Gets a token with the client credentials grant, stores the store, registers webhooks and imports products.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";

const API_VERSION = Deno.env.get("SHOPIFY_API_VERSION") ?? "2026-10";
const NEEDED = ["read_orders", "read_products", "write_merchant_managed_fulfillment_orders"];
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);
  const supabaseUrl = Deno.env.get("SUPABASE_URL")!, serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

  const userClient = createClient(supabaseUrl, Deno.env.get("SUPABASE_ANON_KEY")!, { global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } } });
  const { data: clientId } = await userClient.rpc("my_client_id");
  if (!clientId) return json({ error: "Log in with your store account first." }, 401);

  const body = await req.json().catch(() => ({}));
  let shop = String(body.shop ?? "").trim().toLowerCase().replace(/^https?:\/\//, "").replace(/\/.*$/, "");
  if (shop && !shop.includes(".")) shop += ".myshopify.com";
  const appId = String(body.client_id ?? "").trim(), appSecret = String(body.client_secret ?? "").trim();
  if (!/^[a-z0-9][a-z0-9-]*\.myshopify\.com$/.test(shop)) return json({ error: "Use your .myshopify.com address, e.g. yourstore.myshopify.com" }, 400);
  if (!/^[A-Za-z0-9_-]{16,128}$/.test(appId)) return json({ error: "That Client ID does not look right. Copy it from your app's Settings in the Dev Dashboard." }, 400);
  if (appSecret.length < 16 || appSecret.length > 256) return json({ error: "That Client secret does not look right. Copy it from your app's Settings in the Dev Dashboard." }, 400);

  // 1. token (client credentials grant)
  const tr = await fetch(`https://${shop}/admin/oauth/access_token`, {
    method: "POST", headers: { "Content-Type": "application/x-www-form-urlencoded", Accept: "application/json" },
    body: new URLSearchParams({ grant_type: "client_credentials", client_id: appId, client_secret: appSecret }),
  }).catch(() => null);
  const tok = tr ? await tr.json().catch(() => null) : null;
  if (!tr || !tr.ok || !tok?.access_token) {
    const raw = JSON.stringify(tok ?? {});
    const msg = /shop_not_permitted/.test(raw)
      ? "Shopify does not allow this app on this store. Create the app from inside this store's Shopify admin (Settings → Apps → Develop apps), so the app and the store belong together."
      : tr?.status === 404 ? "Store not found. Check your .myshopify.com address."
      : "Shopify did not accept these details. Check the Client ID and secret, and that you installed the app on your store.";
    return json({ error: msg, detail: raw.slice(0, 200) }, 400);
  }
  const scopes = String(tok.scope ?? "").split(",").map((s) => s.trim());
  const has = (s: string) => scopes.includes(s) || (s.startsWith("read_") && scopes.includes("write_" + s.slice(5)));
  const missing = NEEDED.filter((s) => !has(s));
  if (missing.length) return json({ error: `Your app is missing these access scopes: ${missing.join(", ")}. Add them, release a new version, approve it on your store and try again.` }, 400);

  // 2. store it
  const admin = createClient(supabaseUrl, serviceKey);
  const { data: shopId, error } = await admin.rpc("service_connect_manual", {
    p_client: clientId, p_shop: shop, p_app_client_id: appId, p_app_secret: appSecret, p_token: tok.access_token, p_scopes: tok.scope ?? "", p_expires_in: tok.expires_in ?? 86399,
  });
  if (error) return json({ error: error.message }, 400);

  // 3. webhooks ("already taken" is fine)
  const webhookUrl = `${supabaseUrl}/functions/v1/shopify-webhook`;
  const failed: string[] = [];
  for (const topic of ["ORDERS_CREATE", "ORDERS_PAID", "ORDERS_CANCELLED", "APP_UNINSTALLED", "PRODUCTS_CREATE", "PRODUCTS_UPDATE", "PRODUCTS_DELETE"]) {
    const r = await fetch(`https://${shop}/admin/api/${API_VERSION}/graphql.json`, {
      method: "POST", headers: { "Content-Type": "application/json", "X-Shopify-Access-Token": tok.access_token },
      body: JSON.stringify({
        query: `mutation($topic: WebhookSubscriptionTopic!, $sub: WebhookSubscriptionInput!) { webhookSubscriptionCreate(topic: $topic, webhookSubscription: $sub) { userErrors { message } } }`,
        variables: { topic, sub: { uri: webhookUrl, format: "JSON" } },
      }),
    }).then((x) => x.json()).catch(() => null);
    const errs = [...(r?.errors ?? []), ...(r?.data?.webhookSubscriptionCreate?.userErrors ?? [])].map((e: { message: string }) => e.message).filter((m: string) => !/taken|already/i.test(m));
    if (!r || errs.length) { failed.push(topic); console.error("webhook", topic, JSON.stringify(r)); }
  }
  await admin.from("system_events").insert({ source: "shopify", shop, topic: "manual_connect", ok: !failed.length, detail: failed.length ? "webhooks failed: " + failed.join(", ") : "connected" }).then(() => {}, () => {});

  // 4. import products (bounded wait)
  let imported: number | null = null;
  try {
    const res = await Promise.race([
      fetch(`${supabaseUrl}/functions/v1/shopify-sync-products`, { method: "POST", headers: { "Content-Type": "application/json", Authorization: `Bearer ${serviceKey}` }, body: JSON.stringify({ shop_id: shopId }) }).then((x) => x.json()),
      new Promise((ok) => setTimeout(() => ok(null), 25000)),
    ]) as { results?: { variants?: number }[] } | null;
    imported = res?.results?.[0]?.variants ?? null;
  } catch (e) { console.error("sync", e); }

  return json({
    ok: true, shop, imported,
    warning: failed.includes("ORDERS_CREATE")
      ? "Connected, but Shopify did not let us receive orders yet. In your app, turn on access to protected customer data (name, address, email, phone), release the version, then click Connect again."
      : failed.length ? `Connected, but some notifications could not be set up (${failed.join(", ")}). Click Connect again in a minute.` : null,
  });
});
