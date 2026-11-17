#!/usr/bin/env python3
"""Builds the public site (site/index.html, site/docs.html) from the content below.
Edit the texts here, run `python3 tools/build_site.py`, commit. Cloudflare publishes site/."""
import html, pathlib
OUT = pathlib.Path(__file__).resolve().parent.parent / "site"
E = html.escape
EMAIL = "hello@shipdao.nl"
COMPANY = "Shipdao is a trade name of Ecom Thijmen · Brugstraat 4, 8181 VH Heerde, Netherlands · KvK 97815845 · VAT NL005289760B27"

def head(title, desc, path):
    return f"""<!doctype html>
<html lang="en"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>{E(title)}</title><meta name="description" content="{E(desc)}">
<link rel="canonical" href="https://shipdao.nl{path}">
<meta property="og:title" content="{E(title)}"><meta property="og:description" content="{E(desc)}"><meta property="og:type" content="website">
<link rel="icon" href="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 64 64'%3E%3Crect width='64' height='64' rx='12' fill='%23B5301F'/%3E%3Ctext x='32' y='45' font-size='38' text-anchor='middle' fill='white' font-family='serif'%3E道%3C/text%3E%3C/svg%3E">
<link rel="preconnect" href="https://fonts.googleapis.com"><link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=Instrument+Sans:wght@400;500;600;700&family=Noto+Serif+SC:wght@400;500&display=swap" rel="stylesheet">
<link rel="stylesheet" href="/assets/site.css">
</head><body>"""

NAV = """<header class="nav"><div class="wrap">
<a class="brand" href="/"><span class="seal">道</span>shipdao</a>
<nav class="links"><a href="/#how">How it works</a><a href="/#why">Why Shipdao</a><a href="/#scale">Scaling</a><a href="/#plans">Plans</a><a href="/#faq">FAQ</a><a href="/docs">Docs</a><a href="#" data-portal="/#/login">Log in</a></nav>
<a class="btn" href="/#contact">Free price check</a>
<button class="burger" aria-label="Menu"><span></span><span></span><span></span></button>
</div></header>"""

FOOT = f"""<footer class="foot"><div class="wrap">
<div class="fgrid">
<div><h4>shipdao</h4><p>China fulfilment for dropshippers who are building a brand.</p></div>
<div><h4>Explore</h4><a href="/#how">How it works</a><a href="/#plans">Plans</a><a href="/#faq">FAQ</a><a href="/docs">Docs</a><a href="#" data-portal="/#/login">Log in</a></div>
<div><h4>Contact</h4><a href="mailto:{EMAIL}">{EMAIL}</a><a href="#" data-wa>WhatsApp</a></div>
<div><h4>Get started</h4><a href="/#contact">Free price check</a><a href="#" data-portal="/#/signup">Create an account</a></div>
</div>
<p class="small muted" style="margin-top:28px">{COMPANY}</p>
<div class="fbottom"><span>© 2026 Shipdao</span><span><a href="#" data-portal="/#/terms">Terms and conditions</a><a href="#" data-portal="/#/privacy">Privacy policy</a></span></div>
</div></footer>
<script src="/assets/site.js" defer></script>
</body></html>"""

MOUNTAIN = """<svg class="ink" viewBox="0 0 1200 220" preserveAspectRatio="none" fill="none" stroke="#C9B79C" stroke-width="1.2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M0 200 L120 150 L190 172 L300 96 L380 140 L470 78 L560 128 L640 60 L730 118 L820 84 L900 132 L1000 70 L1090 120 L1200 92"/><path d="M0 210 L90 178 L170 196 L260 140 L350 176 L440 120 L540 166 L620 112 L720 158 L800 128 L900 170 L990 116 L1100 160 L1200 136" opacity="0.6"/><path d="M470 78 L478 72 L486 78 M640 60 L648 54 L656 60 M1000 70 L1008 64 L1016 70"/><path d="M560 128 L560 118 L572 118 L572 128 M820 84 L820 74 L832 74 L832 84"/></svg>"""

def sec_head(eb, title, sub=None):
    return f'<div data-r><p class="eb">{eb}</p><h2>{title}</h2>{f"<p class=sub>{sub}</p>" if sub else ""}</div>'

STEPS = [("一", "Send your products", "Share your product links. Within 24 hours you get an all-in price per order, shipping and duties included."),
         ("二", "Connect Shopify", "Install one app. Orders flow to us, tracking flows back automatically."),
         ("三", "Top up and go", "Add balance to your account. Each order is paid from it, and we check, pack and ship it."),
         ("四", "You keep more margin", "Faster delivery, fewer refunds and fewer “where is my order?” emails.")]
