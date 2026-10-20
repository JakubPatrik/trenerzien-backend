-- Assertions for 12.sql (double opt-in). Run by booking-test.sh on a throwaway local
-- Postgres after 4–7.sql — never against the real project. Any failed ASSERT aborts.
-- Own helper with dated slots (days 60–62) so it doesn't touch the other tests' slots.
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

CREATE FUNCTION pg_temp.at(days int, hhmm text) RETURNS timestamptz LANGUAGE sql STABLE AS $$
  SELECT ((now() AT TIME ZONE 'Europe/Bratislava')::date + days + hhmm::time) AT TIME ZONE 'Europe/Bratislava'
$$;

CREATE FUNCTION pg_temp.appt(_token text) RETURNS public.appointments LANGUAGE sql AS $$
  SELECT a.* FROM public.appointments a JOIN public.consultation_applications c ON c.id = a.application_id
  WHERE c.token = _token ORDER BY a.created_at DESC LIMIT 1
$$;

CREATE FUNCTION pg_temp.offered(days int, hhmm text) RETURNS boolean LANGUAGE sql AS $$
  SELECT EXISTS (SELECT 1 FROM public.booking_slots(pg_temp.at(days, hhmm), pg_temp.at(days, hhmm))
                 WHERE helper_id = 'aaaaaaaa-0000-0000-0000-0000000000f1')
$$;

UPDATE public.booking_settings SET horizon_days = 90, min_notice_minutes = 0, buffer_minutes = 0;

INSERT INTO auth.users VALUES ('0f0f0f0f-0000-0000-0000-0000000000f1', 'optin-helper@x.sk');
INSERT INTO public.helpers (id, user_id, name, email, active) VALUES
  ('aaaaaaaa-0000-0000-0000-0000000000f1', '0f0f0f0f-0000-0000-0000-0000000000f1', 'Opt', 'optin-helper@x.sk', true);
INSERT INTO public.helper_availability (helper_id, date, start_time, end_time)
SELECT 'aaaaaaaa-0000-0000-0000-0000000000f1', (now() AT TIME ZONE 'Europe/Bratislava')::date + d, t, t + interval '1 hour'
FROM generate_series(60, 62) d, unnest(ARRAY[time '09:00', time '10:00', time '11:00']) t;
INSERT INTO public.consultation_applications (token, name, email, phone, qualified)
SELECT 'opt' || i, 'Opt ' || i, 'opt' || i || '@x.sk', '09' || i, true FROM generate_series(1, 9) i;

\echo 'opt-in: settings default 120 min'
DO $$ BEGIN
  ASSERT (SELECT opt_in_hold_minutes FROM public.booking_settings) = 120;
END $$;

\echo 'opt-in: hold blocks the slot, has a token and a 2 h expiry'
SELECT public.hold_appointment('opt1', pg_temp.at(60, '09:00'), 'aaaaaaaa-0000-0000-0000-0000000000f1') \gset
DO $$ DECLARE a public.appointments; BEGIN
  a := pg_temp.appt('opt1');
  ASSERT a.status = 'pending_opt_in', a.status;
  ASSERT a.opt_in_token ~ '^[0-9a-f]{64}$', 'token format';
  ASSERT a.opt_in_expires_at BETWEEN now() + interval '119 minutes' AND now() + interval '121 minutes', 'expiry';
  ASSERT a.pending_at IS NULL;
  ASSERT NOT pg_temp.offered(60, '09:00'), 'held slot still offered';
END $$;
SELECT pg_temp.expect_error($$SELECT public.hold_appointment('opt1', pg_temp.at(60, '10:00'))$$, 'already_booked');
SELECT pg_temp.expect_error($$SELECT public.book_appointment('opt2', pg_temp.at(60, '09:00'), 'aaaaaaaa-0000-0000-0000-0000000000f1')$$, 'slot_unavailable');
SELECT pg_temp.expect_error($$
  INSERT INTO public.appointments (application_id, helper_id, starts_at, ends_at, status)
  SELECT id, 'aaaaaaaa-0000-0000-0000-0000000000f1', pg_temp.at(60, '09:30'), pg_temp.at(60, '10:30'), 'confirmed'
  FROM public.consultation_applications WHERE token = 'opt2'$$, 'appointments_no_overlap');
