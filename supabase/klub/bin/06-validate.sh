#!/usr/bin/env bash
# Read-only: compare row counts and check integrity after the sync.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./00-config.sh

echo "--- Expected additions (from transformed export) ---"
echo "  new auth users: $(jq length "$EXPORT_DIR/new-auth-users.json")"
echo "  klub profiles:  $(jq length "$EXPORT_DIR/profiles.json")"
echo "  klub roles:     $(jq length "$EXPORT_DIR/user_roles.json")"
echo "  klub memberships: $(jq length "$EXPORT_DIR/memberships.json")"

echo ""
echo "--- Actual totals in target (vyzva + klub combined) ---"
psql "$DIRECT_URL" -c "select count(*) as auth_users from auth.users;"
psql "$DIRECT_URL" -c "select count(*) as profiles from public.profiles;"
psql "$DIRECT_URL" -c "select role, count(*) from public.user_roles group by role order by 1;"
psql "$DIRECT_URL" -c "select count(*) as memberships from public.memberships;"
psql "$DIRECT_URL" -c "select source, count(*) from public.memberships group by source order by 2 desc;"

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
select count(*) as profiles_missing_email
from public.profiles where email is null or email = '';"

echo ""
echo "--- Spot check: a merged identity (should show BOTH vyzva and klub data) ---"
psql "$DIRECT_URL" -c "
select id, email, full_name, city, invitation
from public.profiles where email = 'cmeldaniel@gmail.com';"