SCALE = [("Prices renegotiated", "At higher volumes we go back to the factory and pass the better price on to you."),
         ("Branded packaging included", "At higher volumes, custom packaging can be built into your price per order."),
         ("Bulk stock when it pays off", "Once a product sells steadily, we can buy it in bulk for you. Lower unit price and faster dispatch."),
         ("Ads and email, in-house", "The same team runs your Meta, TikTok and email, so marketing and stock stay in sync.")]
PLANS = [("Fulfilment", "For dropshippers with a winning product.", ["Sourcing and price negotiation", "Quality checks with photos", "Packing and shipping", "Tracking synced to Shopify", "WhatsApp support"], "All-in price per order, from your quote", ""),
         ("Fulfilment + tracking", "For stores that want fewer “where is my order?” emails.", ["Everything in Fulfilment", "Branded tracking emails", "Shipped, in transit and delivered", "Set up in Klaviyo"], "Per order + a one-off setup", ""),
         ("Fulfilment + growth", "We bring the orders too: ads and email, run by the same team.", ["Everything in Fulfilment + tracking", "Meta and TikTok ads", "Email flows and campaigns", "A weekly call on your numbers"], "Monthly fee + per order, on request", " dark")]
FAQ = [("Which countries do you ship to?", "We ship worldwide. Tell us where your customers are and your quote shows the route and delivery time per country."),
       ("Do I need to buy stock?", "No. We buy per order, so you can start with zero stock. When a product sells steadily, bulk stock can lower your cost."),
       ("How fast do orders ship and arrive?", "It depends on the product and the route. Your quote shows the expected processing and delivery time per country, and tracking is synced to your Shopify store."),
       ("What if a parcel is lost or damaged?", "No delivery scan 30 days after shipping? Tell us and we reship it or credit the order price to your balance. Damaged or wrong item: send photos within 14 days of delivery."),
       ("I use AliExpress or CJ now. How do I switch?", "Send your product links and we quote an all-in price. If we beat what you pay now on price or speed, we connect your Shopify and new orders run through us."),
       ("How does paying work?", "You top up a balance and every order is paid from it. No contract and no subscription, so you can stop whenever you want."),
       ("How do VAT, duties and customs work?", "Duties and VAT are prepaid wherever possible, so your customer never pays at the door."),
       ("What happens around Chinese New Year?", "Factories close for about two weeks around Chinese New Year. We warn you weeks ahead, so you can stock up on bestsellers before the break.")]

# ---- homepage (dark/cream layout) ----
HOME_HEAD = lambda: head("Shipdao: China fulfilment for scaling dropshippers", "China fulfilment for dropshippers who are scaling. Faster delivery than AliExpress, your own packaging and one all-in price per order. No stock and no minimums.", "/").replace(
    '<link href="https://fonts.googleapis.com/css2?family=Instrument+Sans:wght@400;500;600;700&family=Noto+Serif+SC:wght@400;500&display=swap" rel="stylesheet">\n<link rel="stylesheet" href="/assets/site.css">',
    '<link href="https://fonts.googleapis.com/css2?family=Instrument+Sans:ital,wght@0,400;0,500;0,600;0,700;1,500;1,600;1,700&family=JetBrains+Mono:wght@400;500&family=Noto+Serif+SC:wght@500;700&display=swap" rel="stylesheet">\n<link rel="stylesheet" href="/assets/home.css">').replace("<body>", '<body class="h">')

HNAV = """<header class="nav"><div class="hw">
<a class="brand" href="/"><span class="seal">道</span>shipdao<i>.</i></a>
<nav class="links"><a href="#how">How it works</a><a href="#why">Why Shipdao</a><a href="#promises">Promises</a><a href="#scale">Scaling</a><a href="#plans">Plans</a><a href="#faq">FAQ</a><a href="/docs">Docs</a><a href="#" data-portal="/#/login">Log in</a></nav>
<a class="btn sm" href="#contact">Free price check</a>
<button class="burger" aria-label="Menu"><span></span><span></span><span></span></button>
</div></header>"""

HFOOT = f"""<footer class="hfoot"><div class="hw">
<div class="fg">
<div class="fb"><a class="brand" href="/"><span class="seal">道</span>shipdao<i>.</i></a><p>China fulfilment for dropshippers who are building a brand. From the factory in China to your customer's door.</p></div>
<div><p class="mono">Explore</p><a href="#how">How it works</a><a href="#promises">Promises</a><a href="#plans">Plans</a><a href="#faq">FAQ</a><a href="/docs">Documentation</a></div>
<div><p class="mono">Contact</p><a href="mailto:{EMAIL}">{EMAIL}</a><a href="#" data-wa>WhatsApp</a><a href="#contact">Free price check</a></div>
<div><p class="mono">Account</p><a href="#" data-portal="/#/login">Log in</a><a href="#" data-portal="/#/signup">Create an account</a><a href="#" data-portal="/#/terms">Terms</a><a href="#" data-portal="/#/privacy">Privacy</a></div>
</div>
<p class="co">{COMPANY}</p>
<div class="fbot"><span>© 2026 Shipdao. All rights reserved.</span><span>China ⇄ Netherlands</span></div>
</div></footer>
<script src="/assets/site.js" defer></script>
</body></html>"""