SELECT pg_temp.expect_error($$
  INSERT INTO public.appointments (application_id, helper_id, starts_at, ends_at, status)
  SELECT id, 'aaaaaaaa-0000-0000-0000-0000000000f1', pg_temp.at(62, '09:00'), pg_temp.at(62, '10:00'), 'pending_opt_in'
  FROM public.consultation_applications WHERE token = 'opt2'$$, 'appointments_opt_in_fields');

\echo 'opt-in: claim → pending, verified; second claim → processing; release → claimable; confirmed → idempotent'
DO $$ DECLARE a public.appointments; r record; BEGIN
  a := pg_temp.appt('opt1');
  SELECT * INTO r FROM public.claim_opt_in(a.opt_in_token);
  ASSERT r.outcome = 'claimed' AND r.appointment_id = a.id, r.outcome;
  ASSERT (pg_temp.appt('opt1')).status = 'pending';
  ASSERT (pg_temp.appt('opt1')).pending_at > now() - interval '1 minute';
  ASSERT (SELECT email_verified_at IS NOT NULL FROM public.consultation_applications WHERE token = 'opt1'), 'not verified';
  ASSERT NOT pg_temp.offered(60, '09:00'), 'claimed slot offered';
  ASSERT (SELECT outcome FROM public.claim_opt_in(a.opt_in_token)) = 'processing';
  PERFORM public.release_claim(a.id);
  ASSERT (pg_temp.appt('opt1')).status = 'pending_opt_in', 'release_claim';
  ASSERT (SELECT outcome FROM public.claim_opt_in(a.opt_in_token)) = 'claimed';
  UPDATE public.appointments SET status = 'confirmed', google_event_id = 'ev1' WHERE id = a.id;
  ASSERT (SELECT outcome FROM public.claim_opt_in(a.opt_in_token)) = 'confirmed';
END $$;

\echo 'opt-in: a hold claimed after 30 min is not treated as a stale pending (regression)'
SELECT public.hold_appointment('opt2', pg_temp.at(60, '10:00'), 'aaaaaaaa-0000-0000-0000-0000000000f1') \gset
UPDATE public.appointments SET created_at = now() - interval '30 minutes' WHERE id = (pg_temp.appt('opt2')).id;
DO $$ BEGIN
  ASSERT (SELECT outcome FROM public.claim_opt_in((pg_temp.appt('opt2')).opt_in_token)) = 'claimed';
  ASSERT NOT pg_temp.offered(60, '10:00'), 'claimed old hold offered';
END $$;
SELECT pg_temp.expect_error($$SELECT public.book_appointment('opt3', pg_temp.at(60, '10:00'), 'aaaaaaaa-0000-0000-0000-0000000000f1')$$, 'slot_unavailable');
DO $$ BEGIN
  ASSERT (pg_temp.appt('opt2')).status = 'pending', 'claimed hold was released by a new booking';
END $$;

\echo 'opt-in: stuck confirmation (>10 min) during a valid hold → back to the hold, link works again'
UPDATE public.appointments SET pending_at = now() - interval '11 minutes' WHERE id = (pg_temp.appt('opt2')).id;
DO $$ BEGIN
  ASSERT NOT pg_temp.offered(60, '10:00'), 'stuck claim within the hold must still block the slot';
  PERFORM public.release_stale_holds();
  ASSERT (pg_temp.appt('opt2')).status = 'pending_opt_in', 'stuck claim not reverted';
  ASSERT (SELECT outcome FROM public.claim_opt_in((pg_temp.appt('opt2')).opt_in_token)) = 'claimed';
END $$;

\echo 'opt-in: expiry frees the slot without the cron; the link then says expired + rebook token'
SELECT public.hold_appointment('opt4', pg_temp.at(60, '11:00'), 'aaaaaaaa-0000-0000-0000-0000000000f1') \gset
UPDATE public.appointments SET opt_in_expires_at = now() - interval '1 second' WHERE id = (pg_temp.appt('opt4')).id;
DO $$ BEGIN
  ASSERT pg_temp.offered(60, '11:00'), 'expired hold still blocks booking_slots()';
END $$;
SELECT public.hold_appointment('opt5', pg_temp.at(60, '11:00'), 'aaaaaaaa-0000-0000-0000-0000000000f1') \gset
DO $$ DECLARE a public.appointments; r record; BEGIN
  a := pg_temp.appt('opt4');
  ASSERT a.status = 'cancelled' AND a.cancel_reason = 'opt_in_expired', a.status || '/' || a.cancel_reason;
  SELECT * INTO r FROM public.claim_opt_in(a.opt_in_token);
  ASSERT r.outcome = 'expired' AND r.rebook_token = 'opt4', format('%s %s', r.outcome, r.rebook_token);
  ASSERT (SELECT email_verified_at IS NOT NULL FROM public.consultation_applications WHERE token = 'opt4'), 'expired click verifies e-mail';
