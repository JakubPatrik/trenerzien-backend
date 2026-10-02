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
- [ ] **New live prices:** when you copy the products from the sandbox, use the lookup keys `klub_mesacne_clenstvo`, `klub_stvrtrocne_clenstvo` and `klub_rocne_clenstvo`.
- [ ] **Watch the first live renewals (27–31 Oct)** in the `stripe-webhook` logs, and check that end dates move forward a month. No live events have arrived yet.
- [x] **Parked:** do Lovable's live webhooks also write memberships?

## C. Call booking (paused)

- [ ] **Google Cloud access** (blocks the rest): OAuth client, then the refresh token (`11`), secrets (`12`) and deploy (`09`).
- [ ] **SmartEmailing secrets:** these already exist from Lovable. Check that the sender and reply-to are confirmed in SmartEmailing.
- [ ] **End-to-end test** after deploy.
- [ ] **WEB frontend:** step 1 token, then step 2 (`booking_slots` → `book-meeting`).
- [ ] **KLUB frontend:** "Moja dostupnosť" for guides.
- [ ] **Me, when you unpause:** `5.sql` (`is_guide()`, `ensure_my_helper()`, membership trigger, tests).
- [ ] **Phase 2:** "Moje pohovory", reminder emails, self-service cancellation for leads, busy check against helpers' own calendars.