TICKER = ["<b>24h</b> all-in quote", "<b>€0</b> stock needed", "<b>No</b> minimums", "<b>QC</b> photos every batch", "<b>Auto</b> tracking to Shopify", "<b>Same-day</b> replies on WhatsApp"]

HSTEPS = [("01", "24 hours", "Send your products", "Share your product links. You get one all-in price per order, shipping and duties included."),
          ("02", "Shopify", "Connect your store", "One click, about a minute. Orders flow to us, tracking flows back by itself."),
          ("03", "China", "We take over the chain", "Buying, quality checks, packing and shipping, paid from your prepaid balance."),
          ("04", "More margin", "You keep more", "Faster delivery, fewer refunds and fewer “where is my order?” emails.")]

def feat(i, dark, eb, big, title, text, tags, visual):
    tg = "".join(f"<span>{t}</span>" for t in tags)
    return f'<div class="feat{" dk" if dark else ""}" data-r><div><p class="mono">0{i} / 06 · {eb}</p><p class="big">{big}</p><h3>{title}</h3><p class="tx">{text}</p><div class="tags">{tg}</div></div><div class="vis">{visual}</div></div>'

FEATS = [
 (True, "Support", "Same day", "A person, not a ticket queue", "Message us on WhatsApp like you would a colleague. You talk to the same person every time, and you hear back the same day.", ["WhatsApp", "Email", "Order chat"],
  '<div class="panel"><p class="mono row"><span>WhatsApp · Shipdao</span><span class="ok">● online</span></p><div class="bub q">Can we add a thank-you card to the hoodie orders?</div><div class="bub a">Yes. Send the design and it goes in from the next batch.</div><p class="mono acc">Replied the same day</p></div>'),
 (False, "Your contact", "1 person", "Who knows your store", "One contact who knows your products, your margins and your customers. No ticket numbers, no “we will check with the warehouse”.", ["Fixed contact", "Knows your margins"],
  '<div class="panel"><p class="mono row"><span>Your products</span><span class="acc">Live</span></p><div class="ln"><span>Hoodie · black / M</span><b>Priced</b></div><div class="ln"><span>Hoodie · grey / L</span><b>Priced</b></div><div class="ln"><span>Cap · beige</span><b class="w">Being sourced</b></div><p class="mono dim">All-in price per variant · in your portal</p></div>'),
 (True, "Quality", "Every batch", "Checked before it ships", "Every new batch is checked for size, colour, finish and packaging. You get the photos. If something is off, it does not leave the warehouse.", ["Before dispatch", "Photos for you"],
  '<div class="panel"><p class="mono row"><span>QC report · batch #12</span><span class="acc">3/3 pass</span></p><div class="qph"><img src="/img/qc-shirt.jpg" alt="T-shirt being checked" loading="lazy"><img src="/img/qc-print.jpg" alt="Print detail" loading="lazy"><img src="/img/qc-box.jpg" alt="Packed box" loading="lazy"></div><div class="ck"><i>✓</i>Size and colour<b>Pass</b></div><div class="ck"><i>✓</i>Finish<b>Pass</b></div><div class="ck"><i>✓</i>Branded packaging<b>Pass</b></div></div>'),
 (False, "Your brand", "Your logo", "On the box, not a grey bag", "Custom boxes, inserts or a thank-you card. This is how a dropshipping store starts to feel like a brand people buy from again.", ["Custom boxes", "Thank-you cards"],
  '<div class="photo"><img src="/img/brand-box.jpg" alt="Branded shipping box" loading="lazy"><p class="mono">Your logo · printed on every parcel</p></div>'),
 (True, "Speed", "Express", "Fast lanes for your bestsellers", "Put your top products on a faster lane and keep the rest on standard. You choose per product, we keep both running.", ["Per product", "Express lanes"],
  '<div class="lanes"><p class="mono row"><span>Standard lane</span><span>per route</span></p><div class="bar"><i data-w="100%"></i></div><p class="mono row acc"><span>Express lane</span><span>faster</span></p><div class="bar ex"><i data-w="62%"></i></div><p class="mono dim">Illustrative. Real times measured per product and route.</p></div>'),
 (False, "Start", "€0", "Stock to get started", "We buy per order, so you start with zero stock and no minimums. When a product sells steadily, bulk stock can lower your cost further.", ["No stock", "No minimums", "No subscription"],
  '<div class="panel"><p class="mono row"><span>Your balance</span><span class="acc">Prepaid</span></p><div class="ln"><span>Order #1041 · hoodie</span><b>− charged</b></div><div class="ln"><span>Order #1042 · cap</span><b>− charged</b></div><div class="ln"><span>Top up · iDEAL</span><b class="g">+ added</b></div><p class="mono dim">Pay per order · stop whenever you want</p></div>'),
]

