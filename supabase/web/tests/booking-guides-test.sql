-- Assertions for 5.sql (KLUB guides: membership → helpers, dated availability).
-- Run by booking-test.sh after booking-test.sql, on a throwaway local Postgres.
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
CREATE FUNCTION pg_temp.day(days int) RETURNS date LANGUAGE sql STABLE AS $$
  SELECT (now() AT TIME ZONE 'Europe/Bratislava')::date + days
$$;

UPDATE public.booking_settings SET horizon_days = 31, min_notice_minutes = 0;

INSERT INTO auth.users VALUES
  ('55555555-5555-5555-5555-555555555555', 'anna@x.sk'),
  ('66666666-6666-6666-6666-666666666666', 'Linked@x.sk'),
  ('77777777-7777-7777-7777-777777777777', 'member@x.sk'),
  ('88888888-8888-8888-8888-888888888888', 'ended@x.sk');
INSERT INTO public.profiles VALUES ('55555555-5555-5555-5555-555555555555', 'Anna Guide');

\echo 'guides: membership creates helper once; other memberships do not'
INSERT INTO public.memberships (user_id, name) VALUES
  ('55555555-5555-5555-5555-555555555555', 'Sprievodkyňa klubu'),
  ('77777777-7777-7777-7777-777777777777', 'Členstvo — ročné');
INSERT INTO public.memberships (user_id, name, ends_at) VALUES
  ('88888888-8888-8888-8888-888888888888', 'Sprievodkyňa klubu', now() - interval '1 day');
UPDATE public.memberships SET status = 'active' WHERE user_id = '55555555-5555-5555-5555-555555555555';
DO $$ BEGIN
  ASSERT (SELECT name || '/' || email || '/' || active FROM public.helpers
          WHERE user_id = '55555555-5555-5555-5555-555555555555') = 'Anna Guide/anna@x.sk/true', 'guide helper row';
  ASSERT (SELECT count(*) FROM public.helpers WHERE user_id = '55555555-5555-5555-5555-555555555555') = 1, 'duplicate helper';
  ASSERT NOT EXISTS (SELECT 1 FROM public.helpers WHERE user_id IN
    ('77777777-7777-7777-7777-777777777777', '88888888-8888-8888-8888-888888888888')), 'non-guide got a helper row';
END $$;

\echo 'guides: links a script-added helper by email (no profile → name kept)'
INSERT INTO public.helpers (name, email) VALUES ('Linked Helper', 'linked@x.sk');
INSERT INTO public.memberships (user_id, name) VALUES ('66666666-6666-6666-6666-666666666666', 'Sprievodkyňa klubu');
DO $$ BEGIN
  ASSERT (SELECT user_id FROM public.helpers WHERE email = 'linked@x.sk') = '66666666-6666-6666-6666-666666666666', 'not linked';
  ASSERT (SELECT count(*) FROM public.helpers WHERE lower(email) = 'linked@x.sk') = 1, 'duplicate by email';
END $$;

\echo 'availability: guide toggles dated slots (RLS, unique, range)'
SET ROLE authenticated;
SET request.jwt.claim.sub = '55555555-5555-5555-5555-555555555555';
SELECT id AS anna FROM public.helpers WHERE user_id = auth.uid() \gset
INSERT INTO public.helper_availability (helper_id, date, start_time, end_time)
VALUES (:'anna', pg_temp.day(5), '10:00', '11:00'), (:'anna', pg_temp.day(20), '18:00', '19:00'),
       (:'anna', pg_temp.day(31), '18:00', '19:00');  -- last allowed day
SELECT pg_temp.expect_error(format($$INSERT INTO public.helper_availability (helper_id, date, start_time, end_time)
  VALUES (%L, pg_temp.day(5), '10:00', '11:00')$$, :'anna'), 'duplicate key');
SELECT pg_temp.expect_error(format($$INSERT INTO public.helper_availability (helper_id, date, start_time, end_time)
  VALUES (%L, pg_temp.day(-1), '10:00', '11:00')$$, :'anna'), 'outside');
SELECT pg_temp.expect_error(format($$INSERT INTO public.helper_availability (helper_id, date, start_time, end_time)
  VALUES (%L, pg_temp.day(32), '10:00', '11:00')$$, :'anna'), 'outside');
SELECT pg_temp.expect_error(format($$INSERT INTO public.helper_availability (helper_id, start_time, end_time)
  VALUES (%L, '10:00', '11:00')$$, :'anna'), 'helper_availability_day_or_date');
