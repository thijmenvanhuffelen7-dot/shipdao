// Receives the "free price check" form (shipdao.nl site, or a Framer form webhook) and stores it as a lead.
// The webhook URL carries ?token=<lead_webhook_token from private.settings>; requests without it are rejected.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";

function safeEqual(a: string, b: string) {
  if (!a || a.length !== b.length) return false;
  let r = 0;
  for (let i = 0; i < a.length; i++) r |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return r === 0;
}
// deno-lint-ignore no-explicit-any
const pick = (o: Record<string, any>, re: RegExp) => {
  const k = Object.keys(o).find((x) => re.test(x));
  return k ? String(o[k] ?? "").slice(0, 500) : null;
};

const CORS = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Methods": "POST, OPTIONS", "Access-Control-Allow-Headers": "content-type" };
const reply = (body: string, status = 200) => new Response(body, { status, headers: CORS });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: CORS });
  if (req.method !== "POST") return reply("Method not allowed", 405);
  const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const { data: token } = await admin.rpc("service_setting", { p_key: "lead_webhook_token" });
  if (!token || !safeEqual(new URL(req.url).searchParams.get("token") ?? "", String(token))) return reply("Unauthorized", 401);

  // max 5 requests per 10 minutes and 30 per day per visitor (IP only kept as a hash)
  const ip = req.headers.get("cf-connecting-ip") ?? req.headers.get("x-real-ip") ?? (req.headers.get("x-forwarded-for") ?? "").split(",")[0].trim();
  const ipHash = [...new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode("shipdao-lead:" + ip)))].slice(0, 12).map((b) => b.toString(16).padStart(2, "0")).join("");
  // plus a site-wide cap of 200 a day, against bots that rotate IP addresses
  for (const [key, max, secs] of [[`lead:600:${ipHash}`, 5, 600], [`lead:86400:${ipHash}`, 30, 86400], ["lead:all", 200, 86400]] as const) {
    const { data: okRate } = await admin.rpc("service_rate_limit", { p_key: key, p_max: max, p_seconds: secs });
    if (okRate === false) return reply("Too many requests", 429);
  }
  const raw = await req.text();
  if (raw.length > 20000) return reply("Too large", 413);
  // deno-lint-ignore no-explicit-any
  let body: Record<string, any> = {};
  try { body = JSON.parse(raw); } catch { body = Object.fromEntries(new URLSearchParams(raw)); }
  if (body && typeof body.data === "object" && body.data) body = { ...body, ...body.data };
  if (body.hp_field) return reply("ok"); // honeypot filled in: a bot. Pretend it worked, store nothing.
  delete body.hp_field;

  const lead = {
    email: pick(body, /mail/i), store_url: pick(body, /store|url|shop|website/i),
    orders_per_day: pick(body, /order/i), message: pick(body, /message|notes?|product/i), raw: body,
  };
  if (!lead.email || !/^[^\s@<>]+@[^\s@<>]+\.[a-z]{2,}$/i.test(lead.email)) return reply("A valid email address is needed", 400);
  const { error } = await admin.from("leads").insert(lead);
  await admin.from("system_events").insert({ source: "site", topic: "lead", ok: !error, detail: error?.message ?? lead.email }).then(() => {}, () => {});
  if (error) return reply("Error", 500);
  return reply("ok");
});
