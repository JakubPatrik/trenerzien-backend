# Double opt-in before the meeting invitation — consolidated requirements

Status: **backend built and tested locally, not deployed** (deploy: section 4.5). This merges Lovable's plan (website side)
with how the booking backend actually works today ([BOOKING.md](BOOKING.md)). Where the two
differ, the backend version below wins; section 5 contains the changes to send back to Lovable.

## 1. Problem and new flow

Today `book-meeting` confirms everything in one call: Google event + Meet link, then
SmartEmailing emails with `pozvanka.ics` to the lead, the helper and the owner, and the
lead goes onto list 615. If she mistyped her email (`gmail.comb`), the invite is lost and
nobody notices.

> Correction to Lovable's plan: Google does **not** email the lead. Google only notifies
> the owner (`pohovory@`). The lead and helper are added as silent guests, and the lead's
> invitation is **our** SmartEmailing email with `pozvanka.ics`. That email is what we hold
> back.

New flow:

```
/pohovor/termin ──POST book-meeting──▶ book_appointment() ── 'pending_opt_in', slot held 2 h
                                       SmartEmailing      ── "Potvrď svoj e-mail" (link with opt_in_token)
               website ──▶ /pohovor/potvrdenie (step 3/3: "Potvrď svoj e-mail")
email link ──▶ /pohovor/dakujem?t=<opt_in_token>
               ──POST confirm-meeting──▶ claim_opt_in()     ── 'pending', email_verified_at
                                         Google Calendar    ── event + Meet (owner notified, guests silent)
                                         appointments       ── 'confirmed'
                                         SmartEmailing      ── lead + helper + owner emails, list 615
cron (5 min) ──▶ booking-holds ──▶ expired holds → meeting-nudge to pohovory@ (assistant calls her)
```

## 2. Decisions

| # | Decision | Source |
| --- | --- | --- |
| 1 | An unconfirmed slot is held for **2 hours**, then released. | Lovable |
| 2 | When a hold expires, a `meeting-nudge` email goes to `BOOKING_OWNER_EMAIL` (`pohovory@trenerzien.sk`) so the assistant can call her. | Lovable |
| 3 | The owner's "new booking" email, the helper's email, the Google event and the list 615 import all happen **after** confirmation. | Lovable + backend |
| 4 | **No SmartEmailing double opt-in campaign.** We send our own transactional confirmation email (`booking-opt-in`, `_shared/email-layout.ts`) with the link. SmartEmailing's DOI needs a campaign email stored in SmartEmailing (`email_id`). Also, `application-submitted` already imports the lead to list 609 as `confirmed`, so a DOI might never be sent. Our own email is sent every time, uses our design, and proves the address just as well. | backend (deviation) |
| 5 | The link carries a dedicated `appointments.opt_in_token`, not the application token. | backend |
| 6 | An expired hold becomes `cancelled` with `cancel_reason = 'opt_in_expired'`, not a new `expired` status. This keeps `appointments_one_per_application` and the existing queries working, so she can book again. The frontend never sees the stored status. | backend (deviation) |
| 7 | The slot is freed **at** `opt_in_expires_at`, because `booking_slots()` and `book_appointment()` check the time. It does not wait for the cron. The cron only sends the nudges. | backend |
| 8 | If the confirmation email fails right away (SmartEmailing rejects the address), the nudge goes out **immediately**. The hold stays, so the assistant can still reach her. | backend |
| 9 | Release behind a flag (`BOOKING_DOUBLE_OPT_IN=true`) so the backend can go live before the website, and the website can switch over without a broken window. | backend |
| 10 | `application-submitted` keeps importing the lead to list 609 **immediately** after the questionnaire, before verification. No change. | Jakub |
| 11 | **Only an admin can resend** the confirmation email, optionally to a corrected address (section 4.3). There is no self-service resend. A woman whose email didn't arrive contacts support (`podpora@trenerzien.sk`), or the assistant reaches her after a nudge. | Jakub |
| 12 | **Unconfirmed holds are hidden from helpers.** KLUB never shows a `pending_opt_in` appointment or its questionnaire. Admins still see them, which support needs. | Jakub |

