# Pozvánky do KLUBU — edge function `send-invitations`

Admin (Členstvá → Import) pošle členkám e-mail s odkazom na nastavenie hesla.
Presunuté z Lovable appky (`sendInvitesBatch`, `sendInviteToEmail`); e-mail je
naša vlastná šablóna (rovnaký layout ako rezervácie), nie SmartEmailing šablóna 1177.

```
admin ──POST send-invitations (Bearer JWT)──▶ has_role(admin)
                                              výber členiek (profiles.invitation)
                                              per členka: generateLink(recovery) → hashed_token
                                              SmartEmailing ── e-mail „Vitaj v klube.“
                                              profiles.invitation = 'invited', invited_at
členka ──klik──▶ klub.trenerzien.sk/nove-heslo?t=<hashed_token>
                 submit: verifyOtp({ token_hash, type: 'recovery' }) → updateUser({ password })
                 → profiles.invitation = 'accepted'
```

| Čo | Kde |
| --- | --- |
| Funkcia | `supabase/functions/send-invitations/index.ts` |
| Šablóna | `send-invitations/email.ts` (layout `_shared/email-layout.ts`) |
| Deploy | `supabase/web/bin/15-deploy-klub-emails.sh` (nasadí aj `notify-emails`) |

## Volanie z appky

```ts
// dávka — appka volá opakovane, kým remaining === 0 alebo sent === 0
const { data } = await supabase.functions.invoke("send-invitations", {
  body: { mode: "batch", siteUrl: window.location.origin, limit: 500, audience: "none", group: "founders_former" },
});
// data = { sent, failed: [{ email, error }], remaining }

// jedna adresa (markInvited: false = test, stav profilu sa nemení; default true)
const { data } = await supabase.functions.invoke("send-invitations", {
  body: { mode: "single", siteUrl: window.location.origin, email: "anna@example.sk", markInvited: true },
});
// data = { ok: true, inviteUrl } | { ok: false, error }   ("Takýto e-mail v klube nie je.")
```

| Pole (batch) | Hodnoty | Default | Význam |
| --- | --- | --- | --- |
| `limit` | 1–500 | 500 | max. členiek v jednom volaní |
| `audience` | `none` / `invited` | `none` | nikdy nepozvané / pozvané, ktoré nereagovali (znova poslať) |
| `group` | `founders_former` / `all` | `founders_former` | `founder_at` alebo `membership_ends_on` vyplnené |
| `emails` | string[] | – | po výbere poslať len na tieto adresy |

Chyby: 401 bez prihlásenia, 403 nie admin, 400 zlé pole, 500 chýbajú SmartEmailing secrets.

## Pravidlá

- **Len členky klubu:** `memberships.name` ∈ Zakladateľské členstvo (ročné / mesačné /
  prevodom), Sprievodkyňa klubu ∪ `profiles.membership_ends_on is not null` (bývalé).
  `single` pošle na akýkoľvek existujúci účet (aj test na vlastnú adresu).
- **Odkaz** vždy na `https://klub.trenerzien.sk/nove-heslo` — `siteUrl` z appky sa
  ignoruje (nikdy preview / localhost).
- **`hashed_token`, nie `action_link`:** skenery v Gmaile / Outlooku otvárajú odkazy
  a `/auth/v1/verify` by token spotrebovali. `/nove-heslo` overuje až pri odoslaní.
- **Každý nový odkaz zneplatní predošlý** — neposielať dvakrát po sebe.
- **Platnosť 7 dní** = Supabase Auth → Email OTP expiry (text e-mailu to uvádza).
- **SmartEmailing:** transakčný e-mail, 1 príjemca na request, 12 paralelne
  (bulk s vlastným HTML má limit 5; `custom-emails-bulk` vyžaduje uloženú šablónu).
  Odosielateľ „KLUB trénera ŽIEN“, tag `klub-nastavenie-hesla`. Ak SmartEmailing
  zamietne (napr. rate limit), členka je vo `failed` a ostáva `none` → ďalšia dávka ju skúsi znova.

## Nasadenie

1. Secrets `SMARTEMAILING_*` (už nastavené pre rezervácie, `12-set-booking-secrets.sh`).
2. `supabase/web/bin/15-deploy-klub-emails.sh` (nasadí aj `notify-emails`)
3. Test: `single` s `markInvited: false` na vlastnú adresu → klik → nastav heslo.

Náhľad e-mailu (nič neposiela):

```bash
npx -y deno run -A supabase/functions/send-invitations/preview.ts [výstupný-priečinok]
```

Logy: Dashboard → Edge Functions → `send-invitations` (`[invite]`).
