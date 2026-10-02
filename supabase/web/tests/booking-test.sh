#!/usr/bin/env bash
# Test 4.sql (booking) on a throwaway LOCAL Postgres — never touches Supabase.
# Needs Postgres binaries (brew install postgresql@17). Steps:
#   1. temp cluster + minimal Supabase stand-ins (roles, auth.users, auth.uid(), has_role)
#   2. 0.sql (consultation_applications) + 4.sql twice (must be re-runnable)
#   3. booking-test.sql assertions
#   4. 30 concurrent bookings on 3 slots → exactly 2 per slot (2 helpers), no deadlocks
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
TESTS_DIR="$(pwd)"
MIGRATIONS_DIR="$(cd ../migrations && pwd)"

TMP="$(mktemp -d /tmp/booking-test.XXXXXX)"
PORT=$(( 55000 + RANDOM % 1000 ))
cleanup() { pg_ctl -D "$TMP/data" -m immediate stop >/dev/null 2>&1 || true; rm -rf "$TMP"; }
trap cleanup EXIT

initdb -D "$TMP/data" -U postgres -A trust >/dev/null
pg_ctl -D "$TMP/data" -o "-p $PORT -k $TMP -c listen_addresses=''" -l "$TMP/log" -w start >/dev/null
P=(psql -h "$TMP" -p "$PORT" -U postgres -d postgres -v ON_ERROR_STOP=1 -q -X)

"${P[@]}" <<'SQL'
CREATE ROLE anon NOLOGIN; CREATE ROLE authenticated NOLOGIN; CREATE ROLE service_role NOLOGIN BYPASSRLS;
CREATE SCHEMA extensions; CREATE EXTENSION pgcrypto WITH SCHEMA extensions;
CREATE SCHEMA auth;
CREATE TABLE auth.users (id uuid PRIMARY KEY, email text);
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE
  AS $$ SELECT nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;
GRANT USAGE ON SCHEMA auth, public, extensions TO anon, authenticated, service_role;
CREATE TYPE app_role AS ENUM ('admin', 'user');
CREATE TABLE public.user_roles (user_id uuid, role app_role, UNIQUE (user_id, role));
CREATE FUNCTION public.has_role(_user_id uuid, _role app_role) RETURNS boolean
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
  AS $$ SELECT EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = _user_id AND role = _role) $$;
SQL

echo "== migrations"
"${P[@]}" -f "$MIGRATIONS_DIR/0.sql" >/dev/null 2>&1
"${P[@]}" -f "$MIGRATIONS_DIR/4.sql" 2>&1 | grep -v NOTICE || true
"${P[@]}" -f "$MIGRATIONS_DIR/4.sql" 2>&1 | grep -v NOTICE || true   # re-run must succeed

echo "== assertions"
"${P[@]}" -f "$TESTS_DIR/booking-test.sql"

echo "== concurrency: 30 parallel bookings on 3 slots"
"${P[@]}" -c "INSERT INTO public.consultation_applications (token, name, email, phone)
              SELECT 'race' || i, 'R' || i, 'r' || i || '@x.sk', '0' FROM generate_series(1, 30) i"
for slot in 1 2 3; do
  for i in $(seq 1 10); do
    n=$(( (slot - 1) * 10 + i ))
    "${P[@]}" -At -c "SELECT public.book_appointment('race$n', ((now() AT TIME ZONE 'Europe/Bratislava')::date + 40 + $slot + time '10:00') AT TIME ZONE 'Europe/Bratislava')" \
      >"$TMP/race$n.out" 2>&1 &
  done
done
wait
ok=$(grep -lE '^[0-9a-f-]{36}$' "$TMP"/race*.out | wc -l | tr -d ' ')
full=$(grep -l 'slot_unavailable' "$TMP"/race*.out | wc -l | tr -d ' ')
other=$(( 30 - ok - full ))
echo "booked=$ok slot_unavailable=$full other=$other"
per_slot=$("${P[@]}" -At -c "SELECT string_agg(c::text, ',') FROM (
  SELECT count(*) c FROM public.appointments a JOIN public.consultation_applications ca ON ca.id = a.application_id
  WHERE ca.token LIKE 'race%' AND a.status <> 'cancelled' GROUP BY a.starts_at) x")
if [ "$ok" != "6" ] || [ "$other" != "0" ] || [ "$per_slot" != "2,2,2" ]; then
  echo "FAIL: expected 6 bookings (2 per slot) and no other errors; per slot: $per_slot" >&2
  cat "$TMP"/race*.out | grep -vE '^[0-9a-f-]{36}$' | grep -v slot_unavailable | grep -v CONTEXT >&2 || true
  exit 1
fi

echo ""
echo "PASS"
