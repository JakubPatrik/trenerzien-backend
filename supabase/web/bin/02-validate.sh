#!/usr/bin/env bash
# Read-only: verify the table exists, RLS is on, and row count/ids match the
# static export.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./00-config.sh

EXPORT_FILE="$WEB_DIR/export/consultation_applications.json"
EXPECTED="$(jq length "$EXPORT_FILE")"

echo "--- Schema ---"
psql "$DIRECT_URL" -c "select relrowsecurity from pg_class where oid = 'public.consultation_applications'::regclass;"
psql "$DIRECT_URL" -c "select policyname, cmd, roles from pg_policies where tablename='consultation_applications';"

echo ""
echo "--- Row count ---"
echo "Expected (from export file): $EXPECTED"
psql "$DIRECT_URL" -c "select count(*) as actual from public.consultation_applications;"

echo ""
echo "--- Ids present ---"
psql "$DIRECT_URL" -c "select id, email, created_at from public.consultation_applications order by created_at;"
