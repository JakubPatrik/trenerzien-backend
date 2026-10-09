#!/usr/bin/env bash
# Apply 8.sql: role 'sprievodkyna' (app_role) replaces the 'Sprievodkyňa klubu'
# membership as what makes someone a guide (is_guide(), badge S). Today's guides
# get the role first; if any is missing it, 8.sql stops before is_guide()
# switches. Admins can toggle the role in KLUB. Re-runnable. Later guides:
# ./19-add-roles.sh <email> sprievodkyna
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./00-config.sh

echo "Target DB:"
psql "$DIRECT_URL" -c "select current_database(), inet_server_addr();"

guides() {
  psql "$DIRECT_URL" -c "
    select u.email, public.is_guide(u.id) as is_guide, public.is_club_member(u.id) as club,
           (select string_agg(r.role::text, ', ' order by r.role::text) from public.user_roles r where r.user_id = u.id) as roles
    from auth.users u
    where public.is_guide(u.id)
       or exists (select 1 from public.memberships m
                  where m.user_id = u.id and m.name = 'Sprievodkyňa klubu'
                    and m.status::text = 'active' and (m.ends_at is null or m.ends_at > now()))
    order by u.email;"
}

echo "Guides today:"
guides

confirm "About to apply 8.sql (everyone above gets role 'sprievodkyna'; is_guide() switches to the role)."

# No --single-transaction: ADD VALUE has to commit before the INSERT uses it.
psql "$DIRECT_URL" -v ON_ERROR_STOP=1 -f "$MIGRATIONS_DIR/8.sql"

echo ""
echo "Guides after (is_guide and club must be t for everyone):"
guides
echo "Done."
