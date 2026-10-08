-- Assertions for 7.sql (add_recruiter / remove_recruiter RPCs). Run by
-- booking-test.sh after booking-recruiters-test.sql, on a throwaway local Postgres.
-- 9999 admin@x.sk = admin, 7777 member@x.sk = leader (not a recruiter anymore).
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

INSERT INTO auth.users VALUES ('12121212-1212-1212-1212-121212121212', 'new@x.sk');
INSERT INTO auth.identities VALUES ('12121212-1212-1212-1212-121212121212', '{"email": "Old@X.sk"}');

\echo 'recruiter rpc: non-admin and anonymous are refused'
SET ROLE authenticated;
SET request.jwt.claim.sub = '77777777-7777-7777-7777-777777777777';
SELECT pg_temp.expect_error($$SELECT public.add_recruiter('new@x.sk')$$, 'forbidden');
SELECT pg_temp.expect_error($$SELECT public.remove_recruiter('linked@x.sk')$$, 'forbidden');
SELECT pg_temp.expect_error($$SELECT public.set_recruiter('new@x.sk', true)$$, 'permission denied');
SET request.jwt.claim.sub = '';
SELECT pg_temp.expect_error($$SELECT public.add_recruiter('new@x.sk')$$, 'forbidden');
RESET ROLE;
SET ROLE anon;
SELECT pg_temp.expect_error($$SELECT public.add_recruiter('new@x.sk')$$, 'permission denied');
RESET ROLE;

\echo 'recruiter rpc: admin adds by identity e-mail, idempotent, then removes'
SET ROLE authenticated;
SET request.jwt.claim.sub = '99999999-9999-9999-9999-999999999999';
SELECT pg_temp.expect_error($$SELECT public.add_recruiter('nobody@x.sk')$$, 'user_not_found');
DO $$
DECLARE r jsonb;
BEGIN
  r := public.add_recruiter('  old@x.sk ');
  ASSERT r ->> 'user_id' = '12121212-1212-1212-1212-121212121212', 'wrong user: ' || r;
  ASSERT (r ->> 'is_recruiter')::boolean AND (r ->> 'helper_active')::boolean, 'not recruiter / helper: ' || r;
  r := public.add_recruiter('new@x.sk');
  ASSERT (r ->> 'helper_active')::boolean, 'second add broke helper: ' || r;
  r := public.remove_recruiter('new@x.sk');
  ASSERT NOT (r ->> 'is_recruiter')::boolean AND NOT (r ->> 'helper_active')::boolean, 'still recruiter: ' || r;
  r := public.add_recruiter('member@x.sk');
  ASSERT (r ->> 'helper_active')::boolean, 'existing helper not reactivated: ' || r;
END $$;
RESET ROLE;
SET request.jwt.claim.sub = '';
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM public.user_roles WHERE user_id = '12121212-1212-1212-1212-121212121212') = 0, 'role left';
  ASSERT EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = '77777777-7777-7777-7777-777777777777' AND role = 'leader'), 'leader role touched';
END $$;

\echo 'all recruiter rpc assertions passed'