Invariant: hold (2 h) < `booking_settings.min_notice_minutes` (24 h), so a hold never
runs into the meeting itself.

## 3. Scope split

| Website — Lovable builds | Backend — we build |
| --- | --- |
| new `/pohovor/potvrdenie` (step 3/3, same funnel header), where `/pohovor/termin` lands: "Potvrď prosím svoj e-mail – poslali sme ti odkaz. Pozvánku na pohovor dostaneš hneď po potvrdení. Termín ti držíme do HH:MM." + SPAM/REKLAMA hint + podpora@ line | migration `12.sql` (section 4.1) |
| `/pohovor/dakujem?t=<token>` (the email link): calls `confirm-meeting`, states confirmed / expired / not_found / error. Without `?t=` it keeps today's copy (flag off). | `book-meeting` changes (4.2) |
| page calls `confirm-meeting` and only renders the result | new `confirm-meeting` (4.2) |
| `/pohovor/termin`: handle the changed `book-meeting` response (section 5) | new `booking-holds` + pg_cron (4.1, 4.2) |
| — | templates `booking-opt-in`, `meeting-nudge` (4.2) |

## 4. Backend — as built

### 4.1 Database — `supabase/web/migrations/12.sql` (re-runnable)

- `consultation_applications.email_verified_at`, set on the first click of a valid link.
- `appointments`: status `pending_opt_in`; `opt_in_token` (32 random bytes, hex, unique),
  `opt_in_expires_at`, `opt_in_email_sent_at`, `nudge_sent_at`, `pending_at`.
  CHECK: a `pending_opt_in` row always has a token and an expiry.
- `booking_settings.opt_in_hold_minutes` (default **120**, 15–1440). Change it without a deploy.
- `appointments_no_overlap` (EXCLUDE) also covers `pending_opt_in`.
- `release_stale_holds()` is the cleanup that `reserve_appointment()`, `reissue_opt_in()`
  and `expired_opt_in_holds()` run:
  - a hold past expiry, or a confirmation stuck past expiry, → `cancelled` / `opt_in_expired`
  - a confirmation stuck for more than 10 min during a valid hold → back to `pending_opt_in`
  - a direct `pending` stuck for more than 10 min → `cancelled` / `expired` (as before)
- `booking_slots()` checks the same rules by time, so the slot is free the moment the hold
  ends, without waiting for the cron. **A stuck `pending` is measured from `pending_at`**
  (fallback `created_at`), not `created_at`.
- `reserve_appointment(token, starts_at, helper_id, opt_in)` is the old `book_appointment()`
  body. `book_appointment()` (same signature as before) and the new `hold_appointment()` are wrappers.
- `claim_opt_in(token) → (outcome, appointment_id, rebook_token)` runs under a row lock:
  - `claimed`: a valid hold → `pending`, `pending_at = now()`
  - `processing`: another call claimed it less than 10 min ago
  - `confirmed`: already confirmed, completed or no-show
  - `expired`: the hold ran out (and is cancelled now if it wasn't). `rebook_token` = the application token.
  - `not_found`: unknown token, or the booking was cancelled for another reason
- `release_claim(id)`: `pending` → `pending_opt_in`.
- `reissue_opt_in(id, email?)`: only for a valid hold. Issues a new token, holds again for
  `opt_in_hold_minutes` from now and resets `nudge_sent_at`. With `email`, it also
  corrects the application (lowercased; `email_verified_at` is cleared). Errors:
  `not_found`, `expired`, `not_pending`, `invalid_email`.
- `expired_opt_in_holds()`: runs the cleanup, then returns expired holds without a
  nudge, at most 1 day old, whose lead has no other active booking.
- RLS (decision 12): a helper doesn't see `pending_opt_in` or `opt_in_expired` rows, nor
  the questionnaire of a hold. Admins see everything.
- All new functions: `service_role` only.

`13.sql`: `booking_holds_tick()` + pg_cron job `booking-holds` (`*/5 * * * *`). It calls
`booking-holds` through pg_net only when `expired_opt_in_holds()` returns rows. The URL
and secret are in Vault (`booking_holds_url`, `booking_holds_secret`).

### 4.2 Edge functions

Moved for reuse: `book-meeting/email.ts` → `_shared/booking-email.ts`, `book-meeting/ics.ts`
→ `_shared/ics.ts`. Today's confirm path (Google event, `confirmed`, legacy columns, emails,
list 615) is now `confirmBooking()` in `_shared/booking.ts`.

