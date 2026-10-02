# Web — Supabase backend

Web tabuľky žijú v **tom istom** Supabase projekte ako Výzva
(`trenerzien-backend/.env`). Skripty sú v `supabase/web/bin/`.

| Skript | Čo robí |
| --- | --- |
| `01-apply.sh` | `consultation_applications` + seed dáta (`0.sql`, `1.sql`) |
| `02-validate.sh` | kontrola po `01` |
| `03-apply-kniha.sh` | `stripe_events` + `book_orders` pre /kniha webhook (`2.sql`) |
| `04-deploy-kniha-webhook.sh` | nasadí edge function `stripe-kniha-webhook` |
| `05-apply-subscriptions.sh` | `memberships.stripe_subscription_id` / `stripe_customer_id` (`3.sql`) |
| `06-deploy-stripe-webhook.sh` | nasadí edge function `stripe-webhook` (predplatné KLUB) |
| `07-backfill-stripe-ids.sh` | doplní `stripe_subscription_id` / `stripe_customer_id` existujúcim `source='stripe'` členstvám podľa e-mailu (`STRIPE_SECRET_KEY=rk_live_… ./07-backfill-stripe-ids.sh`, po `05`) |
| `08-apply-booking.sh` | rezervácia pohovoru — tabuľky, RPC, RLS (`4.sql`), viď `BOOKING.md` |
| `09-deploy-booking.sh` | nasadí edge functions `book-meeting` a `cancel-meeting` |
| `10-add-helper.sh` | pridá helpera (+ voliteľne týždennú dostupnosť) |
| `11-google-refresh-token.sh` | jednorazovo získa Google refresh token master účtu |
| `12-set-booking-secrets.sh` | nastaví Google / SmartEmailing / CORS secrets z env premenných |

---

## Stripe webhook pre /kniha

Kód: `supabase/functions/stripe-kniha-webhook/`

- `index.ts` — overí Stripe podpis, idempotencia cez `stripe_events`, dispatch eventov
- `stripe.ts` — načítanie Checkout Session z API (HMAC overenie podpisu je v `_shared/stripe.ts`)
- `fulfill.ts` — routing podľa `lookup_key` ceny, Pack4you (stub), prístup do Výzvy

### Routing podľa `lookup_key`

| lookup_key | Akcia |
| --- | --- |
| `kniha_packeta_sk` | zásielka Pack4you, Packeta |
| `kniha_dpd_sk` | zásielka Pack4you, DPD |
| `kniha_kurier_cz` | zásielka Pack4you, CZ kuriér |
| `balik_premena_vyzva_kniha` | zásielka Pack4you (dopravca `BUNDLE_CARRIER` vo `fulfill.ts`, zatiaľ Packeta) + členstvo `Výzva` |
| `audiokniha` | členstvo `Audiokniha` (cena v Stripe ešte neexistuje) |

Prístup = nájdi účet podľa emailu v `profiles`, inak ho vytvor
(`auth.admin.createUser`, trigger založí profil a rolu). Potom sa pridá riadok
do `memberships` (`status='active'`, bez `ends_at`), ak rovnaké aktívne
členstvo ešte nemá.

**Nové účty nemajú heslo.** V `/admin/users` sa zobrazia ako nepozvané — admin
im pošle pozvánku tlačidlom „Pozvať".

### Nasadenie — krok za krokom

1. **Tabuľky:** `supabase/web/bin/03-apply-kniha.sh`
2. **Deploy:** `supabase login` (raz), potom
   `supabase/web/bin/04-deploy-kniha-webhook.sh`. Skript vypíše URL pre test a live.
3. **Stripe endpointy** (zvlášť v test aj live móde):
   Developers → Webhooks → Add endpoint
   - URL: `…/functions/v1/stripe-kniha-webhook?env=test` (resp. `?env=live`)
   - Events: `checkout.session.completed`,
     `checkout.session.async_payment_succeeded`,
     `checkout.session.async_payment_failed`
   - Skopíruj **Signing secret** (`whsec_…`). Je to nový secret — tie z
     existujúceho app webhooku tu nefungujú.
4. **Restricted API kľúč** (test aj live): Developers → API keys → Create
   restricted key → *Checkout Sessions: Read*, ostatné None.
5. **Secrets** v Supabase: Dashboard → Edge Functions → Secrets
   (`https://supabase.com/dashboard/project/<ref>/functions/secrets`)

   | Názov | Hodnota |
   | --- | --- |
   | `STRIPE_KNIHA_WEBHOOK_SECRET_TEST` | `whsec_…` z test endpointu |
   | `STRIPE_KNIHA_WEBHOOK_SECRET_LIVE` | `whsec_…` z live endpointu |
   | `STRIPE_SECRET_KEY_TEST` | `rk_test_…` |
   | `STRIPE_SECRET_KEY_LIVE` | `rk_live_…` |
   | `PACK4YOU_API_KEY` | neskôr, keď bude Pack4you API |

   `SUPABASE_URL` a `SUPABASE_SERVICE_ROLE_KEY` sú dostupné automaticky.

### Odpovede a chyby

- `400` — zlý podpis alebo chýba `?env=test|live`.
- `500` — chýbajú secrets pre dané `env` (Stripe bude skúšať znova).
- `200` — všetko ostatné, aj chyba pri spracovaní. Vtedy má
  `book_orders.status = 'error'` a dôvod v stĺpci `error`. Riadok v
  `stripe_events` sa zmaže, takže po oprave stačí v Stripe pri evente dať
  **Resend**.

