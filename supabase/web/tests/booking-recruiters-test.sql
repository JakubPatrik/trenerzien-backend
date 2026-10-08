-- Assertions for 6.sql (KLUB personalistky: user_roles 'personalistka' → helpers,
-- guides lose the calendar, member_badges()). Run by booking-test.sh after
-- booking-guides-test.sql and 6.sql, on a throwaway local Postgres.
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

CREATE FUNCTION pg_temp.day(days int) RETURNS date LANGUAGE sql STABLE AS $$
  SELECT (now() AT TIME ZONE 'Europe/Bratislava')::date + days
$$;

-- 6666 linked@x.sk = active guide from booking-guides-test.sql, 7777 member@x.sk = plain member
INSERT INTO auth.users VALUES ('99999999-9999-9999-9999-999999999999', 'admin@x.sk');
INSERT INTO public.user_roles VALUES ('99999999-9999-9999-9999-999999999999', 'admin'),
                                     ('77777777-7777-7777-7777-777777777777', 'leader');
INSERT INTO public.profiles (id, full_name, founder_at) VALUES
  ('66666666-6666-6666-6666-666666666666', 'Linked Guide', NULL),
  ('77777777-7777-7777-7777-777777777777', 'Mia Recruiter', now());

\echo 'recruiters: 6.sql deactivated guides, script helpers untouched'
DO $$ BEGIN
  ASSERT NOT (SELECT active FROM public.helpers WHERE email = 'linked@x.sk'), 'guide still active';
  ASSERT (SELECT bool_and(active) FROM public.helpers WHERE email IN ('zuzana@x.sk', 'peter@x.sk')), 'script helpers deactivated';
  ASSERT NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'sync_guide_helper'), 'old trigger left';
END $$;
INSERT INTO public.memberships (user_id, name) VALUES ('55555555-5555-5555-5555-555555555555', 'Sprievodkyňa klubu');
DO $$ BEGIN
  ASSERT NOT (SELECT active FROM public.helpers WHERE email = 'anna@x.sk'), 'guide membership reactivated helper';
END $$;

\echo 'recruiters: inactive guide cannot write availability'
SET ROLE authenticated;
SET request.jwt.claim.sub = '66666666-6666-6666-6666-666666666666';
SELECT pg_temp.expect_error(format($$INSERT INTO public.helper_availability (helper_id, date, start_time, end_time)
  VALUES (%L, pg_temp.day(3), '10:00', '11:00')$$, (SELECT id FROM public.helpers WHERE email = 'linked@x.sk')), 'row-level security');

\echo 'recruiters: only admin grants personalistka, and only that role'
SELECT pg_temp.expect_error($$INSERT INTO public.user_roles VALUES ('66666666-6666-6666-6666-666666666666', 'personalistka')$$, 'row-level security');
SET request.jwt.claim.sub = '99999999-9999-9999-9999-999999999999';
SELECT pg_temp.expect_error($$INSERT INTO public.user_roles VALUES ('66666666-6666-6666-6666-666666666666', 'admin')$$, 'row-level security');
INSERT INTO public.user_roles VALUES ('77777777-7777-7777-7777-777777777777', 'personalistka');
RESET ROLE;
DO $$ BEGIN
  ASSERT (SELECT name || '/' || email || '/' || active FROM public.helpers
          WHERE user_id = '77777777-7777-7777-7777-777777777777') = 'Mia Recruiter/member@x.sk/true', 'recruiter helper row';
  ASSERT public.is_recruiter('77777777-7777-7777-7777-777777777777'), 'is_recruiter';
  ASSERT NOT public.is_recruiter('66666666-6666-6666-6666-666666666666'), 'guide is recruiter';
  ASSERT public.is_club_member('77777777-7777-7777-7777-777777777777'), 'recruiter not club member';
END $$;

\echo 'recruiters: recruiter sets availability, WEB offers it'
SET ROLE authenticated;
SET request.jwt.claim.sub = '77777777-7777-7777-7777-777777777777';
INSERT INTO public.helper_availability (helper_id, date, start_time, end_time)
SELECT id, pg_temp.day(4), '09:00', '10:00' FROM public.helpers WHERE user_id = auth.uid();
RESET ROLE;
DO $$ BEGIN
  ASSERT EXISTS (SELECT 1 FROM public.booking_slots() WHERE helper_name = 'Mia Recruiter'), 'recruiter slot not offered';
END $$;

\echo 'badges: RL, Z, S, P combine in fixed order; anonymous sees nothing'
INSERT INTO public.user_roles VALUES ('66666666-6666-6666-6666-666666666666', 'personalistka');
SET ROLE authenticated;
SET request.jwt.claim.sub = '77777777-7777-7777-7777-777777777777';
DO $$ BEGIN
  ASSERT (SELECT badges FROM public.member_badges() WHERE user_id = '77777777-7777-7777-7777-777777777777') = ARRAY['RL','Z','P'], 'mia badges';
  ASSERT (SELECT badges FROM public.member_badges() WHERE user_id = '66666666-6666-6666-6666-666666666666') = ARRAY['S','P'], 'guide+recruiter badges';
  ASSERT NOT EXISTS (SELECT 1 FROM public.member_badges() WHERE cardinality(badges) = 0), 'empty badges returned';
END $$;
SET request.jwt.claim.sub = '';
DO $$ BEGIN ASSERT NOT EXISTS (SELECT 1 FROM public.member_badges()), 'anonymous sees badges'; END $$;
RESET ROLE;
DO $$ BEGIN ASSERT (SELECT active FROM public.helpers WHERE email = 'linked@x.sk'), 'guide+recruiter not reactivated'; END $$;

\echo 'recruiters: admin removes role → inactive, availability kept'
SET ROLE authenticated;
SET request.jwt.claim.sub = '99999999-9999-9999-9999-999999999999';
DELETE FROM public.user_roles WHERE user_id = '77777777-7777-7777-7777-777777777777' AND role = 'personalistka';
RESET ROLE;
SET request.jwt.claim.sub = '';
DO $$ BEGIN
  ASSERT NOT (SELECT active FROM public.helpers WHERE email = 'member@x.sk'), 'still active after removal';
  ASSERT NOT EXISTS (SELECT 1 FROM public.booking_slots() WHERE helper_name = 'Mia Recruiter'), 'removed recruiter offered';
  ASSERT (SELECT count(*) FROM public.helper_availability a JOIN public.helpers h ON h.id = a.helper_id
          WHERE h.email = 'member@x.sk') = 1, 'availability lost';
  ASSERT EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = '77777777-7777-7777-7777-777777777777' AND role = 'leader'), 'leader role removed';
END $$;

\echo 'all recruiter assertions passed'