| Function | What changed |
| --- | --- |
| `book-meeting` | `BOOKING_DOUBLE_OPT_IN=true` → `hold_appointment()` + `booking-opt-in` email. If the email fails, a `meeting-nudge` (`email_failed`) goes out right away. 200 returns `status: "pending_opt_in"`, `meet_link: null`, `opt_in_expires_at`. 409 `already_booked` returns the hold the same way. No resend. Flag off → as today, via `confirmBooking()`. |
| `confirm-meeting` (new) | `POST { token }`. 200 `confirmed` / `expired` + `rebook_token` / `not_found`. 400 for a malformed token, 502 for calendar or DB failure (`release_claim()`, the link works again). On `processing` it polls up to 15 s and never reports `confirmed` early. |
| `booking-holds` (new) | `Bearer BOOKING_HOLDS_SECRET`. `{ action: "tick" }` (cron) sends one `meeting-nudge` (`expired`) per row and sets `nudge_sent_at`. `{ action: "resend", appointment_id, email? }` (support) calls `reissue_opt_in()` and sends the email. |
| `cancel-meeting` | can also cancel a `pending_opt_in` hold (admin). |

Templates in `_shared/booking-email.ts`. Preview: `npx -y deno run -A supabase/functions/book-meeting/preview.ts`.

| Template | To | Subject | Tag |
| --- | --- | --- | --- |
| `optInEmail` | lead | Potvrď e-mail k pohovoru: {deň}, {čas} — button "Potvrdiť e-mail", "termín ti držíme do HH:MM" | `booking-opt-in` |
| `nudgeEmail` (`expired`) | `BOOKING_OWNER_EMAIL` | Nepotvrdený termín: {meno}, {deň}, {čas} — contact, helper, time, "Zavolať klientke" | `booking-nudge` |
| `nudgeEmail` (`email_failed`) | `BOOKING_OWNER_EMAIL` | E-mail neodišiel: … — "send the correct email to podpora@" | `booking-nudge` |

New secrets: `BOOKING_DOUBLE_OPT_IN` (flag), `BOOKING_HOLDS_SECRET` (set by `24`),
`BOOKING_SITE_URL` (optional, default `https://trenerzien.sk`).

### 4.3 Support resend (decision 11)

```bash
supabase/web/bin/25-resend-opt-in.sh <appointment id | lead email as typed> [corrected email]
```

It shows the booking, refuses an expired hold or a non-hold, asks for confirmation, then
calls `booking-holds` `resend`. An admin UI button can call the same function later.

### 4.4 Tests

`supabase/web/tests/booking-test.sh` (local Postgres) runs `12.sql` twice, then
`booking-opt-in-test.sql`:

- a hold blocks the slot and has a token and a 2 h expiry
- claim / processing / release / confirmed
- regression: a hold claimed after 30 min is not stale
- a stuck confirmation is reverted, or expired
- expiry frees the slot without the cron, the link returns `expired` with a rebook token, and rebooking works
- `not_found` cases
- nudge selection
- reissue: new token, old one dead, corrected email, refusals
- flag-off booking unchanged
- RLS for helper, admin and anon