PROMISES = [("24h", "All-in quote", "Send your products and you get one price per order within 24 hours, shipping and duties included."),
            ("€0", "Stock & minimums", "We buy per order. You start without stock and without a minimum order volume."),
            ("30d", "Lost parcel", "No delivery scan 30 days after shipping? We reship it or credit the order price to your balance."),
            ("14d", "Damaged or wrong", "Send photos within 14 days of delivery and we sort it out with you.")]

DASH = [("Your prices, per variant", "Every product and variant with your shop price, our all-in price and what you keep."),
        ("Every order, as it moves", "Status and tracking for every order, synced to Shopify automatically."),
        ("Top up in one click", "iDEAL, Bancontact or card. Every order is paid from your balance, every month exportable."),
        ("Photos and chat per order", "Quality-check photos and a chat with us, right next to the order it is about.")]

DIFF = [("Response time", "Next day, if you chase it", "<em>Same day</em> on WhatsApp, from one fixed contact"),
        ("Price", "A markup you never see", "One <em>all-in price</em> per order, agreed up front"),
        ("Tracking", "Pasted in by hand, days later", "Synced to <em>Shopify</em> automatically"),
        ("Quality", "Your customers are the quality check", "Checked <em>before dispatch</em>, with photos"),
        ("Packaging", "A grey bag with someone else's name", "<em>Your logo</em> on the box"),
        ("Stock", "Buy upfront or wait", "<em>No stock</em>, no minimums, pay per order")]

