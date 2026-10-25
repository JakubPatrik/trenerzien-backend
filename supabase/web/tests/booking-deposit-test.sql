-- Assertions for 16.sql (refundable deposit). Run by booking-test.sh on a throwaway local
-- Postgres — never against the real project. Any failed ASSERT aborts.
\set ON_ERROR_STOP 1
\set QUIET 1
\pset tuples_only on
\o /dev/null

CREATE FUNCTION pg_temp.expect_error(sql text, expected text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE sql;
  RAISE EXCEPTION 'expected error "%" but succeeded: %', expected, sql;
EXCEPTION WHEN OTHERS THEN
  IF sqlerrm LIKE 'expected error%' OR position(expected IN sqlerrm) = 0 THEN
    RAISE EXCEPTION 'expected "%", got "%" for: %', expected, sqlerrm, sql;
  END IF;
END $$;

\echo 'deposit: anon submits the questionnaire, cannot mark it paid'
GRANT INSERT ON public.consultation_applications TO anon;  -- Supabase's default grant
SET ROLE anon;
INSERT INTO public.consultation_applications (token, name, email, phone) VALUES ('dep1', 'D', 'd@x.sk', '0');
SELECT pg_temp.expect_error($$INSERT INTO public.consultation_applications (token, name, email, deposit_paid)
  VALUES ('dep2', 'D', 'd@x.sk', true)$$, 'row-level security');
SELECT pg_temp.expect_error($$INSERT INTO public.consultation_applications (token, name, email, deposit_session_id)
  VALUES ('dep3', 'D', 'd@x.sk', 'cs_test_x')$$, 'row-level security');
SELECT pg_temp.expect_error($$INSERT INTO public.consultation_applications (token, name, email, deposit_payment_intent_id)
  VALUES ('dep4', 'D', 'd@x.sk', 'pi_x')$$, 'row-level security');
SELECT pg_temp.expect_error($$INSERT INTO public.consultation_applications (token, name, email)
  VALUES ('dep5', 'D', 'not-an-email')$$, 'row-level security');
RESET ROLE;

\echo 'deposit: service role marks it paid (what markDepositPaid does), second update is a no-op'
DO $$
DECLARE n int;
BEGIN
  UPDATE public.consultation_applications SET deposit_paid = true, deposit_paid_at = now(),
    deposit_session_id = 'cs_test_1', deposit_payment_intent_id = 'pi_1'
  WHERE token = 'dep1' AND deposit_paid = false;
  GET DIAGNOSTICS n = ROW_COUNT; ASSERT n = 1, 'first mark';
  UPDATE public.consultation_applications SET deposit_paid = true, deposit_session_id = 'cs_test_2'
  WHERE token = 'dep1' AND deposit_paid = false;
  GET DIAGNOSTICS n = ROW_COUNT; ASSERT n = 0, 'second mark must not match';
  ASSERT (SELECT deposit_session_id FROM public.consultation_applications WHERE token = 'dep1') = 'cs_test_1';
END $$;

\o
\echo 'deposit: OK'
