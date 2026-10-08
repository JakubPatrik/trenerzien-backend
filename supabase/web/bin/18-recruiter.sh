#!/usr/bin/env bash
# Add / remove the KLUB role 'personalistka' (leads interviews — sets her
# availability in KLUB „Moja dostupnosť“). The trigger from 6.sql creates or
# (de)activates her helpers row. KLUB admins can do the same in the app.
#
#   ./18-recruiter.sh add jana@example.sk
#   ./18-recruiter.sh remove jana@example.sk
#   ./18-recruiter.sh list
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./00-config.sh

ACTION="${1:-}"; EMAIL="${2:-}"
list() {
  psql "$DIRECT_URL" -c "
    select u.email, p.full_name, h.active as helper_active
    from public.user_roles r
    join auth.users u on u.id = r.user_id
    left join public.profiles p on p.id = r.user_id
    left join public.helpers h on h.user_id = r.user_id
    where r.role::text = 'personalistka'
    order by u.email;"
}

case "$ACTION" in
  list) list; exit 0 ;;
  add|remove) [ -n "$EMAIL" ] || { sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 1; } ;;
  *) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac

USER_ID="$(psql "$DIRECT_URL" -At -v email="$EMAIL" <<'SQL'
select public.find_auth_user_id_by_email(:'email');
SQL
)"
if [ -z "$USER_ID" ]; then
  echo "No account with email $EMAIL." >&2
  exit 1
fi

if [ "$ACTION" = add ]; then
  psql "$DIRECT_URL" -v ON_ERROR_STOP=1 -q -v uid="$USER_ID" <<'SQL'
insert into public.user_roles (user_id, role) values (:'uid', 'personalistka') on conflict do nothing;
SQL
else
  psql "$DIRECT_URL" -v ON_ERROR_STOP=1 -q -v uid="$USER_ID" <<'SQL'
delete from public.user_roles where user_id = :'uid' and role::text = 'personalistka';
SQL
fi
list
