#!/usr/bin/env bash
# Apply 9.sql: roles 'leader' and 'lider' (app_role) merge into 'lider'. Every
# user_roles 'leader' becomes 'lider'; functions and RLS policies that check
# 'leader' are rewritten to 'lider'; a trigger stores any new 'leader' as
# 'lider'. One transaction — if anything still uses 'leader' at the end,
# nothing changes. Re-runnable.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./00-config.sh

echo "Target DB:"
psql "$DIRECT_URL" -c "select current_database(), inet_server_addr();"

leaders() {
  psql "$DIRECT_URL" -c "
    select u.email, string_agg(r.role::text, ', ' order by r.role::text) as roles
    from public.user_roles r
    join auth.users u on u.id = r.user_id
    where r.role::text in ('leader', 'lider')
    group by u.email
    order by u.email;"
}

echo "Leaders today:"
leaders

echo "Functions / policies still checking 'leader':"
psql "$DIRECT_URL" -c "
  select 'function' as kind, p.proname as name
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.prokind = 'f'
    and p.proname <> 'user_roles_leader_to_lider'
    and pg_get_functiondef(p.oid) like '%''leader''%'
  union all
  select 'policy', tablename || ': ' || policyname
  from pg_policies
  where coalesce(qual, '') || coalesce(with_check, '') like '%''leader''%'
  order by 1, 2;"

confirm "About to apply 9.sql (everyone above ends up with 'lider' only; functions and policies switch to 'lider')."

psql "$DIRECT_URL" -v ON_ERROR_STOP=1 --single-transaction -f "$MIGRATIONS_DIR/9.sql"

echo ""
echo "Leaders after (roles must be just 'lider'):"
leaders
echo "Done."
