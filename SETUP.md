# Shipdao: live zetten

De database en alle edge functions draaien al op Supabase-project `yjkbjljnnikfqvzvzulg`.
Wat nog moet gebeuren kan alleen jij doen (accounts en geheime sleutels).

## 1. Portal online zetten
`index.html` is de hele portal. Zet hem online (Netlify Drop, Vercel, GitHub Pages, Cloudflare Pages).
Noteer de URL, bijvoorbeeld `https://portal.shipdao.nl/`.

In Supabase → Authentication → URL Configuration:
- **Site URL** = die URL
- **Redirect URLs** = dezelfde URL toevoegen

## 2. Shopify-app maken
Shopify Partners (partners.shopify.com) → Apps → Create app → handmatig.
- **App URL**: je portal-URL
- **Allowed redirection URL**: `https://yjkbjljnnikfqvzvzulg.supabase.co/functions/v1/shopify-callback`
- **Compliance webhooks** (alle drie): `https://yjkbjljnnikfqvzvzulg.supabase.co/functions/v1/shopify-webhook`
- **API access → Protected customer data**: aanvragen voor naam + adres
  (zonder dit komen orders niet binnen, want je hebt het verzendadres nodig)
- **Distribution**: "Custom distribution" per klantwinkel, of "Public / unlisted" als je veel klanten hebt.

## 3. Secrets in Supabase
Supabase → Edge Functions → Secrets:

| Naam | Waarde |
|---|---|
| `SHOPIFY_API_KEY` | Client ID van je Shopify-app |
| `SHOPIFY_API_SECRET` | Client secret van je Shopify-app |
| `APP_URL` | je portal-URL (stap 1) |

## 4. Testen
1. Maak een development store in Shopify Partners en zet er een paar producten in.
2. Log in op de portal als klant → Connect store → `jouwteststore.myshopify.com`.
3. Na goedkeuren kom je terug op **Products**: alle producten en varianten staan erin.
4. Log in als admin → **Products** → vul supplier-link en kosten in → status *priced* → Save.
5. Plaats een testorder in de winkel → hij verschijnt bij **Orders**, wordt afgeschreven van het saldo.
6. Tracking invullen → *Ship + tracking* → de klant krijgt de Shopify-verzendmail.

## Hoe het werkt
- Producten worden per **variant** opgeslagen. Nieuwe of gewijzigde producten in Shopify komen automatisch binnen (webhooks).
- Een order wordt alleen afgerekend als **die exacte variant** een prijs heeft. Anders krijgt hij status *issue*.
- Zodra je een product op *priced* zet en opslaat, worden orders die daarop wachtten automatisch opnieuw afgerekend.
- **Export for agent (CSV)** op de Products-pagina = lijst met alles wat nog gesourcet moet worden, voor je agent.