END $$;
-- rebooking with the application token works (slot 11:00 is taken by opt5 now)
SELECT public.hold_appointment('opt4', pg_temp.at(61, '09:00'), 'aaaaaaaa-0000-0000-0000-0000000000f1') \gset
DO $$ BEGIN
  ASSERT (pg_temp.appt('opt4')).status = 'pending_opt_in', 'rebook';
END $$;

\echo 'opt-in: claim on an expired hold (no cron yet) expires it; unknown and otherwise cancelled → not_found'
UPDATE public.appointments SET opt_in_expires_at = now() - interval '1 second' WHERE id = (pg_temp.appt('opt5')).id;
DO $$ DECLARE a public.appointments; BEGIN
  a := pg_temp.appt('opt5');
  ASSERT (SELECT outcome FROM public.claim_opt_in(a.opt_in_token)) = 'expired';
  ASSERT (pg_temp.appt('opt5')).cancel_reason = 'opt_in_expired';
  ASSERT (SELECT outcome FROM public.claim_opt_in('deadbeef' || repeat('0', 56))) = 'not_found';
  ASSERT (SELECT outcome FROM public.claim_opt_in(NULL)) = 'not_found';
END $$;
SELECT public.hold_appointment('opt6', pg_temp.at(61, '10:00'), 'aaaaaaaa-0000-0000-0000-0000000000f1') \gset
UPDATE public.appointments SET status = 'cancelled', cancel_reason = 'cancelled by admin' WHERE id = (pg_temp.appt('opt6')).id;
DO $$ BEGIN
  ASSERT (SELECT outcome FROM public.claim_opt_in((pg_temp.appt('opt6')).opt_in_token)) = 'not_found';
END $$;

\echo 'opt-in: stuck confirmation after the hold ran out → expired (gets a nudge)'
SELECT public.hold_appointment('opt7', pg_temp.at(61, '11:00'), 'aaaaaaaa-0000-0000-0000-0000000000f1') \gset
DO $$ BEGIN PERFORM public.claim_opt_in((pg_temp.appt('opt7')).opt_in_token); END $$;
UPDATE public.appointments SET pending_at = now() - interval '11 minutes', opt_in_expires_at = now() - interval '1 minute'
 WHERE id = (pg_temp.appt('opt7')).id;
DO $$ BEGIN
  ASSERT pg_temp.offered(61, '11:00'), 'stuck claim past the hold still blocks';
END $$;

\echo 'opt-in: expired_opt_in_holds() → only un-nudged, without another active booking'
DO $$ DECLARE ids uuid[]; BEGIN
  SELECT array_agg(appointment_id) INTO ids FROM public.expired_opt_in_holds();
  -- opt4's first hold: she rebooked → no nudge. opt5 and opt7: nudge.
  ASSERT (pg_temp.appt('opt7')).status = 'cancelled', 'stuck expired claim not released';
  ASSERT ids @> ARRAY[(pg_temp.appt('opt5')).id, (pg_temp.appt('opt7')).id], format('missing nudges %s', ids);
  ASSERT NOT EXISTS (SELECT 1 FROM public.expired_opt_in_holds() e JOIN public.appointments a ON a.id = e.appointment_id
                     JOIN public.consultation_applications c ON c.id = a.application_id WHERE c.token = 'opt4'),
         'nudge for a lead who already rebooked';
  UPDATE public.appointments SET nudge_sent_at = now() WHERE id = (pg_temp.appt('opt5')).id;
  ASSERT NOT EXISTS (SELECT 1 FROM public.expired_opt_in_holds() WHERE appointment_id = (pg_temp.appt('opt5')).id), 'nudged twice';
  ASSERT (SELECT lead_phone FROM public.expired_opt_in_holds() WHERE appointment_id = (pg_temp.appt('opt7')).id) = '097';
END $$;

