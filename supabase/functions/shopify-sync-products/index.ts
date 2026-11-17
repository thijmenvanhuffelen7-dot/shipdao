// Pulls every product + variant from a connected Shopify store into public.products.
// POST { shop_id? }  — admin: any shop (or all shops when shop_id is omitted); client: only own shops.
// Also called internally by shopify-callback right after install (with the service role key).
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

// Shopify allows at most 1000 cost points per query: products × variants must stay under it.
// 10 products × (80 variants + a few fields) ≈ 850 points.
const QUERY = `query($cursor: String) {
  products(first: 10, after: $cursor) {
    pageInfo { hasNextPage endCursor }
    nodes {
      legacyResourceId title handle status onlineStoreUrl
      featuredMedia { preview { image { url } } }
      variants(first: 80) { nodes { legacyResourceId title sku price } }
    }
  }
}`;

type Item = Record<string, string | null>;

// Manually connected stores (their own app) get 24-hour tokens: refresh when it is about to expire.
// deno-lint-ignore no-explicit-any
async function freshToken(admin: any, shopId: string, info: any): Promise<string> {
  if (!info.app_client_id || !info.app_secret) return info.access_token;
  if (info.expires_at && new Date(info.expires_at).getTime() - Date.now() > 10 * 60 * 1000) return info.access_token;
  const r = await fetch(`https://${info.shop_domain}/admin/oauth/access_token`, {
    method: "POST", headers: { "Content-Type": "application/x-www-form-urlencoded", Accept: "application/json" },
    body: new URLSearchParams({ grant_type: "client_credentials", client_id: info.app_client_id, client_secret: info.app_secret }),
  });
  const body = await r.json().catch(() => null);
  if (!r.ok || !body?.access_token) throw new Error(`${info.shop_domain}: could not refresh the Shopify token (${r.status}). Reconnect the store.`);
  await admin.rpc("service_store_token", { p_shop_id: shopId, p_token: body.access_token, p_scopes: body.scope ?? "", p_expires_in: body.expires_in ?? 86399 });
  return body.access_token;
}


async function syncShop(admin: ReturnType<typeof createClient>, shopId: string) {
  const { data: info, error } = await admin.rpc("service_shop_token", { p_shop_id: shopId });
  if (error || !info) throw new Error("Store not connected");
  if (!/(read|write)_products/.test(String(info.scopes ?? "")))
    throw new Error(`${info.shop_domain}: reconnect the store so Shipdao may read products`);
  const token = await freshToken(admin, shopId, info);

  const items: Item[] = [];
  let cursor: string | null = null;
  for (let page = 0; page < 400; page++) { // up to 4000 products
    const r = await fetch(`https://${info.shop_domain}/admin/api/${API_VERSION}/graphql.json`, {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-Shopify-Access-Token": token },
      body: JSON.stringify({ query: QUERY, variables: { cursor } }),
    });
    if (r.status === 429) { await new Promise((ok) => setTimeout(ok, 2000)); page--; continue; }
    const body = await r.json().catch(() => null);
    if (!r.ok || body?.errors) {
      const throttled = (body?.errors ?? []).some((e: { extensions?: { code?: string } }) => e.extensions?.code === "THROTTLED");
      if (throttled) { await new Promise((ok) => setTimeout(ok, 2000)); page--; continue; }
      throw new Error(`Shopify ${r.status}: ${JSON.stringify(body?.errors ?? body).slice(0, 300)}`);
    }
    const conn = body.data.products;
    for (const p of conn.nodes) {
      const many = p.variants.nodes.length > 1;
      for (const v of p.variants.nodes) {
        items.push({
          product_id: String(p.legacyResourceId), variant_id: String(v.legacyResourceId),
          title: p.title, variant_title: many || v.title !== "Default Title" ? v.title : null,
          sku: v.sku || null, price: v.price ?? null,
          image_url: p.featuredMedia?.preview?.image?.url ?? null,
          shop_url: p.onlineStoreUrl ?? `https://${info.shop_domain}/products/${p.handle}`,
          status: p.status,
        });
      }
    }
    if (!conn.pageInfo.hasNextPage) break;
    cursor = conn.pageInfo.endCursor;
  }

  let created = 0, updated = 0;
  for (let i = 0; i < items.length; i += 500) {
    const { data, error: e } = await admin.rpc("service_upsert_products", { p_shop: info.shop_domain, p_items: items.slice(i, i + 500) });
    if (e) throw new Error(e.message);
    created += data?.new ?? 0; updated += data?.updated ?? 0;
  }
  return { shop: info.shop_domain, variants: items.length, new: created, updated };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  const url = Deno.env.get("SUPABASE_URL")!;
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const admin = createClient(url, serviceKey);
  const { shop_id } = await req.json().catch(() => ({ shop_id: null }));
  const auth = req.headers.get("Authorization") ?? "";

  // which shops may this caller sync?
  let shopIds: string[] = [];
  if (auth === `Bearer ${serviceKey}`) {
    if (!shop_id) return json({ error: "shop_id required" }, 400);
    shopIds = [shop_id];
  } else {
    const user = createClient(url, Deno.env.get("SUPABASE_ANON_KEY")!, { global: { headers: { Authorization: auth } } });
    const { data: isAdmin } = await user.rpc("is_admin");
    const { data: myClient } = await user.rpc("my_client_id");
    let q = admin.from("shops").select("id, client_id").eq("status", "active");
    if (shop_id) q = q.eq("id", shop_id);
    if (!isAdmin) {
      if (!myClient) return json({ error: "Not allowed" }, 403);
      q = q.eq("client_id", myClient);
    }
    const { data: shops } = await q;
    shopIds = (shops ?? []).map((s: { id: string }) => s.id);
    if (!shopIds.length) return json({ error: "No connected Shopify store" }, 404);
  }

  const results = [];
  for (const id of shopIds) {
    try { results.push(await syncShop(admin, id)); }
    catch (e) { results.push({ shop_id: id, error: e instanceof Error ? e.message : String(e) }); }
  }
  const failed = results.filter((r) => "error" in r);
  if (failed.length === results.length) return json({ error: failed.map((f) => f.error).join("; "), results }, 400);
  return json({ ok: true, results });
});