def home():
    tick = "".join(f"<span>{t}</span><i>●</i>" for t in TICKER) * 2
    steps = "".join(f'<div class="st{" hl" if n == "04" else ""}"><p class="mono row"><b>{n}</b><span>{tag}</span></p><h3>{t}</h3><p>{d}</p></div>' for n, tag, t, d in HSTEPS)
    feats = "".join(feat(i + 1, *f) for i, f in enumerate(FEATS))
    prom = "".join(f'<div><p class="pn">{n}</p><p class="mono acc">{l}</p><p>{d}</p></div>' for n, l, d in PROMISES)
    dash = "".join(f'<div class="di"><h3>{t}</h3><p>{d}</p></div>' for t, d in DASH)
    plans = "".join(f'<div class="plan{" dk" if c else ""}" data-r><p class="mono acc">{f"0{i+1}"}</p><h3>{t}</h3><p class="for">{f}</p><ul>{"".join(f"<li>{x}</li>" for x in items)}</ul><p class="price">{p}</p></div>' for i, (t, f, items, p, c) in enumerate(PLANS))
    them = "".join(f'<div class="dr"><i>×</i><div><p class="mono">{k}</p><p>{a}</p></div></div>' for k, a, _ in DIFF)
    us = "".join(f'<div class="dr"><i>✓</i><div><p class="mono">{k}</p><p>{b}</p></div></div>' for k, _, b in DIFF)
    faq = "".join(f'<details{" open" if i == 0 else ""}><summary>{q}<i></i></summary><p>{a}</p></details>' for i, (q, a) in enumerate(FAQ))
    return HOME_HEAD() + HNAV + f"""
<main>
<section class="hero">
  <div class="ink-bg" aria-hidden="true">{MOUNTAIN}{MOUNTAIN}<span class="han">道</span></div>
  <div class="hw"><p class="mono kick">The team behind your store · China ⇄ Netherlands</p></div>
  <div class="ticker"><div class="tt">{tick}</div></div>
  <div class="hw hgrid">
    <div><h1 data-r>Your store <em>sells.</em><br>We <em>ship it</em> like<br><span class="it">a real brand.</span></h1>
      <div class="ctas" data-r><a class="btn arrow" href="#contact">Get a free price check<b>→</b></a><a class="btn ghost" href="#how">See how it works</a></div></div>
    <p class="side" data-r>Everything between the factory in China and your customer's door: buying, quality checks, packing and shipping. One all-in price per order, no stock and no minimums.</p>
  </div>
</section>

<section class="vsec"><div class="hw">
  <div class="video" data-yt="cYNEAUwrMck" role="button" aria-label="Play the intro video" data-r><img src="https://i.ytimg.com/vi/cYNEAUwrMck/maxresdefault.jpg" alt="Shipdao intro video" loading="lazy"><span class="vt">Found a winner?<br>Ship it like a <em>brand.</em></span><span class="snd">▶ Watch with sound</span></div>
</div></section>

<section class="cs" id="how"><div class="hw">
  <p class="mono acc" data-r>How it works · 流程</p>
  <h2 data-r>Live in about a week, without<br>touching the chain <em class="it">yourself.</em></h2>
  <div class="steps" data-r>{steps}</div>
</div></section>

<section class="cs" id="why" style="padding-top:0"><div class="hw">
  <div class="split" data-r><div><p class="mono acc">Why Shipdao · 为什么</p><h2>More than an agent.<br>A partner <em class="it">on your side.</em></h2></div><p class="note">Everything below is standard for every store we work with, not an upsell.</p></div>
  <div class="feats">{feats}</div>
</div></section>

<section class="ds" id="promises"><div class="hw">
  <p class="mono acc" data-r>Promises · 承诺</p>
  <h2 data-r>Promises are <em class="it">cheap.</em><br>Ours are <em class="it">specific.</em></h2>
  <p class="lead" data-r>No vague “fast shipping” and “top quality”. These are the rules we work by, so you know what to expect before your first order.</p>
  <div class="pgrid" data-r>{prom}</div>
  <ul class="dots" data-r><li>No contract and no subscription. You top up a balance and can stop whenever you want.</li><li>Doing volume? Then we sit down and agree targets for your store together.</li></ul>
</div></section>

<section class="cs"><div class="hw">
  <p class="mono acc" data-r>Your portal · 后台</p>
  <h2 data-r>One portal.<br><em class="acc it">Everything in it.</em></h2>
  <p class="lead" data-r>Your whole chain in one place: prices, orders, tracking, balance and photos. And when you'd rather ask a person, we are one message away.</p>
  <div class="dash">
    <div data-r>{dash}<div class="tags"><span>Live prices</span><span>Orders &amp; tracking</span><span>One-click top up</span><span>QC photos</span></div></div>
    <div class="dcard" data-r><p class="mono acc">app.shipdao.nl</p><h3>Everything in it.</h3><div class="ln"><span>All-in prices</span><b>Live</b></div><div class="ln"><span>Orders &amp; tracking</span><b>Live</b></div><div class="ln"><span>Top up balance</span><b>1 click</b></div><div class="ln"><span>Shopify sync</span><b>Auto</b></div><p class="mono dim">And a person one message away</p></div>
  </div>
</div></section>

<section class="cs" id="scale" style="padding-top:0"><div class="hw">
  <p class="mono acc" data-r>Scaling · 增长</p>
  <h2 data-r>The more you sell,<br>the <em class="acc it">cheaper</em> it gets.</h2>
  <p class="lead" data-r>Simple: the more volume you do, the more volume we do. So as your winner grows, we work to bring your cost per order down.</p>
  <div class="gcard" data-r><p class="mono acc">Fulfilment + growth</p><h3>We bring the <em class="acc it">orders</em> too.</h3>
    <p class="ar"><b>→</b><span><strong>Meta and TikTok ads.</strong> Run by the same team that ships your orders, so marketing and stock stay in sync.</span></p>
    <p class="ar"><b>→</b><span><strong>Email flows and campaigns.</strong> Welcome, abandoned cart and branded tracking emails in Klaviyo.</span></p>
    <p class="ar"><b>→</b><span><strong>A weekly call on your numbers.</strong> What sold, what it cost, and what we change next.</span></p>
    <div class="tags"><span>Ads</span><span>Email</span><span>Weekly call</span></div></div>
  <div class="s3" data-r>
    <div><p class="pn acc">Better prices</p><p class="mono">Renegotiated</p><p>At higher volumes we go back to the factory and pass the better price on to you.</p></div>
    <div><p class="pn acc">Your box</p><p class="mono">Branded packaging</p><p>At higher volumes, custom packaging can be built into your price per order.</p></div>
    <div><p class="pn acc">Bulk</p><p class="mono">When it pays off</p><p>Once a product sells steadily, we buy it in bulk for you: lower unit price, faster dispatch.</p></div>
  </div>
</div></section>

<section class="cs" id="plans" style="padding-top:0"><div class="hw">
  <div class="split" data-r><div><p class="mono acc">Plans · 方案</p><h2>Start with fulfilment.<br><em class="it">Grow with us.</em></h2></div><p class="note">No stock, no minimums, no subscription. You pay per order from a prepaid balance.</p></div>
  <div class="plans">{plans}</div>
</div></section>

<section class="cs" id="difference" style="padding-top:0"><div class="hw narrow">
  <p class="mono acc" data-r>The difference · 区别</p>
  <h2 data-r>Your agent answers tomorrow.<br><em class="it">We answer today.</em></h2>
  <div class="vs" data-r><div class="vc them"><p class="mono">Typical agent</p>{them}</div><span class="vsb">VS</span><div class="vc us"><p class="mono acc">Shipdao</p>{us}<a class="mono acc lk" href="#contact">Switch in about a week →</a></div></div>
</div></section>

<section class="cs belief"><div class="hw">
  <p class="mono acc c" data-r>Our belief · 信念</p>
  <h2 class="c" data-r>Your supplier isn't a line item. It's<br>your <em class="acc">most important partner.</em></h2>
  <div class="b3" data-r>
    <div><p class="mono acc">01 · Personal contact</p><h3>You know who you talk to.</h3><p>One contact who knows your products, your margins and your customers. No ticket numbers.</p></div>
    <div><p class="mono acc">02 · Built for growth</p><h3>We win when you grow.</h3><p>We earn per order, not per hour or per month. Your growth is our business model.</p></div>
    <div><p class="mono acc">03 · No lock-in</p><h3>Built for the long run.</h3><p>No contract and no lock-in. We keep you because the work is good, not because you are stuck.</p></div>
  </div>
  <div class="founder" data-r><span class="seal lg">道</span><div><p>“I started Shipdao because dropshippers kept telling me the same thing: the product sells, but the supplier holds them back.”</p><b class="mono">Thijmen · founder</b></div></div>
</div></section>

<section class="cs" id="faq"><div class="hw faq">
  <div data-r><h2>The questions every dropshipper asks first.</h2><p class="lead">Something else on your mind? Message us and you hear back the same day.</p><a class="mono acc lk" href="#contact">Get your price check →</a></div>
  <div class="acc-list" data-r>{faq}</div>
</div></section>

<section class="cs end" id="contact"><div class="hw">
  <p class="mono acc c" data-r>Free · quote within 24 hours</p>
  <h2 class="c huge" data-r>Let's ship it<span class="acc">.</span></h2>
  <p class="lead c" data-r>Send your products and see your all-in price per order before you switch. Doing 10+ orders a day? We also compare it with what you pay now.</p>
  <p class="mono c dim small" data-r>Now onboarding our founding stores. The first 10 get founding rates<br>and a direct line to the founder.</p>
  <form class="form" id="price-form" data-r><div class="fr">
    <div><label for="f-store">Store URL</label><input id="f-store" name="store" placeholder="yourstore.com" required></div>
    <div><label for="f-orders">Orders per day</label><select id="f-orders" name="orders"><option>Under 10</option><option>10 to 50</option><option>50 to 200</option><option>200+</option></select></div>
    <div><label for="f-email">Email</label><input id="f-email" name="email" type="email" placeholder="you@yourstore.com" required></div></div>
    <input class="hp" name="hp_field" tabindex="-1" autocomplete="off" aria-hidden="true">
    <button class="btn" type="submit">Send my price check</button>
    <div class="ok">Thanks! You get your all-in price within 24 hours.</div>
    <p class="alt">Prefer to talk? Email <a href="mailto:{EMAIL}">{EMAIL}</a><a href="#" data-wa> or WhatsApp us</a>.</p>
  </form>
</div></section>
</main>""" + HFOOT