Stavy v `book_orders.status`: `received` → `awaiting_payment` (prevod ešte
nedorazil) → `awaiting_shipment` (zaplatené / prístup udelený, zásielka ešte
nevytvorená) → `fulfilled`. Ďalej `shipped` (ručne), `payment_failed`, `error`.

Kým nie je hotové Pack4you API, knižné objednávky zostávajú
v `awaiting_shipment`:

```sql
select created_at, email, name, phone, carrier, shipping
from public.book_orders
where status = 'awaiting_shipment' and env = 'live'
order by created_at;
```

### Test

```bash
# 1. bez podpisu → 400 (401 by znamenalo, že JWT overovanie nie je vypnuté)
curl -i -X POST "https://<ref>.supabase.co/functions/v1/stripe-kniha-webhook?env=test" -d '{}'

# 2. Stripe CLI (dočasne daj jeho whsec_ do STRIPE_KNIHA_WEBHOOK_SECRET_TEST)
stripe listen --forward-to "https://<ref>.supabase.co/functions/v1/stripe-kniha-webhook?env=test"
stripe trigger checkout.session.completed
# → book_orders riadok so status 'error' (neznámy lookup_key) = cesta funguje
```

Potom skutočný testovací nákup na `/kniha` pre každý `lookup_key` a kontrola
`book_orders`, `profiles` a `memberships`. Resend toho istého eventu nesmie
vytvoriť druhé členstvo.

Logy: Dashboard → Edge Functions → stripe-kniha-webhook → Logs.

---

## Stripe webhook pre predplatné KLUB

Kód: `supabase/functions/stripe-webhook/` (+ spoločné `supabase/functions/_shared/`)

- `index.ts` — overí Stripe podpis, idempotencia cez `stripe_events`, z eventu zistí ID predplatného
- `membership.ts` — routing podľa `lookup_key`, mapovanie stavu predplatného na `memberships`

Každý event sa zredukuje na ID predplatného, predplatné sa **znova načíta zo
Stripe API** (`expand[]=customer`) a jeho aktuálny stav sa zapíše (upsert) do
jedného riadku `memberships` podľa `stripe_subscription_id`. Poradie ani
opakovanie eventov preto nevadí. Používateľ sa páruje podľa e-mailu zákazníka
(ak neexistuje, vytvorí sa — rovnako ako pri /kniha).

### Eventy (zapnúť na endpointe)

`customer.subscription.created`, `customer.subscription.updated`,
`customer.subscription.deleted`, `invoice.paid`, `invoice.payment_failed`

Endpoint: `https://<ref>.supabase.co/functions/v1/stripe-webhook?env=test|live`

### Routing podľa `lookup_key`

| lookup_key | `memberships.name` |
| --- | --- |
| `klub_mesacne` | Členstvo KLUB — mesačné |
| `klub_stvrtrocne` | Členstvo KLUB — štvrťročné |
| `klub_rocne` | Členstvo KLUB — ročné |

### Stav predplatného → členstvo

| Stripe `status` | `status` | `ends_at` |
| --- | --- | --- |
| `active`, `trialing` | `active` | koniec aktuálneho obdobia |
| `past_due` (Stripe skúša platbu znova) | `active` | koniec posledného zaplateného obdobia (nepredlžuje sa) |
| `paused` | `paused` | koniec posledného zaplateného obdobia |
| `unpaid`, `canceled`, `incomplete_expired` | `ended` | `ended_at` predplatného |
| `incomplete` | — (nič sa nezapíše, čaká sa na `invoice.paid`) | — |

`ends_at` pri Stripe riadkoch nikdy nie je `NULL` (to znamená doživotné členstvo).

### Secrets

| Secret | Hodnota |
| --- | --- |
| `STRIPE_WEBHOOK_SECRET_TEST` / `_LIVE` | `whsec_…` z endpointu `stripe-webhook` |
| `STRIPE_SECRET_KEY_TEST` / `_LIVE` | spoločný s /kniha; restricted key potrebuje aj **Subscriptions: read** a **Customers: read** |

### Odpovede

- `400` — chýba/zlé `env` alebo neplatný podpis
- `500` — chýbajú secrets **alebo spracovanie zlyhalo** (napr. neznámy
  `lookup_key`). Riadok v `stripe_events` sa zmaže a Stripe event automaticky
  pošle znova (až ~3 dni) — po oprave sa stav dorovná sám.
- `200` — spracované, duplikát, alebo ignorovaný event

### Test

```bash
curl -i -X POST "https://<ref>.supabase.co/functions/v1/stripe-webhook?env=test" -d '{}'   # → 400
stripe listen --forward-to "https://<ref>.supabase.co/functions/v1/stripe-webhook?env=test"
```

Scenáre v test mode (obnovy cez Stripe test clock): nové predplatné (karta
`4242…`) → `active`; posun hodín za obnovu → `ends_at` sa posunie; karta
`4000 0000 0000 0341` + posun → `past_due` (stále `active`, `ends_at` bez
zmeny), po vyčerpaní pokusov → `ended`; zrušenie → `ended`; Resend eventu →
duplikát, riadok bez zmeny.

Logy: Dashboard → Edge Functions → stripe-webhook → Logs (`[stripe]`, `[sync]`).
