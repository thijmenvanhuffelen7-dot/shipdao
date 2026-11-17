// Mollie calls this with "id=tr_..." whenever a payment changes.
// Mollie webhooks are not signed, so we never trust the request: we fetch the payment
// from the Mollie API with our own key and only then update the balance.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("Method not allowed", { status: 405 });
  const key = Deno.env.get("MOLLIE_API_KEY");
  if (!key) return new Response("Not configured", { status: 500 });

  const form = await req.formData().catch(() => null);
  const id = String(form?.get("id") ?? "");
  if (!/^tr_[A-Za-z0-9]+$/.test(id)) return new Response("ok"); // ignore junk, don't leak anything

  const r = await fetch(`https://api.mollie.com/v2/payments/${id}`, { headers: { Authorization: `Bearer ${key}` } });
  if (r.status === 404) return new Response("ok");
  if (!r.ok) return new Response("Mollie unavailable", { status: 503 }); // Mollie retries
  const m = await r.json();

  const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const paymentId = m.metadata?.payment_id;
  if (!paymentId) return new Response("ok");
  const { data, error } = await admin.rpc("service_mark_payment", {
    p_payment: paymentId, p_mollie_id: m.id, p_status: m.status, p_amount: Number(m.amount?.value),
    p_method: m.method ?? null, p_mode: m.mode ?? null, p_charged_back: Number(m.amountChargedBack?.value ?? 0),
  });
  if (error) { console.error("mark", id, error.message); return new Response("Error", { status: 500 }); }
  console.log("mollie", id, JSON.stringify(data));
  return new Response("ok");
});
