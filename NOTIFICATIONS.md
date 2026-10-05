# Upozornenia z KLUBU — edge function `notify-emails`

Klub len ohlási udalosť; všetko ostatné (nastavenia, throttling, príjemca, šablóna,
SmartEmailing, log) je vo funkcii. E-maily sú naša vlastná šablóna
(`_shared/email-layout.ts`), nie uložená SmartEmailing šablóna.

| `kind` | Predmet | Tlačidlo → |
| --- | --- | --- |
| `message` | {actor} ti poslala správu | Prečítať správu → `/spravy?chat=<ref>` |
| `pair_request` | {actor} ti poslala žiadosť o parťáčku | Zobraziť žiadosť → `/partacky` |
| `pair_accepted` | {actor} prijala tvoju žiadosť o parťáčku | Otvoriť parťáčky → `/partacky` |

V poznámke odkaz na vypnutie: `/profil#upozornenia`. Odosielateľ „KLUB trénera ŽIEN“,
tag `klub-upozornenie`.

## Volanie z klubu (fire-and-forget)

```ts
await fetch(`${SUPABASE_URL}/functions/v1/notify-emails`, {
  method: "POST",
  headers: { "Content-Type": "application/json", Authorization: `Bearer ${callerJwt}` },
  body: JSON.stringify({ kind, recipient_id, actor_id, ref }),
}).catch(() => {});
```

`ref` = `pair_requests.id` — pri správe je to chat (`direct_messages.pair_id`), pri
žiadosti / prijatí samotná žiadosť. **Povinné** (overuje sa ním vzťah).

| Odpoveď | Kedy |
| --- | --- |
| 200 `{ ok: true, status: "sent" \| "skipped_pref" \| "skipped_throttle" \| "skipped_no_email" }` | |
| 400 `bad_request` | zlý `kind`, chýbajúce / neplatné uuid, `recipient_id = actor_id` |
| 401 `unauthorized` | chýbajúci / neplatný JWT |
| 403 `forbidden` / `not_a_member` / `not_related` | JWT ≠ `actor_id` / bez profilu alebo `membership_paused_at` / `ref` nie je ich pár (pri žiadosti `from = actor`, pri prijatí `from = recipient`) |
| 502 `{ ok: false, status: "failed" }` | SmartEmailing zlyhal (detail len v logu a `notification_emails.error`) |

## Poradie

1. JWT → `user.id === actor_id`, profil existuje a nie je pozastavený.
2. Validácia + `pair_requests` medzi nimi.
3. `notification_prefs` (`email_messages` / `email_pairs`; chýbajúci riadok = zapnuté).
4. Throttle: `notification_emails` pre príjemcu, `kind` a `ref` za posledných
   60 min (správy) / 5 min (žiadosti).
5. Príjemca: `profiles.email`, oslovenie `nickname || full_name`. Autor:
   `full_name || nickname || "Členka klubu"`.
6. SmartEmailing (transakčný, `message_contents`).
7. Log do `notification_emails` aj pri chybe → throttle pokryje aj opakovania.

## Nasadenie

1. Secrets `SMARTEMAILING_*` (už sú), voliteľne `CLUB_PUBLIC_URL=…` cez `12-set-booking-secrets.sh`.
2. `supabase/web/bin/15-deploy-klub-emails.sh`
3. Test vlastným JWT (napr. správa v testovacom chate) → `notification_emails` má riadok s `error = null`.

Náhľad všetkých troch e-mailov (nič neposiela):

```bash
npx -y deno run -A supabase/functions/notify-emails/preview.ts [výstupný-priečinok]
```

Logy: Dashboard → Edge Functions → `notify-emails` (`[notify]`).
