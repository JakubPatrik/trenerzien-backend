# Web — Supabase backend

Web tabuľky žijú v **tom istom** Supabase projekte ako Výzva
(`trenerzien-backend/.env`). Skripty sú v `supabase/web/bin/`.

| Skript | Čo robí |
| --- | --- |
| `01-apply.sh` | `consultation_applications` + seed dáta (`0.sql`, `1.sql`) |
| `02-validate.sh` | kontrola po `01` |
| `03-apply-stripe-events.sh` | `stripe_events` — idempotencia Stripe webhooku (`2.sql`) |
| `05-apply-subscriptions.sh` | `memberships.stripe_subscription_id` / `stripe_customer_id` + názvy členstiev v `is_club_member()` (`3.sql`) |
| `06-deploy-stripe-webhook.sh` | nasadí edge function `stripe-webhook` (predplatné KLUB) |
| `07-backfill-stripe-ids.sh` | doplní `stripe_subscription_id` / `stripe_customer_id` existujúcim `source='stripe'` členstvám podľa e-mailu (`STRIPE_SECRET_KEY=rk_live_… ./07-backfill-stripe-ids.sh`, po `05`) |
| `13-sync-stripe-memberships.sh` | zosúladí prepojené členstvá so Stripe (stav, `ends_at`, názov) logikou webhooku; dry run → potvrdenie; `--create-missing` založí chýbajúce |
| `08-apply-booking.sh` | rezervácia pohovoru — tabuľky, RPC, RLS (`4.sql`), viď `BOOKING.md` |
| `09-deploy-booking.sh` | nasadí edge functions `book-meeting` a `cancel-meeting` |
| `10-add-helper.sh` | pridá helpera (+ voliteľne týždennú dostupnosť) |
| `11-google-refresh-token.sh` | jednorazovo získa Google refresh token master účtu |
| `12-set-booking-secrets.sh` | nastaví Google / SmartEmailing / CORS secrets z env premenných |

---

## Stripe webhook pre predplatné KLUB

Kód: `supabase/functions/stripe-webhook/` (+ spoločné `supabase/functions/_shared/`)

- `index.ts` — overí Stripe podpis, idempotencia cez `stripe_events`, z eventu zistí ID predplatného
- `membership.ts` — routing podľa `lookup_key`, mapovanie stavu predplatného na `memberships`

Každý event sa zredukuje na ID predplatného, predplatné sa **znova načíta zo
Stripe API** (`expand[]=customer`) a jeho aktuálny stav sa zapíše (upsert) do
jedného riadku `memberships` podľa `stripe_subscription_id`. Poradie ani
opakovanie eventov preto nevadí. Používateľ sa páruje podľa e-mailu zákazníka
(ak neexistuje, vytvorí sa bez hesla — admin mu pošle pozvánku z `/admin/users`).

### Eventy (zapnúť na endpointe)

`customer.subscription.created`, `customer.subscription.updated`,
`customer.subscription.deleted`, `invoice.paid`, `invoice.payment_failed`

Endpoint: `https://<ref>.supabase.co/functions/v1/stripe-webhook?env=test|live`

### Routing podľa `lookup_key`

| lookup_key | `memberships.name` |
| --- | --- |
| `klub_mesacne_clenstvo` | Členstvo — mesačné |
| `klub_stvrtrocne_clenstvo` | Členstvo — štvrťročné |
| `klub_rocne_clenstvo` | Členstvo — ročné |
| `zk_klub_mesacne_clenstvo`, `zk_klub_mesacne` | Zakladateľské členstvo — mesačné (live, 49 €) |
| `zk_klub_rocne_clenstvo`, `zk_klub_rocne` | Zakladateľské členstvo — ročné (live, 497 €) |

Prístup do KLUBu dáva `public.is_club_member()` **podľa názvu** — nový plán treba
pridať do `PLANS` (`membership.ts`) aj do zoznamu názvov v `3.sql` (`05-apply-subscriptions.sh`).

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
| `STRIPE_SECRET_KEY_TEST` / `_LIVE` | restricted key: **Subscriptions: read** a **Customers: read** |

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
