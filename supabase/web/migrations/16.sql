-- Vratná záloha 100 € pred výberom termínu (ZALOHA_VRATENIE.md, LOVABLE_ZALOHA.md)
--
-- Lead po dotazníku zaplatí zálohu na platobnej stránke webu (Lovable, client_reference_id
-- = token dotazníka); až potom book-meeting rezervuje termín (BOOKING_DEPOSIT_REQUIRED=true).
-- Zaplatenie zapíše stripe-webhook (checkout.session.completed).
--
--   deposit_paid, deposit_paid_at, deposit_session_id   už existujú (0.sql)
--   deposit_payment_intent_id                           nové: platba na vrátenie v Stripe
--   politika "Anyone can submit an application"          anon nesmie poslať nič z deposit_*
--                                                        (znenie z produkcie + nový stĺpec)
--
-- Frontend sa nemení (stĺpce zapisuje len service role). Re-runnable.

ALTER TABLE public.consultation_applications
  ADD COLUMN IF NOT EXISTS deposit_payment_intent_id text;

DROP POLICY IF EXISTS "Anyone can submit an application" ON public.consultation_applications;
CREATE POLICY "Anyone can submit an application"
ON public.consultation_applications
FOR INSERT
TO anon, authenticated
WITH CHECK (
  length(trim(both from coalesce(name, ''))) BETWEEN 1 AND 200
  AND coalesce(email, '') ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'
  AND length(email) <= 255
  AND coalesce(deposit_paid, false) = false
  AND deposit_paid_at IS NULL
  AND deposit_session_id IS NULL
  AND deposit_payment_intent_id IS NULL
  AND booking_event_id IS NULL
  AND booking_meet_url IS NULL
  AND coalesce(synced_to_smartemailing, false) = false
  AND sync_error IS NULL
);
