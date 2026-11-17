// Client tops up their balance online via Mollie (iDEAL, Bancontact, card).
// POST { amount }          -> { checkout_url }   (send the browser there)
// POST { check: <id> }     -> re-fetch status from Mollie (used when the client comes back,
//                             in case the webhook has not arrived yet)
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";

const MIN = 10, MAX = 5000;
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

// deno-lint-ignore no-explicit-any
export async function syncFromMollie(admin: any, key: string, paymentId: string, mollieId: string) {
  const r = await fetch(`https://api.mollie.com/v2/payments/${encodeURIComponent(mollieId)}`, { headers: { Authorization: `Bearer ${key}` } });
  if (!r.ok) throw new Error(`Mollie ${r.status}`);
  const m = await r.json();
  const { data, error } = await admin.rpc("service_mark_payment", {
    p_payment: paymentId, p_mollie_id: m.id, p_status: m.status, p_amount: Number(m.amount?.value),
    p_method: m.method ?? null, p_mode: m.mode ?? null, p_charged_back: Number(m.amountChargedBack?.value ?? 0),
  });
  if (error) throw new Error(error.message);
  return data;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  const key = Deno.env.get("MOLLIE_API_KEY");
  const appUrl = Deno.env.get("APP_URL");
  if (!key) return json({ error: "Online payments are not set up yet. Please top up by bank transfer." }, 503);
  if (!appUrl) return json({ error: "APP_URL secret is missing" }, 500);

  const url = Deno.env.get("SUPABASE_URL")!;
  const user = createClient(url, Deno.env.get("SUPABASE_ANON_KEY")!, { global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } } });
  const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const { data: clientId } = await user.rpc("my_client_id");
  const { data: who } = await user.auth.getUser();
  if (!clientId || !who?.user) return json({ error: "Not allowed" }, 403);

  const body = await req.json().catch(() => ({}));

  if (body.check) {
    const { data: p } = await admin.from("payments").select("id, mollie_id, client_id").eq("id", body.check).single();
    if (!p || p.client_id !== clientId) return json({ error: "Payment not found" }, 404);
    if (!p.mollie_id) return json({ status: "created" });
    try { return json(await syncFromMollie(admin, key, p.id, p.mollie_id)); }
    catch (e) { return json({ error: e instanceof Error ? e.message : String(e) }, 502); }
  }

  const amount = Math.round(Number(body.amount) * 100) / 100;
  if (!(amount >= MIN && amount <= MAX)) return json({ error: `Amount must be between €${MIN} and €${MAX}` }, 400);

  const { data: client } = await admin.from("clients").select("name").eq("id", clientId).single();
  const { data: pay, error } = await admin.from("payments")
    .insert({ client_id: clientId, amount, created_by: who.user.id }).select("id").single();
  if (error) return json({ error: error.message }, 500);

  const back = `${appUrl}${appUrl.includes("?") ? "&" : "?"}topup=${pay.id}`;
  const r = await fetch("https://api.mollie.com/v2/payments", {
    method: "POST",
    headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/json" },
    body: JSON.stringify({
      amount: { currency: "EUR", value: amount.toFixed(2) },
      description: `Shipdao balance top-up · ${client?.name ?? ""}`.slice(0, 255),
      redirectUrl: back, cancelUrl: back,
      webhookUrl: `${url}/functions/v1/mollie-webhook`,
      metadata: { payment_id: pay.id, client_id: clientId },
    }),
  });
  const m = await r.json().catch(() => null);
  if (!r.ok || !m?._links?.checkout?.href) {
    await admin.from("payments").update({ status: "failed" }).eq("id", pay.id);
    return json({ error: "Mollie: " + (m?.detail ?? `error ${r.status}`) }, 502);
  }
  await admin.from("payments").update({ mollie_id: m.id, status: m.status, mode: m.mode, checkout_url: m._links.checkout.href }).eq("id", pay.id);
  return json({ checkout_url: m._links.checkout.href, payment_id: pay.id });
});
