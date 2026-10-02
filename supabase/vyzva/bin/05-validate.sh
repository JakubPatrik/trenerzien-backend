#!/usr/bin/env bash
# Step 5: validate the import against the fresh export from step 2.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./00-config.sh

echo "--- Expected (from latest export) ---"
for t in profiles user_roles memberships; do
  echo "  $t: $(jq length "$EXPORT_DIR/$t.json")"
done
echo "  admin roles: $(jq '[.[] | select(.role=="admin")] | length' "$EXPORT_DIR/user_roles.json")"

echo ""
echo "--- Actual (new project) ---"
psql "$DIRECT_URL" -c "select count(*) as auth_users from auth.users;"
psql "$DIRECT_URL" -c "select count(*) as profiles from public.profiles;"
psql "$DIRECT_URL" -c "select count(*) as user_roles from public.user_roles;"
psql "$DIRECT_URL" -c "select count(*) filter (where role='admin') as admin_roles from public.user_roles;"
psql "$DIRECT_URL" -c "select count(*) as memberships from public.memberships;"

echo ""
echo "--- Integrity checks (all should be 0) ---"
psql "$DIRECT_URL" -c "
select count(*) as orphaned_memberships
from public.memberships m left join auth.users u on u.id = m.user_id
where u.id is null;"
psql "$DIRECT_URL" -c "
select count(*) as orphaned_roles
from public.user_roles r left join auth.users u on u.id = r.user_id
where u.id is null;"
psql "$DIRECT_URL" -c "
select count(*) as profiles_without_auth_user
from public.profiles p left join auth.users u on u.id = p.id
where u.id is null;"

echo ""
echo "--- Breakdowns ---"
psql "$DIRECT_URL" -c "select status, count(*) from public.memberships group by status order by 1;"
psql "$DIRECT_URL" -c "select plan_name, count(*) from public.memberships group by plan_name order by 2 desc;"

echo ""
echo "Compare the two blocks above by hand against 'Expected'. If they match,"
echo "move on to the manual smoke test in MIGRATION.md §7."
