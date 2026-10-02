#!/usr/bin/env bash
# Step 1: apply the 4 drizzle migrations to the new (empty) Supabase project,
# then verify the schema landed correctly.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./00-config.sh

echo "Target DB:"
psql "$DIRECT_URL" -c "select current_database(), inet_server_addr();"

confirm "About to apply 4 migrations (profiles/user_roles/memberships + columns) to the DB above."

for f in "$BACKEND_DIR"/drizzle/migrations/meta/{0,1,2,3}.sql; do
  echo "== $f"
  psql "$DIRECT_URL" -f "$f"
done

echo ""
echo "--- Verification ---"
psql "$DIRECT_URL" -c "select tablename, rowsecurity from pg_tables where schemaname='public';"
psql "$DIRECT_URL" -c "select typname from pg_type where typname in ('app_role','membership_status');"
psql "$DIRECT_URL" -c "select proname from pg_proc where proname in ('has_role','handle_new_user');"
psql "$DIRECT_URL" -c "select tgname from pg_trigger where tgrelid = 'auth.users'::regclass;"

echo ""
echo "Expect: profiles/user_roles/memberships all rowsecurity=t; both enums present;"
echo "has_role + handle_new_user present; on_auth_user_created trigger present."
echo ""
echo "Also do manually in the Supabase dashboard (not scriptable via psql):"
echo "  Authentication > Providers: Email on, Enable signups OFF, Google if used"
echo "  Authentication > URL Configuration: Site URL + redirect URLs for vyzva.trenerzien.sk"
