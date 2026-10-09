#!/usr/bin/env bash
# Grant roles (user_roles) to an existing account, by email. Roles she already
# has are skipped. 'personalistka' also creates / activates her helpers row
# (trigger from 6.sql). The account must exist — new members come in through
# Stripe or the KLUB admin invite.
#
#   ./19-add-roles.sh gloriaondicova@gmail.com admin personalistka
#
# Roles: admin, user, lider, personalistka, sprievodkyna (app_role enum).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./00-config.sh

if [ $# -lt 2 ]; then
  sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'
  exit 1
fi
EMAIL="$1"; shift
ROLES="$(printf '%s\n' "$@" | paste -sd, -)"

USER_ID="$(psql "$DIRECT_URL" -At -v email="$EMAIL" <<'SQL'
select public.find_auth_user_id_by_email(:'email');
SQL
)"
if [ -z "$USER_ID" ]; then
  echo "No account with email $EMAIL." >&2
  exit 1
fi

show() {
  psql "$DIRECT_URL" -v uid="$USER_ID" <<'SQL'
select u.email, p.full_name,
       (select string_agg(r.role::text, ', ' order by r.role::text) from public.user_roles r where r.user_id = u.id) as roles,
       h.active as helper_active
from auth.users u
left join public.profiles p on p.id = u.id
left join public.helpers h on h.user_id = u.id
where u.id = :'uid';
SQL
}

show
confirm "About to grant roles: $ROLES"

psql "$DIRECT_URL" -v ON_ERROR_STOP=1 -q -v uid="$USER_ID" -v roles="$ROLES" <<'SQL'
insert into public.user_roles (user_id, role)
select :'uid', r::public.app_role
from unnest(string_to_array(:'roles', ',')) r
on conflict (user_id, role) do nothing;
SQL

show
