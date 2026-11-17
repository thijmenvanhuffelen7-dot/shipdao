// Shipdao public site: settings + small behaviours. No frameworks.
const SITE = {
  PORTAL: "https://app.shipdao.nl",
  LEAD_URL: "https://yjkbjljnnikfqvzvzulg.supabase.co/functions/v1/lead-intake?token=PivjsuY_sTmVv549syh0Nr1CWxYM-203",
  WHATSAPP: "",          // e.g. "31612345678"; empty = WhatsApp links are hidden
  BOOKING_URL: "",       // e.g. a Calendly link; empty = "Book a call" text only
};

// scroll reveal, with a small stagger for siblings that appear together
const io = "IntersectionObserver" in window ? new IntersectionObserver((entries) => {
  for (const e of entries) if (e.isIntersecting) {
    const el = e.target, sibs = [...el.parentElement.children].filter((c) => c.hasAttribute("data-r"));
    el.style.transitionDelay = `${Math.min(sibs.indexOf(el), 6) * 0.08}s`;
    el.classList.add("in"); io.unobserve(el);
    el.querySelectorAll(".bar i[data-w]").forEach((b) => (b.style.width = b.dataset.w));
  }
}, { threshold: 0.15, rootMargin: "0px 0px -40px 0px" }) : null;
document.querySelectorAll("[data-r]").forEach((el) => (io ? io.observe(el) : el.classList.add("in")));
if (!io) document.querySelectorAll(".bar i[data-w]").forEach((b) => (b.style.width = b.dataset.w));

// mobile menu
const nav = document.querySelector(".nav");
document.querySelector(".burger")?.addEventListener("click", () => nav.classList.toggle("open"));
document.querySelectorAll(".links a").forEach((a) => a.addEventListener("click", () => nav.classList.remove("open")));

// portal links
document.querySelectorAll("[data-portal]").forEach((a) => (a.href = SITE.PORTAL + a.dataset.portal));
// WhatsApp / booking links only when configured
document.querySelectorAll("[data-wa]").forEach((a) => { if (SITE.WHATSAPP) a.href = `https://wa.me/${SITE.WHATSAPP}`; else a.remove(); });
document.querySelectorAll("[data-book]").forEach((a) => { if (SITE.BOOKING_URL) a.href = SITE.BOOKING_URL; else a.replaceWith(document.createTextNode(a.textContent)); });

// YouTube: load the player only after a click (keeps the page fast)
document.querySelectorAll(".video[data-yt]").forEach((v) => v.addEventListener("click", () => {
  v.innerHTML = `<iframe src="https://www.youtube-nocookie.com/embed/${v.dataset.yt}?autoplay=1&rel=0" allow="autoplay; encrypted-media; picture-in-picture" allowfullscreen title="Shipdao intro"></iframe>`;
}, { once: true }));

// price check form -> Leads in the portal
const form = document.getElementById("price-form");
form?.addEventListener("submit", async (e) => {
  e.preventDefault();
  const btn = form.querySelector("button"), ok = form.querySelector(".ok");
  const data = Object.fromEntries(new FormData(form).entries());
  if (data.hp_field) return; // bots fill hidden fields
  btn.disabled = true; btn.textContent = "Sending…";
  try {
    const r = await fetch(SITE.LEAD_URL, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ store: data.store, orders: data.orders, email: data.email }) });
    if (!r.ok) throw new Error(r.status);
    form.querySelectorAll("input,select").forEach((i) => (i.disabled = true));
    btn.style.display = "none"; ok.style.display = "block";
  } catch {
    btn.disabled = false; btn.textContent = "Send my price check";
    alert("Something went wrong. Please email us at hello@shipdao.nl");
  }
});
