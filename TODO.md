The sync finished: all 65 memberships are linked, none is still "lifetime", and the missing membership was created. The test account is gone and `.env` is clean.

# TODO

## B. KLUB subscriptions (Stripe)

- [x] **Run the sync once more** to confirm it shows everything `unchanged` and no subscriptions without a membership:
  ```bash
  STRIPE_SECRET_KEY=<live key> supabase/web/bin/13-sync-stripe-memberships.sh
  ```
- [x] **4 past-due members currently have no KLUB access.** Their paid period ended on 27–30 Sep and Stripe is still retrying their cards. When a payment goes through, the webhook restores access automatically. If any of them contacts support, that's why.
- [x] **Live key:** consider switching the Supabase secret `STRIPE_SECRET_KEY_LIVE` to a restricted key with read access to Subscriptions and Customers.
- [ ] **Test-mode checks with a test clock:** a renewal moves the end date forward, the declining card ends the membership after retries, and cancelling ends it.
- [x] **New live prices:** when you copy the products from the sandbox, use the lookup keys `klub_mesacne_clenstvo`, `klub_stvrtrocne_clenstvo` and `klub_rocne_clenstvo`.
- [ ] **Watch the first live renewals (27–31 Oct)** in the `stripe-webhook` logs, and check that end dates move forward a month. No live events have arrived yet.
- [x] **Parked:** do Lovable's live webhooks also write memberships?

## C. Call booking

- [x] **`5.sql`:** guides set availability per 1-hour slot on specific dates, up to 31 days ahead. A trigger on the `Sprievodkyňa klubu` membership keeps their guide record (`helpers` row) up to date.
- [x] **4.sql + 5.sql applied to production** (`08`), and guide records backfilled (`14`). All 8 guides are active, and 2 dated availability slots already exist.
- [x] **SmartEmailing secrets** are set.
- [x] **KLUB frontend:** "Moja dostupnosť" at `/dostupnost`, showing availability and booked meetings.
- [x] **WEB frontend:** step 1 token, then `/pohovor/termin` (`booking_slots` → `book-meeting`).
- [x] **Google Cloud access:** OAuth client on the Workspace master account `pohovory@`, refresh token (`11`) and secrets (`12`) set. `BOOKING_ALLOWED_ORIGINS` = `trenerzien.sk` + `www.trenerzien.sk`.
- [x] **Edge functions deployed** (`09`): `book-meeting`, `cancel-meeting`.
- [x] **End-to-end booking test:** questionnaire → book → calendar event, invitations and confirmation email all arrived.
- [ ] **Test cancelling** through `cancel-meeting`: the event disappears, Google emails the cancellation, and the slot is back in `booking_slots()`.
- [ ] **Guides fill in their availability** for the next month.
- [x] **Personalistka role (`6.sql`) applied to production** (`17`). Only recruiters (role `personalistka`) lead interviews; all 8 guide helpers are now inactive.
- [ ] **Add the recruiters:** `18-recruiter.sh add <email>`. Until then the WEB offers no interview slots.
- [ ] **KLUB frontend (Lovable):** `supabase/klub/KLUB_LOVABLE_PERSONALISTKA.md`.
- [ ] **Phase 2:** mark meetings as completed or no-show in KLUB, reminder emails, self-service cancellation for leads, busy check against helpers' own calendars.