# ---- docs ----
CH = [
 ("how", "How Shipdao works", "What we do, what you do, and where the line between the two sits.", [
  ("What we do", [("p", "Shipdao is the fulfilment side of your store. Your shop stays in Shopify. Orders that come in there arrive with us automatically; we buy the product, check it, pack it and ship it to your customer. You see all of it, and what it costs, in your portal.")], ("d1-overview.png", "Your overview: balance, top-up and your prices.")),
  ("The loop, in five steps", [("ol", ["Your customer orders in your Shopify store.", "The order appears in your portal within seconds.", "It is paid from your balance at the agreed all-in price.", "We buy, check, pack and ship it.", "The tracking number lands in Shopify and your customer gets the shipping email."])], None),
  ("What you actually do", [("ul", ["Keep your balance topped up.", "Make sure new products have a price before you advertise them.", "Glance at anything waiting on you: address problems and messages."])], None),
  ("What the portal is not", [("p", "It is not your store. Product pages, the prices your customers pay, refunds to your customers and your marketing all stay in Shopify. Changing something in the portal never changes your storefront.")], None)]),
 ("start", "Getting started", "From a free price check to your first order.", [
  ("Free price check", [("p", "Send your products through the price check on this site. Within 24 hours you get an all-in price per order, shipping included, so you know your margin before you switch.")], None),
  ("Create your account", [("p", "Go to app.shipdao.nl, choose Sign up, fill in your store name, your name, email and a password, and accept the terms.")], None),
  ("Logging in", [("p", "Your portal lives at app.shipdao.nl. Forgot your password? Use “Forgot password?” on the login screen. Give each colleague their own login rather than sharing one.")], None)]),
 ("shopify", "Connecting Shopify", "One click, about a minute. No app to build, no keys to send.", [
  ("Connect your store", [("ol", ["In the portal, open Connect store.", "Type your .myshopify.com address (Shopify → Settings → Domains shows it).", "Click Connect Shopify and approve the permissions in Shopify.", "You land back in the portal with your products already imported."])], ("d2-connect.png", "Connect store: type your .myshopify.com address and approve.")),
  ("What we can see", [("p", "Your orders (to ship them), your products (to price them) and the fulfilment of orders we handle (to add tracking). Nothing else. Uninstall the app in Shopify and the connection stops immediately.")], None),
  ("New products and more stores", [("p", "Products you add or change in Shopify come in automatically; “Re-import from Shopify” pulls everything again. Running a second store? Connect it the same way; its orders use the same balance.")], None)]),
 ("products", "Products and prices", "A product needs an agreed price before we can ship it. This is where that happens.", [
  ("Your products", [("p", "Every product and variant from your store is listed, with your shop price, our all-in price and what you keep."), ("ul", ["Waiting for price: imported, not priced yet. Orders for it wait.", "Being sourced: we are getting prices from our suppliers.", "Priced: agreed price. Orders for it are charged and shipped automatically."])], ("d3-products.png", "Products: your shop price, our all-in price and what you keep.")),
  ("Every variant has its own price", [("p", "A red and a blue version can cost different amounts, so each variant is priced separately. An order is only charged when that exact variant has a price.")], None),
  ("The order to do things in", [("ol", ["Add the product to Shopify.", "Check it shows up under Products.", "Wait until it says Priced.", "Then switch on your ads."])], None),
  ("Questions about a product", [("p", "Every product has a chat. When we need your OK on a size, a colour or a replacement before we buy, we ask it there, with the product next to it.")], None)]),
 ("balance", "Balance and payments", "How you pay, how much to keep in, and the file your bookkeeper wants.", [
  ("How the balance works", [("p", "You keep a prepaid balance with us. Every order is charged from it at the agreed price the moment it comes in. If the balance runs out, orders wait until you top up, then go out automatically.")], None),
  ("Topping up", [("p", "Choose an amount and pay with iDEAL, Bancontact or card. Your balance updates within seconds.")], ("d4-balance.png", "Balance: top up online and export your statement.")),
  ("How much, how often", [("p", "Look at what you spend in a normal week and stay a week ahead. It costs nothing to sit in credit, and an empty balance is the most common reason orders sit still.")], None),
  ("Your statement", [("p", "Balance lists every top-up, charge and refund with your balance after each one. Pick a month and export it.")], None),
  ("Getting it back", [("p", "Stop whenever you want. Unused balance is refunded on request, as set out in our terms.")], None)]),
 ("orders", "Orders", "Every order from your store, with its status on our side.", [
  ("The orders page", [("p", "Filter by what needs you (waiting on you, address problem, processing for more than 5 days), search by order, customer, product or tracking number, pick a date range and export exactly that list.")], ("d5-orders.png", "Orders: filter by what needs you, search, export.")),
  ("What each status means", [("ul", ["Not paid in Shopify: your customer has not paid yet. Nothing is charged; it ships once Shopify marks it paid.", "Paid: charged from your balance, queued for packing.", "Sent to agent: being bought and packed.", "Shipped: on its way, tracking is in Shopify.", "On hold: your balance was too low. Top up and it goes out.", "Issue: a product in it has no price yet.", "Address problem: we cannot deliver to this address.", "Cancelled: cancelled in Shopify or by us; what you paid went back to your balance."])], None),
  ("Inside an order", [("p", "Click any order for the delivery address, what your customer paid, our price and what you keep, the tracking, quality-check photos and a chat with us about that order.")], ("d6-order-detail.png", "Inside an order: fix an address, see your margin, chat with us.")),
  ("Address problems", [("p", "If a carrier rejects an address (missing house number, wrong postcode), the order stops and shows in red. Open it, correct the address and save: it goes straight back into the queue. These never fix themselves, so check them daily.")], None),
  ("“My order isn’t here”", [("p", "Usually it is not paid in Shopify yet, it was placed before you connected your store, or it has nothing that needs shipping. Still missing? Message us with the Shopify order number.")], None)]),
 ("tracking", "Shipping and tracking", "From our warehouse to your customer’s door.", [
  ("Tracking goes to Shopify", [("p", "When an order ships, the tracking number appears in your portal and in Shopify, and Shopify emails your customer. You do not have to do anything.")], None),
  ("“Where is my order?”", [("p", "Search the order number under Orders and send your customer the tracking link. Delivery time depends on the product and the route; your quote shows it per country.")], None),
  ("Lost or damaged", [("p", "No delivery scan 30 days after shipping? Message us with the order number and we reship it or credit the order price to your balance. Damaged or wrong item: send photos within 14 days of delivery.")], None)]),
 ("quality", "Quality checks and messages", "See what goes in the box, and talk to us about it.", [
  ("Quality-check photos", [("p", "Our team photographs what goes in the box. The photos appear with the order in your portal, so you see what your customer will get.")], None),
  ("Messages", [("p", "Every order and every product has its own chat with us, so the conversation stays with the thing it is about. A red dot in the menu means something is waiting for you.")], None)]),
 ("routine", "Your routine", "You don’t need to work the portal. You need to check it.", [
  ("Every day, two minutes", [("ul", ["Overview: anything waiting? Address problems first.", "Red dots: unread messages from us.", "Balance: enough for the next few days?"])], None),
  ("Every week", [("ul", ["Products: anything new waiting for a price?", "Orders: anything processing for more than 5 days?", "Top up so you stay a week ahead."])], None),
  ("Every month", [("ul", ["Balance → pick the month → export for your bookkeeping.", "Spot-check a few orders: is your margin still what you think it is?"])], None)]),
 ("help", "Help", "How to reach a person.", [
  ("Talk to a person", [("p", f"Message us on WhatsApp or email {EMAIL}. You talk to the same person every time and hear back the same day.")], None),
  ("The fine print", [("p", "Our terms, privacy statement and data processing agreement are in your portal at app.shipdao.nl.")], None)]),
]

