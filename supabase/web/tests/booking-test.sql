-- Assertions for 4.sql + 5.sql (booking). Run by booking-test.sh on a throwaway local
-- Postgres — never against the real project. Any failed ASSERT aborts.
\set ON_ERROR_STOP 1
\set QUIET 1
\pset tuples_only on
\o /dev/null

-- Raises unless `sql` fails with an error message containing `expected`.
CREATE FUNCTION pg_temp.expect_error(sql text, expected text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE sql;
  RAISE EXCEPTION 'expected error "%" but succeeded: %', expected, sql;
EXCEPTION WHEN OTHERS THEN
  IF sqlerrm LIKE 'expected error%' OR position(expected IN sqlerrm) = 0 THEN
    RAISE EXCEPTION 'expected "%", got "%" for: %', expected, sqlerrm, sql;
  END IF;
END $$;

-- Local Bratislava time `days` from today, e.g. pg_temp.at(30, '09:00').
CREATE FUNCTION pg_temp.at(days int, hhmm text) RETURNS timestamptz LANGUAGE sql STABLE AS $$
  SELECT ((now() AT TIME ZONE 'Europe/Bratislava')::date + days + hhmm::time) AT TIME ZONE 'Europe/Bratislava'
$$;

-- Fixtures: two helpers, every day 09:00–12:00 Bratislava, four applications.
INSERT INTO auth.users VALUES
  ('11111111-1111-1111-1111-111111111111', 'zuzana@x.sk'),
  ('22222222-2222-2222-2222-222222222222', 'peter@x.sk'),
  ('33333333-3333-3333-3333-333333333333', 'other@x.sk'),
  ('44444444-4444-4444-4444-444444444444', 'admin@x.sk');
INSERT INTO public.user_roles VALUES ('44444444-4444-4444-4444-444444444444', 'admin');
INSERT INTO public.helpers (id, user_id, name, email) VALUES
  ('aaaaaaaa-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'Zuzana', 'zuzana@x.sk'),
  ('aaaaaaaa-0000-0000-0000-000000000002', '22222222-2222-2222-2222-222222222222', 'Peter', 'peter@x.sk');
INSERT INTO public.helper_availability (helper_id, day_of_week, start_time, end_time)
SELECT h, d, '09:00', '12:00'
FROM unnest(ARRAY['aaaaaaaa-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000002']::uuid[]) h,
     generate_series(1, 7) d;
INSERT INTO public.consultation_applications (id, token, name, email, phone, qualified) VALUES
  ('bbbbbbbb-0000-0000-0000-000000000001', 'tok1', 'L1', 'l1@x.sk', '1', true),
  ('bbbbbbbb-0000-0000-0000-000000000002', 'tok2', 'L2', 'l2@x.sk', '2', true),
  ('bbbbbbbb-0000-0000-0000-000000000003', 'tok3', 'L3', 'l3@x.sk', '3', true),
  ('bbbbbbbb-0000-0000-0000-000000000004', 'tokNQ', 'NQ', 'nq@x.sk', '4', false);

\echo 'slots: grid, min notice, horizon'
DO $$
DECLARE n int; lo timestamptz; hi timestamptz; local_minutes int[];
BEGIN
  SELECT count(*), min(starts_at), max(starts_at),
         array_agg(DISTINCT extract(hour FROM starts_at AT TIME ZONE 'Europe/Bratislava')::int * 60
                          + extract(minute FROM starts_at AT TIME ZONE 'Europe/Bratislava')::int)
    INTO n, lo, hi, local_minutes FROM public.booking_slots();
  ASSERT n > 0, 'no slots';
  ASSERT lo >= now() + interval '24 hours', 'min notice violated';
  ASSERT (SELECT horizon_days FROM public.booking_settings) = 31, '5.sql should set horizon to 31 days';
  ASSERT hi <= now() + interval '31 days', 'horizon violated';
  ASSERT local_minutes <@ ARRAY[540, 600, 660], format('unexpected local start times %s', local_minutes);
  ASSERT NOT EXISTS (SELECT 1 FROM public.booking_slots() WHERE ends_at - starts_at <> interval '60 minutes'), 'slot length';
END $$;

-- Wider window for the remaining tests (dates relative to today).
UPDATE public.booking_settings SET horizon_days = 90, min_notice_minutes = 0;

\echo 'slots: local 09/10/11:00 across 90 days (spans a DST change in most seasons)'
DO $$ BEGIN
  ASSERT NOT EXISTS (
    SELECT 1 FROM public.booking_slots()
    WHERE (starts_at AT TIME ZONE 'Europe/Bratislava')::time NOT IN ('09:00', '10:00', '11:00')
  ), 'slot drifted from the local grid';
END $$;

\echo 'book: specific helper, then "anyone" gets the other one'
SELECT public.book_appointment('tok1', pg_temp.at(30, '09:00'), 'aaaaaaaa-0000-0000-0000-000000000001') AS a1 \gset
SELECT public.book_appointment('tok2', pg_temp.at(30, '09:00')) AS a2 \gset
DO $$ BEGIN
  ASSERT (SELECT status FROM public.appointments WHERE application_id = 'bbbbbbbb-0000-0000-0000-000000000001') = 'pending';
  ASSERT (SELECT helper_id FROM public.appointments WHERE application_id = 'bbbbbbbb-0000-0000-0000-000000000002')
         = 'aaaaaaaa-0000-0000-0000-000000000002', '"anyone" should get Peter';
  ASSERT NOT EXISTS (SELECT 1 FROM public.booking_slots(pg_temp.at(30, '09:00'), pg_temp.at(30, '09:00'))),
         'booked slot still offered';
END $$;

\echo 'book: rejections'
SELECT pg_temp.expect_error($$SELECT public.book_appointment('tok3', pg_temp.at(30, '09:00'))$$, 'slot_unavailable');
SELECT pg_temp.expect_error($$SELECT public.book_appointment('tok1', pg_temp.at(32, '09:00'))$$, 'already_booked');
SELECT pg_temp.expect_error($$SELECT public.book_appointment('nope', pg_temp.at(32, '09:00'))$$, 'application_not_found');
SELECT pg_temp.expect_error($$SELECT public.book_appointment('tokNQ', pg_temp.at(32, '09:00'))$$, 'not_qualified');
SELECT pg_temp.expect_error($$SELECT public.book_appointment('tok3', pg_temp.at(32, '09:30'))$$, 'slot_unavailable');
SELECT pg_temp.expect_error($$SELECT public.book_appointment('tok3', pg_temp.at(32, '12:00'))$$, 'slot_unavailable');
SELECT pg_temp.expect_error($$SELECT public.book_appointment('tok3', now() - interval '1 day')$$, 'slot_unavailable');
SELECT pg_temp.expect_error($$SELECT public.book_appointment('tok3', now() + interval '200 days')$$, 'slot_unavailable');
SELECT pg_temp.expect_error($$SELECT public.book_appointment('tok3', pg_temp.at(32, '09:00'), 'aaaaaaaa-0000-0000-0000-00000000dead')$$, 'slot_unavailable');

\echo 'constraint: direct overlapping insert is refused'
SELECT pg_temp.expect_error($$
  INSERT INTO public.appointments (application_id, helper_id, starts_at, ends_at, status)
  VALUES ('bbbbbbbb-0000-0000-0000-000000000003', 'aaaaaaaa-0000-0000-0000-000000000001',
          pg_temp.at(30, '09:30'), pg_temp.at(30, '10:30'), 'confirmed')$$,
  'appointments_no_overlap');

\echo 'time off and buffer'
INSERT INTO public.helper_time_off (helper_id, starts_at, ends_at)
VALUES ('aaaaaaaa-0000-0000-0000-000000000001', pg_temp.at(34, '00:00'), pg_temp.at(35, '00:00'));
DO $$ BEGIN
  ASSERT (SELECT array_agg(DISTINCT helper_name) FROM public.booking_slots(pg_temp.at(34, '00:00'), pg_temp.at(34, '23:59')))
         = ARRAY['Peter'], 'time off not respected';
END $$;
UPDATE public.booking_settings SET buffer_minutes = 15;
DO $$ BEGIN
  ASSERT NOT EXISTS (SELECT 1 FROM public.booking_slots(pg_temp.at(30, '10:00'), pg_temp.at(30, '10:00'))
                     WHERE helper_name = 'Zuzana'), 'buffer not respected';
END $$;
UPDATE public.booking_settings SET buffer_minutes = 0;

\echo 'stale pending (>10 min) frees the slot and the application'
UPDATE public.appointments SET created_at = now() - interval '11 minutes' WHERE application_id = 'bbbbbbbb-0000-0000-0000-000000000001';
SELECT public.book_appointment('tok3', pg_temp.at(30, '09:00'), 'aaaaaaaa-0000-0000-0000-000000000001') AS a3 \gset
DO $$ BEGIN
  ASSERT (SELECT status || '/' || cancel_reason FROM public.appointments WHERE application_id = 'bbbbbbbb-0000-0000-0000-000000000001')
         = 'cancelled/expired';
END $$;
SELECT public.book_appointment('tok1', pg_temp.at(32, '09:00'), 'aaaaaaaa-0000-0000-0000-000000000002') AS a1b \gset
UPDATE public.appointments SET status = 'confirmed' WHERE status = 'pending';

\echo 'validation'
SELECT pg_temp.expect_error($$INSERT INTO public.helper_availability (helper_id, day_of_week, start_time, end_time, timezone)
  VALUES ('aaaaaaaa-0000-0000-0000-000000000001', 1, '09:00', '10:00', 'Mars/Base')$$, 'invalid timezone');
SELECT pg_temp.expect_error($$INSERT INTO public.helper_availability (helper_id, day_of_week, start_time, end_time)
  VALUES ('aaaaaaaa-0000-0000-0000-000000000001', 1, '10:00', '09:00')$$, 'check constraint');
SELECT pg_temp.expect_error($$INSERT INTO public.helper_availability (helper_id, day_of_week, start_time, end_time)
  VALUES ('aaaaaaaa-0000-0000-0000-000000000001', 0, '09:00', '10:00')$$, 'check constraint');

\echo 'RLS: anon'
SET ROLE anon;
DO $$ BEGIN ASSERT (SELECT count(*) FROM public.booking_slots()) > 0; END $$;
DO $$ BEGIN ASSERT (SELECT count(*) FROM public.booking_settings) = 1; END $$;
SELECT pg_temp.expect_error('SELECT * FROM public.helpers', 'permission denied');
SELECT pg_temp.expect_error('SELECT * FROM public.appointments', 'permission denied');
SELECT pg_temp.expect_error($$SELECT public.book_appointment('tok3', now())$$, 'permission denied');
RESET ROLE;

\echo 'RLS: helper (Zuzana)'
SET ROLE authenticated;
SET request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM public.helpers) = 1, 'helper sees other helpers';
  ASSERT (SELECT bool_and(helper_id = 'aaaaaaaa-0000-0000-0000-000000000001') FROM public.helper_availability), 'helper sees foreign availability';
  ASSERT (SELECT bool_and(helper_id = 'aaaaaaaa-0000-0000-0000-000000000001') FROM public.appointments), 'helper sees foreign appointments';
  -- application of the active appointment only (tok3), not the expired tok1 one nor tok2 (Peter)
  ASSERT (SELECT array_agg(token) FROM public.consultation_applications) = ARRAY['tok3'], 'helper application visibility';
END $$;
INSERT INTO public.helper_availability (helper_id, day_of_week, start_time, end_time)
VALUES ('aaaaaaaa-0000-0000-0000-000000000001', 1, '14:00', '16:00');
SELECT pg_temp.expect_error($$INSERT INTO public.helper_availability (helper_id, day_of_week, start_time, end_time)
  VALUES ('aaaaaaaa-0000-0000-0000-000000000002', 1, '14:00', '16:00')$$, 'row-level security');
DO $$ DECLARE n int; BEGIN
  WITH d AS (DELETE FROM public.helper_availability WHERE helper_id = 'aaaaaaaa-0000-0000-0000-000000000002' RETURNING 1)
  SELECT count(*) INTO n FROM d;
  ASSERT n = 0, 'helper deleted foreign availability';
  WITH u AS (UPDATE public.appointments SET status = 'completed', helper_note = 'ok' WHERE application_id = 'bbbbbbbb-0000-0000-0000-000000000003' RETURNING 1)
  SELECT count(*) INTO n FROM u;
  ASSERT n = 1, 'helper cannot set outcome';
END $$;
SELECT pg_temp.expect_error($$UPDATE public.appointments SET status = 'cancelled'$$, 'row-level security');
SELECT pg_temp.expect_error($$UPDATE public.appointments SET starts_at = now()$$, 'permission denied');
SELECT pg_temp.expect_error($$INSERT INTO public.appointments (application_id, helper_id, starts_at, ends_at)
  VALUES ('bbbbbbbb-0000-0000-0000-000000000003', 'aaaaaaaa-0000-0000-0000-000000000001', now(), now() + interval '1 hour')$$, 'permission denied');
DO $$ DECLARE n int; BEGIN
  WITH u AS (UPDATE public.booking_settings SET horizon_days = 5 RETURNING 1) SELECT count(*) INTO n FROM u;
  ASSERT n = 0, 'helper changed booking settings';
END $$;
RESET ROLE;

\echo 'RLS: unrelated user sees nothing; admin sees all'
SET ROLE authenticated;
SET request.jwt.claim.sub = '33333333-3333-3333-3333-333333333333';
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM public.helpers) + (SELECT count(*) FROM public.helper_availability)
       + (SELECT count(*) FROM public.appointments) + (SELECT count(*) FROM public.consultation_applications) = 0;
END $$;
SET request.jwt.claim.sub = '44444444-4444-4444-4444-444444444444';
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM public.helpers) = 2;
  ASSERT (SELECT count(*) FROM public.appointments) >= 3;
  ASSERT (SELECT count(*) FROM public.consultation_applications) = 4;
END $$;
DO $$ DECLARE n int; BEGIN
  WITH u AS (UPDATE public.booking_settings SET horizon_days = 90 RETURNING 1) SELECT count(*) INTO n FROM u;
  ASSERT n = 1, 'admin cannot update settings';
END $$;
RESET ROLE;

\echo 'all assertions passed'