After that, the 4 → 5 → 12 re-apply (what `08` does) and the 30-way concurrency test.
Edge functions pass `deno check` and `deno lint`. They haven't run against Supabase yet.

### 4.5 Deploy

1. **Backend, flag off** (safe while the website is unchanged):
   `supabase/web/bin/24-booking-opt-in.sh`. It applies `12.sql` and sets
   `BOOKING_HOLDS_SECRET`. It deploys `book-meeting`, `confirm-meeting`,
   `booking-holds` and `cancel-meeting`, then sets the Vault entries and applies `13.sql`.
   Last, it smoke-tests `confirm-meeting` with an unknown token (expects
   `{"status":"not_found"}`) and `booking-holds` with `tick`.
2. **Check flag off:** one normal test booking still gets the invitation immediately.
3. **Website:** Lovable ships `/pohovor/termin` → `/pohovor/potvrdenie`, and `/pohovor/dakujem?t=`.
4. **Flag on:** `24-booking-opt-in.sh on`.
5. **End-to-end:**
   - book → "Potvrď e-mail" arrives → click → `/pohovor/dakujem` shows confirmed → the
     invitation plus the helper and owner emails arrive
   - book and don't click: set `opt_in_expires_at` in the past, wait ≤ 5 min → nudge at
     `pohovory@`, slot free again; the old link then shows expired → rebook works
   - `25-resend-opt-in.sh <email> <other email>` → a new link arrives, and the old one shows `not_found`
6. **Rollback:** `24-booking-opt-in.sh off`. Existing holds can still be confirmed.
7. Then fold this into `BOOKING.md` (flow, statuses, emails).

## 5. Changes to send back to Lovable

Paste-ready:

> Route change for double opt-in (backend is unchanged otherwise):
>
> 1. **`/pohovor/termin` → `/pohovor/potvrdenie`** (new page, step 3/3 of the funnel, same header as steps 1–2). When `book-meeting` returns `appointment.status === "pending_opt_in"` (200, or 409 `already_booked`), navigate here with `?until=<opt_in_expires_at>`. Copy: "Potvrď prosím svoj e-mail – poslali sme ti odkaz. Pozvánku na pohovor dostaneš hneď po potvrdení. Termín ti držíme do 14:30." (HH:MM in Europe/Bratislava; fallback "2 hodiny"), the SPAM/REKLAMA hint and "Neprišiel ti e-mail? Napíš na podpora@trenerzien.sk". No resend button, no Meet link. Any other status (flag off): navigate to `/pohovor/dakujem` exactly as today.
> 2. **The email link is `https://trenerzien.sk/pohovor/dakujem?t=<token>`** (not `/pohovor/potvrdene`, drop that page). With `t`: check it against `/^[a-f0-9]{16,128}$/` (no match → not_found), call `supabase.functions.invoke("confirm-meeting", { body: { token } })` once on mount and show the state. Without `t`: today's thank-you copy, unchanged.
>    - **confirmed** (200 `{ status: "confirmed", starts_at, ends_at, helper_name }`): "Hotovo, pozvánka je na ceste" + date, time, consultant (Bratislava time), confetti.
>    - **expired** (200 `{ status: "expired", rebook_token }`): "Termín vypršal". Save `rebook_token` as the questionnaire token (the key `/pohovor/termin` reads) and show "Vybrať nový termín" → `/pohovor/termin`.
>    - **not_found** (200 `{ status: "not_found" }`): "Odkaz je neplatný" + podpora@.
>    - **error** (400, 5xx, network): "Skús odkaz otvoriť znova o chvíľu" + retry button + podpora@.
>    `head()` with `robots: noindex` when `t` is present.
> 3. Release: unchanged. The backend goes live with the flag off, you ship, then we switch the flag on.
