# Shipdao: live zetten

De database en alle edge functions draaien al op Supabase-project `yjkbjljnnikfqvzvzulg`.
Wat nog moet gebeuren kan alleen jij doen (accounts en geheime sleutels).

## 1. Online zetten: Framer (site) + Vercel (portal)
Opzet:
- `shipdao.nl` → **Framer**: je publieke site (home, how it works, FAQ, partners)
- `app.shipdao.nl` → **Cloudflare** (Workers) of Vercel: de portal (`public/index.html`), login en dashboard
- **Supabase** blijft de backend: database, betalingen, Shopify

**Cloudflare (aanrader, gratis en commercieel gebruik mag)**
1. dash.cloudflare.com → Workers & Pages → Create → Import a repository → `shipdao`. `wrangler.jsonc` in de repo zegt: alleen de map `public/` gaat online.
2. Settings → Domains & Routes: zet de workers.dev-URL aan, en voeg `app.shipdao.nl` toe als Custom domain (daarvoor moet `shipdao.nl` bij Cloudflare in beheer zijn: nameservers omzetten bij je registrar).

**Of Vercel** (let op: gratis plan alleen niet-commercieel)
1. vercel.com → inloggen met GitHub → *Add New → Project* → kies `shipdao`.
2. Framework preset: **Other**. Build command: leeg. Output directory: leeg (`.`).
3. Deploy. `vercel.json` en `.vercelignore` zitten al in de repo (beveiligingsheaders; database-bestanden en notities gaan niet online).
4. Settings → Domains → voeg `app.shipdao.nl` toe en zet het DNS-record dat Vercel noemt bij je domeinregistrar.
5. Elke push naar de production branch zet automatisch een nieuwe versie online.

**Framer**
1. Publiceer je Framer-site op `shipdao.nl`.
2. Knoppen "Log in" → `https://app.shipdao.nl/#/login`, "Get started" → `https://app.shipdao.nl/#/signup`.
3. In `public/index.html`: zet `CONFIG.SITE_URL = "https://shipdao.nl"`. De portal toont dan geen eigen homepage meer maar meteen de login, en het logo linkt naar Framer.
4. Link vanuit Framer naar de juridische pagina's in de portal: `https://app.shipdao.nl/#/terms`, `#/privacy`, `#/dpa` (die moeten bij de portal blijven vanwege de aanmeldcheckbox).

Noteer de portal-URL (`https://app.shipdao.nl`), die heb je hieronder nodig.

In Supabase → Authentication → URL Configuration:
- **Site URL** = je portal-URL (Vercel, bv. `https://app.shipdao.nl`)
- **Redirect URLs** = dezelfde URL toevoegen

## 2. Shopify-app maken
Shopify Partners (partners.shopify.com) → Apps → Create app → handmatig.
- **App URL**: je portal-URL (Vercel)
- **Allowed redirection URL**: `https://yjkbjljnnikfqvzvzulg.supabase.co/functions/v1/shopify-callback`
- **Compliance webhooks** (alle drie): `https://yjkbjljnnikfqvzvzulg.supabase.co/functions/v1/shopify-webhook`
- **API access → Protected customer data**: aanvragen voor naam + adres
  (zonder dit komen orders niet binnen, want je hebt het verzendadres nodig)
- **Distribution**: "Custom distribution" per klantwinkel, of "Public / unlisted" als je veel klanten hebt.

## 3. Mollie (online opwaarderen)
1. Maak een account op mollie.com. Je hebt een **KvK-nummer** nodig, plus een ID-check en een zakelijke rekening (of je privérekening als eenmanszaak).
2. Mollie controleert je website. Daarvoor moeten je bedrijfsgegevens, voorwaarden en privacyverklaring zichtbaar zijn. Die pagina's zitten al in de portal; vul alleen `CONFIG.COMPANY` bovenin `public/index.html` in.
3. Zet iDEAL (en eventueel Bancontact en creditcard) aan onder *Betaalmethodes*.
4. Kopieer je API-key: eerst `test_...` om te testen, daarna `live_...`.

## 4. Secrets in Supabase
Supabase → Edge Functions → Secrets:

| Naam | Waarde |
|---|---|
| `SHOPIFY_API_KEY` | Client ID van je Shopify-app |
| `SHOPIFY_API_SECRET` | Client secret van je Shopify-app |
| `APP_URL` | je portal-URL (stap 1) |
| `MOLLIE_API_KEY` | `test_...` om te testen, later `live_...` |

## 5. Testen
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

## Checklist voordat je live gaat
- [ ] Ingeschreven bij de KvK en btw-nummer ontvangen
- [ ] `CONFIG.COMPANY` in `public/index.html` ingevuld (anders zie je als admin een gele waarschuwing)
- [ ] Voorwaarden en privacyverklaring doorgelezen. Kloppen de 30 dagen voor verloren pakketten en de aansprakelijkheid voor jou? Laat ze bij twijfel checken.
- [ ] Met je agent of magazijn in China de **standaardcontractbepalingen (SCC's)** afgesproken. Je stuurt adressen van EU-consumenten naar China, en dat mag alleen met zo'n afspraak.
- [ ] Mollie goedgekeurd, `MOLLIE_API_KEY` vervangen door de `live_`-key
- [ ] Testbetaling van €10 gedaan en gezien dat die in het saldo verschijnt
- [ ] Shopify-app goedgekeurd voor klantgegevens
- [ ] Testklant en testorders verwijderd

## Hoe online opwaarderen werkt
- De klant kiest een bedrag (€10 tot €5.000) en betaalt bij Mollie.
- Mollie roept `mollie-webhook` aan. Die vraagt de betaling **zelf** op bij Mollie, met jouw sleutel, en boekt pas daarna het saldo bij. Een nep-melding levert dus niks op.
- Elke betaling wordt maar één keer bijgeboekt. Een chargeback haalt het bedrag weer van het saldo af.
- Wachtende orders worden direct afgerekend zodra er saldo bij komt.
- De transactiekosten van Mollie zijn voor jou.