\echo 'opt-in: reissue → new token, old one dead, corrected e-mail, new expiry; refusals'
SELECT public.hold_appointment('opt8', pg_temp.at(62, '09:00'), 'aaaaaaaa-0000-0000-0000-0000000000f1') \gset
DO $$ DECLARE a public.appointments; r record; BEGIN
  a := pg_temp.appt('opt8');
  UPDATE public.appointments SET opt_in_expires_at = now() + interval '5 minutes', nudge_sent_at = now() WHERE id = a.id;
  SELECT * INTO r FROM public.reissue_opt_in(a.id, '  Opt8@Gmail.com ');
  ASSERT r.opt_in_token <> a.opt_in_token AND r.opt_in_token ~ '^[0-9a-f]{64}$', 'token not replaced';
  ASSERT r.email = 'opt8@gmail.com', r.email;
  ASSERT r.opt_in_expires_at > now() + interval '119 minutes', 'hold not extended';
  ASSERT (pg_temp.appt('opt8')).nudge_sent_at IS NULL, 'nudge flag not reset';
  ASSERT (SELECT outcome FROM public.claim_opt_in(a.opt_in_token)) = 'not_found', 'old link still works';
  SELECT * INTO r FROM public.reissue_opt_in(a.id);
  ASSERT r.email = 'opt8@gmail.com', 'e-mail changed without p_email';
END $$;
SELECT pg_temp.expect_error($$SELECT * FROM public.reissue_opt_in((pg_temp.appt('opt8')).id, 'not-an-email')$$, 'invalid_email');
SELECT pg_temp.expect_error($$SELECT * FROM public.reissue_opt_in((pg_temp.appt('opt5')).id)$$, 'expired');
SELECT pg_temp.expect_error($$SELECT * FROM public.reissue_opt_in((pg_temp.appt('opt1')).id)$$, 'not_pending');
SELECT pg_temp.expect_error($$SELECT * FROM public.reissue_opt_in(gen_random_uuid())$$, 'not_found');

\echo 'opt-in: direct booking (flag off) unchanged; stale direct pending still released'
SELECT public.book_appointment('opt9', pg_temp.at(62, '10:00'), 'aaaaaaaa-0000-0000-0000-0000000000f1') \gset
DO $$ BEGIN
  ASSERT (pg_temp.appt('opt9')).status = 'pending' AND (pg_temp.appt('opt9')).opt_in_token IS NULL;
  UPDATE public.appointments SET created_at = now() - interval '11 minutes' WHERE id = (pg_temp.appt('opt9')).id;
  PERFORM public.release_stale_holds();
  ASSERT (pg_temp.appt('opt9')).cancel_reason = 'expired', 'stale direct pending kept';
END $$;

\echo 'opt-in: RLS — helper sees neither holds nor expired holds nor their questionnaires; admin does'
SET ROLE authenticated;
SET request.jwt.claim.sub = '0f0f0f0f-0000-0000-0000-0000000000f1';
DO $$ BEGIN
  ASSERT NOT EXISTS (SELECT 1 FROM public.appointments WHERE status = 'pending_opt_in'), 'helper sees holds';
  ASSERT NOT EXISTS (SELECT 1 FROM public.appointments WHERE cancel_reason = 'opt_in_expired'), 'helper sees expired holds';
  ASSERT EXISTS (SELECT 1 FROM public.appointments WHERE status = 'confirmed'), 'helper lost confirmed';
  ASSERT (SELECT array_agg(token ORDER BY token) FROM public.consultation_applications) = ARRAY['opt1', 'opt2'],
         format('helper applications %s', (SELECT array_agg(token ORDER BY token) FROM public.consultation_applications));
END $$;
SELECT pg_temp.expect_error($$SELECT * FROM public.claim_opt_in('x')$$, 'permission denied');
SELECT pg_temp.expect_error($$SELECT * FROM public.reissue_opt_in(gen_random_uuid())$$, 'permission denied');
SELECT pg_temp.expect_error($$SELECT public.hold_appointment('opt3', now())$$, 'permission denied');
SET request.jwt.claim.sub = '44444444-4444-4444-4444-444444444444';
DO $$ BEGIN
  ASSERT EXISTS (SELECT 1 FROM public.appointments WHERE status = 'pending_opt_in'), 'admin cannot see holds';
END $$;
RESET ROLE;
SET ROLE anon;
SELECT pg_temp.expect_error($$SELECT * FROM public.claim_opt_in('x')$$, 'permission denied');
SELECT pg_temp.expect_error($$SELECT * FROM public.expired_opt_in_holds()$$, 'permission denied');
RESET ROLE;

-- Keep the next tests' slot counts (2 helpers) intact.
UPDATE public.helpers SET active = false WHERE id = 'aaaaaaaa-0000-0000-0000-0000000000f1';

\echo 'all opt-in assertions passed'
