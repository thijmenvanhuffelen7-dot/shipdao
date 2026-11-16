// Admin only. Marks an order as shipped in Shipdao and, when it came from Shopify,
// creates the fulfillment with tracking in the client's store (customer gets the tracking email).
// POST { order_id }
// (unchanged; copied from the deployed version so the repo holds every function)
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";

const API_VERSION = Deno.env.get("SHOPIFY_API_VERSION") ?? "2026-10";
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

  const userClient = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } },
  });
  const { data: isAdmin } = await userClient.rpc("is_admin");
  if (!isAdmin) return json({ error: "Not allowed" }, 403);

  const { order_id } = await req.json().catch(() => ({ order_id: null }));
  if (!order_id) return json({ error: "order_id required" }, 400);

  const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const { data: order } = await admin.from("orders").select("id, tracking_number, shop_id, shopify_order_id").eq("id", order_id).single();
  if (!order) return json({ error: "Order not found" }, 404);
  if (!order.tracking_number) return json({ error: "Add a tracking number first" }, 400);

  let shopify = "skipped (no Shopify store)";
  if (order.shop_id && order.shopify_order_id) {
    const { data: info, error } = await admin.rpc("service_fulfillment_info", { p_order: order_id });
    if (error || !info) return json({ error: "Store not connected any more" }, 400);

    const gql = async (query: string, variables: Record<string, unknown>) => {
      const r = await fetch(`https://${info.shop_domain}/admin/api/${API_VERSION}/graphql.json`, {
        method: "POST",
        headers: { "Content-Type": "application/json", "X-Shopify-Access-Token": info.access_token },
        body: JSON.stringify({ query, variables }),
      });
      return r.json();
    };

    const fo = await gql(
      `query($id: ID!) { order(id: $id) { fulfillmentOrders(first: 20) { nodes { id status } } } }`,
      { id: `gid://shopify/Order/${info.shopify_order_id}` },
    );
    const open = (fo?.data?.order?.fulfillmentOrders?.nodes ?? [])
      .filter((n: { status: string }) => ["OPEN", "IN_PROGRESS"].includes(n.status))
      .map((n: { id: string }) => ({ fulfillmentOrderId: n.id }));
    if (open.length === 0) {
      shopify = "nothing open to fulfil in Shopify";
    } else {
      const res = await gql(
        `mutation($f: FulfillmentInput!) { fulfillmentCreate(fulfillment: $f) { fulfillment { id status } userErrors { field message } } }`,
        {
          f: {
            notifyCustomer: true,
            trackingInfo: {
              number: info.tracking_number,
              company: info.tracking_company ?? undefined,
              url: info.tracking_url ?? undefined,
            },
            lineItemsByFulfillmentOrder: open,
          },
        },
      );
      const errs = res?.data?.fulfillmentCreate?.userErrors ?? res?.errors ?? [];
      if (errs.length) return json({ error: "Shopify: " + errs.map((e: { message: string }) => e.message).join("; ") }, 400);
      shopify = "fulfilled";
    }
  }

  await admin.from("orders").update({ status: "shipped", shipped_at: new Date().toISOString() }).eq("id", order_id);
  return json({ ok: true, shopify });
});