SELECT pg_temp.expect_error(format($$INSERT INTO public.helper_availability (helper_id, day_of_week, date, start_time, end_time)
  VALUES (%L, 1, pg_temp.day(5), '10:00', '11:00')$$, :'anna'), 'helper_availability_day_or_date');
SELECT pg_temp.expect_error(format($$INSERT INTO public.helper_availability (helper_id, date, start_time, end_time, timezone)
  VALUES (%L, pg_temp.day(5), '12:00', '13:00', 'Mars/Base')$$, :'anna'), 'invalid timezone');
SELECT pg_temp.expect_error($$INSERT INTO public.helper_availability (helper_id, date, start_time, end_time)
  VALUES ('aaaaaaaa-0000-0000-0000-000000000001', pg_temp.day(5), '15:00', '16:00')$$, 'row-level security');
INSERT INTO public.helper_availability (helper_id, date, start_time, end_time)
VALUES (:'anna', pg_temp.day(6), '08:00', '09:00');
DELETE FROM public.helper_availability WHERE helper_id = :'anna' AND date = pg_temp.day(6);
RESET ROLE;

\echo 'slots: dated rows give exactly those slots, only on that date'
SET request.jwt.claim.sub = '';
DO $$
DECLARE v_anna uuid := (SELECT id FROM public.helpers WHERE user_id = '55555555-5555-5555-5555-555555555555');
BEGIN
  ASSERT (SELECT array_agg(starts_at ORDER BY starts_at) FROM public.booking_slots(now(), pg_temp.at(25, '00:00')) WHERE helper_id = v_anna)
         = ARRAY[pg_temp.at(5, '10:00'), pg_temp.at(20, '18:00')], 'dated slots wrong (day 6 was deleted)';
  ASSERT (SELECT count(*) FROM public.booking_slots(pg_temp.at(5, '00:00'), pg_temp.at(6, '00:00'))
          WHERE helper_id = 'aaaaaaaa-0000-0000-0000-000000000001') = 3, 'weekly helper slots changed';
END $$;

\echo 'book: a dated slot can be booked'
INSERT INTO public.consultation_applications (token, name, email, phone, qualified) VALUES ('tokG', 'G', 'g@x.sk', '5', true);
DO $$ DECLARE v_id uuid; BEGIN
  v_id := public.book_appointment('tokG', pg_temp.at(5, '10:00'), (SELECT id FROM public.helpers WHERE email = 'anna@x.sk'));
  ASSERT (SELECT helper_id FROM public.appointments WHERE id = v_id) = (SELECT id FROM public.helpers WHERE email = 'anna@x.sk');
  UPDATE public.appointments SET status = 'cancelled' WHERE id = v_id;
END $$;

\echo 'guides: ended membership deactivates (availability kept), reactivation and delete'
UPDATE public.memberships SET status = 'expired' WHERE user_id = '55555555-5555-5555-5555-555555555555';
DO $$ BEGIN
  ASSERT NOT (SELECT active FROM public.helpers WHERE email = 'anna@x.sk'), 'still active';
  ASSERT NOT EXISTS (SELECT 1 FROM public.booking_slots() WHERE helper_name = 'Anna Guide'), 'inactive guide offered';
  ASSERT (SELECT count(*) FROM public.helper_availability a JOIN public.helpers h ON h.id = a.helper_id
          WHERE h.email = 'anna@x.sk') = 3, 'availability lost';
END $$;
UPDATE public.memberships SET status = 'active' WHERE user_id = '55555555-5555-5555-5555-555555555555';
DO $$ BEGIN ASSERT (SELECT active FROM public.helpers WHERE email = 'anna@x.sk'), 'not reactivated'; END $$;
DELETE FROM public.memberships WHERE user_id = '55555555-5555-5555-5555-555555555555';
DO $$ BEGIN ASSERT NOT (SELECT active FROM public.helpers WHERE email = 'anna@x.sk'), 'active after delete'; END $$;

\echo 'guides: non-club helpers (no guide membership) stay active'
DO $$ BEGIN
  ASSERT (SELECT bool_and(active) FROM public.helpers WHERE email IN ('zuzana@x.sk', 'peter@x.sk')), 'script helpers deactivated';
END $$;

UPDATE public.booking_settings SET horizon_days = 90;  -- concurrency test books 41–43 days ahead
\echo 'all guide assertions passed'