def docs():
    toc = "".join(f'<a href="#{cid}"><span>{i+1:02d}</span>{E(t)}</a>' for i, (cid, t, _, _) in enumerate(CH))
    body = ""
    for i, (cid, title, intro, subs) in enumerate(CH):
        cards = ""
        for j, (st, blocks, img) in enumerate(subs):
            inner = ""
            for kind, c in blocks:
                if kind == "p": inner += f"<p>{E(c)}</p>"
                else: inner += f"<{kind}>" + "".join(f"<li>{E(x)}</li>" for x in c) + f"</{kind}>"
            fig = f'<figure><img src="/img/{img[0]}" alt="{E(img[1])}" loading="lazy"><figcaption>{E(img[1])}</figcaption></figure>' if img else ""
            cards += f'<div class="dcard" id="{cid}-{j+1}" data-r><h3><span>{i+1}.{j+1}</span>{E(st)}</h3>{inner}{fig}</div>'
        body += f'<section class="chap" id="{cid}"><p class="eb">Chapter {i+1:02d}</p><h2>{E(title)}</h2><p>{E(intro)}</p>{cards}</section>'
    cta = '<div class="dcard" style="background:var(--rice);border:0"><h3>Ready to see your price per order?</h3><p class="muted">Send your products through the free price check, or create your account straight away.</p><p style="margin-top:14px"><a class="btn" href="#" data-portal="/#/signup">Create your free account →</a></p></div>'
    return head("Documentation · Shipdao", "How Shipdao works: connecting Shopify, prices, balance, orders, tracking and quality checks, explained step by step.", "/docs") + NAV + f"""
<main><section class="dhead"><div class="wrap"><p class="eb">Documentation · 文档</p><h1>Everything about Shipdao</h1><p>How we work, how to connect your store, and every page of your portal explained. Every section has a number, so “6.4” is a link you can send to anyone.</p></div></section>
<section class="dbody"><div class="wrap dcols"><nav class="toc">{toc}</nav><div>{body}{cta}</div></div></section></main>""" + FOOT

NOTFOUND = head("Page not found · Shipdao", "This page does not exist.", "/404") + NAV + '<main class="sec"><div class="wrap" style="text-align:center"><h1>Page not found</h1><p class="sub" style="margin:16px auto 28px">This page does not exist (any more).</p><a class="btn" href="/">Back to the homepage</a></div></main>' + FOOT

(OUT / "index.html").write_text(home(), encoding="utf-8")
(OUT / "docs.html").write_text(docs(), encoding="utf-8")
(OUT / "404.html").write_text(NOTFOUND, encoding="utf-8")
print("built", [p.name for p in OUT.glob("*.html")])
