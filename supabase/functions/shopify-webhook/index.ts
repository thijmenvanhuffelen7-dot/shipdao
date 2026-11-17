// Receives Shopify webhooks: new orders, product changes, uninstall and the mandatory privacy webhooks.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";

const enc = new TextEncoder();
async function hmacBase64(secret: string, body: string) {
  const key = await crypto.subtle.importKey("raw", enc.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const sig = await crypto.subtle.sign("HMAC", key, enc.encode(body));
  return btoa(String.fromCharCode(...new Uint8Array(sig)));
}
function safeEqual(a: string, b: string) {
  if (a.length !== b.length) return false;
  let r = 0;
  for (let i = 0; i < a.length; i++) r |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return r === 0;
}

// REST-style product payload -> rows for service_upsert_products
// deno-lint-ignore no-explicit-any
function productItems(p: any, shop: string) {
  const variants = p.variants ?? [];
  const img = p.image?.src ?? p.images?.[0]?.src ?? null;
  return variants.map((v: Record<string, unknown>) => ({
    product_id: String(p.id), variant_id: String(v.id), title: p.title,
    variant_title: variants.length > 1 || v.title !== "Default Title" ? v.title : null,
    sku: v.sku || null, price: v.price ?? null, image_url: img,
    shop_url: `https://${shop}/products/${p.handle}`, status: String(p.status ?? "").toUpperCase(),
  }));
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("Method not allowed", { status: 405 });
  const secret = Deno.env.get("SHOPIFY_API_SECRET");
  if (!secret) return new Response("Not configured", { status: 500 });

  const raw = await req.text();
  const given = req.headers.get("X-Shopify-Hmac-Sha256") ?? "";
  if (!safeEqual(await hmacBase64(secret, raw), given)) return new Response("Unauthorized", { status: 401 });

  const topic = (req.headers.get("X-Shopify-Topic") ?? "").toLowerCase();
  const shop = (req.headers.get("X-Shopify-Shop-Domain") ?? "").toLowerCase();
  // deno-lint-ignore no-explicit-any
  let payload: any = {};
  try { payload = JSON.parse(raw); } catch { return new Response("Bad JSON", { status: 400 }); }

  const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  let result: unknown = null;

  switch (topic) {
    case "orders/create": {
      const { data, error } = await admin.rpc("service_ingest_order", { p_shop: shop, p_payload: payload });
      if (error) { console.error("ingest", error); return new Response("Error", { status: 500 }); } // Shopify retries
      result = data;
      break;
    }
    case "orders/paid": {
      const { data, error } = await admin.rpc("service_order_paid", { p_shop: shop, p_payload: payload });
      if (error) { console.error("paid", error); return new Response("Error", { status: 500 }); }
      result = data;
      break;
    }
    case "orders/cancelled": {
      const { data, error } = await admin.rpc("service_order_cancelled", { p_shop: shop, p_payload: payload });
      if (error) { console.error("cancelled", error); return new Response("Error", { status: 500 }); }
      result = data;
      break;
    }
    case "products/create":
    case "products/update": {
      const { data, error } = await admin.rpc("service_upsert_products", { p_shop: shop, p_items: productItems(payload, shop) });
      if (error) { console.error("products", error); return new Response("Error", { status: 500 }); }
      result = data;
      break;
    }
    case "products/delete":
      if (payload.id) await admin.rpc("service_products_deleted", { p_shop: shop, p_product_id: Number(payload.id) });
      break;
    case "app/uninstalled":
      await admin.rpc("service_shop_uninstalled", { p_shop: shop });
      break;
    case "customers/redact": {
      const ids = ((payload.orders_to_redact as number[]) ?? []).map(Number);
      await admin.rpc("service_customer_redact", { p_shop: shop, p_order_ids: ids });
      break;
    }
    case "shop/redact":
      await admin.rpc("service_shop_redact", { p_shop: shop });
      break;
    case "customers/data_request":
      // We only hold order name + shipping address for fulfilment; nothing extra to export automatically.
      console.log("data request for", shop);
      break;
  }
  return new Response(JSON.stringify({ ok: true, result }), { headers: { "Content-Type": "application/json" } });
});
