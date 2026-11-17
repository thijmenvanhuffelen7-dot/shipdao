// Shopify redirects here after the merchant approves the app.
// Verifies the HMAC, exchanges the code for a token, stores it, registers webhooks
// and imports the store's products.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";

const API_VERSION = Deno.env.get("SHOPIFY_API_VERSION") ?? "2026-10";
const enc = new TextEncoder();

async function hmacHex(secret: string, message: string) {
  const key = await crypto.subtle.importKey("raw", enc.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const sig = await crypto.subtle.sign("HMAC", key, enc.encode(message));
  return [...new Uint8Array(sig)].map((b) => b.toString(16).padStart(2, "0")).join("");
}
function safeEqual(a: string, b: string) {
  if (a.length !== b.length) return false;
  let r = 0;
  for (let i = 0; i < a.length; i++) r |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return r === 0;
}

Deno.serve(async (req) => {
  const appUrl = Deno.env.get("APP_URL") ?? "";
  const back = (status: string, msg = "") =>
    Response.redirect(`${appUrl}${appUrl.includes("?") ? "&" : "?"}shopify=${status}${msg ? `&msg=${encodeURIComponent(msg)}` : ""}`, 302);

  try {
    const secret = Deno.env.get("SHOPIFY_API_SECRET");
    const apiKey = Deno.env.get("SHOPIFY_API_KEY");
    if (!secret || !apiKey) return back("error", "Shopify app not configured");

    const params = new URL(req.url).searchParams;
    const shop = (params.get("shop") ?? "").toLowerCase();
    const code = params.get("code") ?? "";
    const state = params.get("state") ?? "";
    const hmac = params.get("hmac") ?? "";

    if (!/^[a-z0-9][a-z0-9-]*\.myshopify\.com$/.test(shop)) return back("error", "Invalid shop");

    const message = [...params.entries()]
      .filter(([k]) => k !== "hmac" && k !== "signature")
      .sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0))
      .map(([k, v]) => `${k}=${v}`)
      .join("&");
    if (!safeEqual(await hmacHex(secret, message), hmac)) return back("error", "Invalid signature");

    const tokenRes = await fetch(`https://${shop}/admin/oauth/access_token`, {
      method: "POST",
      headers: { "Content-Type": "application/json", Accept: "application/json" },
      body: JSON.stringify({ client_id: apiKey, client_secret: secret, code }),
    });
    if (!tokenRes.ok) return back("error", "Token exchange failed");
    const { access_token, scope } = await tokenRes.json();

    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const admin = createClient(supabaseUrl, serviceKey);
    const { data: shopId, error } = await admin.rpc("service_complete_oauth", {
      p_state: state, p_shop: shop, p_token: access_token, p_scopes: scope ?? "",
    });
    if (error) return back("error", error.message);

    // Register webhooks ("already taken" errors are fine)
    const webhookUrl = `${supabaseUrl}/functions/v1/shopify-webhook`;
    const failed: string[] = [];
    for (const topic of ["ORDERS_CREATE", "ORDERS_PAID", "ORDERS_CANCELLED", "APP_UNINSTALLED", "PRODUCTS_CREATE", "PRODUCTS_UPDATE", "PRODUCTS_DELETE"]) {
      const r = await fetch(`https://${shop}/admin/api/${API_VERSION}/graphql.json`, {
        method: "POST",
        headers: { "Content-Type": "application/json", "X-Shopify-Access-Token": access_token },
        body: JSON.stringify({
          query: `mutation($topic: WebhookSubscriptionTopic!, $sub: WebhookSubscriptionInput!) {
            webhookSubscriptionCreate(topic: $topic, webhookSubscription: $sub) { userErrors { message } }
          }`,
          variables: { topic, sub: { uri: webhookUrl, format: "JSON" } },
        }),
      }).then((x) => x.json()).catch(() => null);
      const errs = [...(r?.errors ?? []), ...(r?.data?.webhookSubscriptionCreate?.userErrors ?? [])]
        .map((e: { message: string }) => e.message).filter((m: string) => !/taken|already/i.test(m));
      if (!r || errs.length) { failed.push(topic); console.error("webhook", topic, JSON.stringify(r)); }
    }

    // Import products (don't block the redirect on a huge catalogue for too long)
    let imported = "";
    try {
      const res = await Promise.race([
        fetch(`${supabaseUrl}/functions/v1/shopify-sync-products`, {
          method: "POST",
          headers: { "Content-Type": "application/json", Authorization: `Bearer ${serviceKey}` },
          body: JSON.stringify({ shop_id: shopId }),
        }).then((x) => x.json()),
        new Promise((ok) => setTimeout(() => ok(null), 25000)),
      ]) as { results?: { variants?: number }[] } | null;
      const n = res?.results?.[0]?.variants;
      imported = n != null ? String(n) : "";
    } catch (e) { console.error("sync", e); }

    const q = new URLSearchParams();
    if (imported) q.set("imported", imported);
    if (failed.includes("ORDERS_CREATE")) q.set("msg", "Connected, but the order webhook could not be registered. Check protected customer data access in your Shopify app settings.");
    return Response.redirect(`${appUrl}${appUrl.includes("?") ? "&" : "?"}shopify=connected${q.toString() ? "&" + q : ""}`, 302);
  } catch (e) {
    return back("error", e instanceof Error ? e.message : "Unknown error");
  }
});
