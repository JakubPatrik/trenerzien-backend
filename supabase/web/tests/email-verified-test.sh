#!/usr/bin/env bash
# Test 14.sql (profiles.email_verified_at) on a throwaway LOCAL Postgres — never touches Supabase.
# Needs Postgres binaries (brew install postgresql@17).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
MIGRATIONS_DIR="$(cd ../migrations && pwd)"

TMP="$(mktemp -d /tmp/email-verified-test.XXXXXX)"
PORT=$(( 56000 + RANDOM % 1000 ))
cleanup() { pg_ctl -D "$TMP/data" -m immediate stop >/dev/null 2>&1 || true; rm -rf "$TMP"; }
trap cleanup EXIT

initdb -D "$TMP/data" -U postgres -A trust >/dev/null
pg_ctl -D "$TMP/data" -o "-p $PORT -k $TMP -c listen_addresses=''" -l "$TMP/log" -w start >/dev/null
P=(psql -h "$TMP" -p "$PORT" -U postgres -d postgres -v ON_ERROR_STOP=1 -q -X)

# Minimal Supabase stand-ins + profiles as in production.
"${P[@]}" <<'SQL'
CREATE ROLE anon NOLOGIN; CREATE ROLE authenticated NOLOGIN; CREATE ROLE service_role NOLOGIN BYPASSRLS;
CREATE SCHEMA auth;
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE
  AS $$ SELECT nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;
GRANT USAGE ON SCHEMA auth, public TO anon, authenticated, service_role;
CREATE TYPE app_role AS ENUM ('admin', 'user');
CREATE TABLE public.user_roles (user_id uuid, role app_role);
CREATE FUNCTION public.has_role(_user_id uuid, _role app_role) RETURNS boolean
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
  AS $$ SELECT EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = _user_id AND role = _role) $$;
CREATE TYPE invitation_state AS ENUM ('none', 'invited', 'accepted');
CREATE TABLE public.profiles (id uuid PRIMARY KEY, email text, invitation invitation_state NOT NULL DEFAULT 'none',
  invited_at timestamptz, updated_at timestamptz DEFAULT now());
GRANT SELECT, UPDATE ON public.profiles TO authenticated;
INSERT INTO public.user_roles VALUES ('00000000-0000-0000-0000-00000000000a', 'admin');
INSERT INTO public.profiles (id, email, invitation, invited_at) VALUES
  ('00000000-0000-0000-0000-000000000001', 'old@x.sk', 'accepted', '2026-09-01'),
  ('00000000-0000-0000-0000-000000000002', 'new@x.sk', 'invited', '2026-10-01'),
  ('00000000-0000-0000-0000-000000000003', 'none@x.sk', 'none', NULL);
SQL

for i in 1 2; do "${P[@]}" -f "$MIGRATIONS_DIR/14.sql" 2>&1 | grep -v NOTICE || true; done   # re-runnable

"${P[@]}" <<'SQL'
\set ON_ERROR_STOP 1
DO $$ BEGIN
  ASSERT (SELECT email_verified_at FROM public.profiles WHERE email = 'old@x.sk') = '2026-09-01', 'backfill = invited_at';
  ASSERT (SELECT email_verified_at FROM public.profiles WHERE email = 'new@x.sk') IS NULL, 'invited is not verified';
END $$;

-- The member herself on /nove-heslo: invitation → accepted.
SET ROLE authenticated;
SET request.jwt.claim.sub = '00000000-0000-0000-0000-000000000002';
UPDATE public.profiles SET invitation = 'accepted' WHERE id = '00000000-0000-0000-0000-000000000002';
-- She can't fake or clear it.
UPDATE public.profiles SET email_verified_at = NULL WHERE id = '00000000-0000-0000-0000-000000000002';
SET request.jwt.claim.sub = '00000000-0000-0000-0000-000000000003';
UPDATE public.profiles SET email_verified_at = now() WHERE id = '00000000-0000-0000-0000-000000000003';
RESET ROLE;
DO $$ BEGIN
  ASSERT (SELECT email_verified_at > now() - interval '1 minute' FROM public.profiles WHERE email = 'new@x.sk'), 'accept sets it';
  ASSERT (SELECT email_verified_at FROM public.profiles WHERE email = 'none@x.sk') IS NULL, 'member set it herself';
END $$;

-- Accepted again later (re-invite): the first time stays.
UPDATE public.profiles SET invitation = 'invited' WHERE email = 'old@x.sk';
UPDATE public.profiles SET invitation = 'accepted' WHERE email = 'old@x.sk';
DO $$ BEGIN
  ASSERT (SELECT email_verified_at FROM public.profiles WHERE email = 'old@x.sk') = '2026-09-01', 'first verification kept';
END $$;

-- Admin can correct it.
SET ROLE authenticated;
SET request.jwt.claim.sub = '00000000-0000-0000-0000-00000000000a';
UPDATE public.profiles SET email_verified_at = NULL WHERE email = 'old@x.sk';
RESET ROLE;
DO $$ BEGIN
  ASSERT (SELECT email_verified_at FROM public.profiles WHERE email = 'old@x.sk') IS NULL, 'admin edit';
END $$;
SQL

echo "PASS"
