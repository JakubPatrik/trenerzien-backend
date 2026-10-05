#!/usr/bin/env bash
# Backfill / repair: make sure every 'Sprievodkyňa klubu' member has a helpers
# row (KLUB „Moja dostupnosť“ needs it) and that ended memberships are inactive.
# New or changed memberships are handled by the trigger from 5.sql — this is
# for the initial backfill and as a manual repair. Safe to re-run.
#
#   ./14-sync-guide-helpers.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./00-config.sh

if [ "$(psql "$DIRECT_URL" -At -c "select count(*) from pg_proc where proname = 'sync_guide_helper'")" = "0" ]; then
  echo "public.sync_guide_helper() is missing — run 08-apply-booking.sh (4.sql + 5.sql) first." >&2
  exit 1
fi

echo "Guide memberships:"
psql "$DIRECT_URL" -c "
  select u.email, m.status, m.ends_at, h.id is not null as has_helper, h.active
  from public.memberships m
  join auth.users u on u.id = m.user_id
  left join public.helpers h on h.user_id = m.user_id
  where m.name = 'Sprievodkyňa klubu'
  order by u.email;"

confirm "About to create / (de)activate helpers rows for the guides above."

psql "$DIRECT_URL" -v ON_ERROR_STOP=1 -q -c "
  select public.sync_guide_helper(user_id)
  from (select distinct user_id from public.memberships where name = 'Sprievodkyňa klubu') x;" >/dev/null

psql "$DIRECT_URL" -c "
  select h.name, h.email, h.active, public.is_guide(h.user_id) as is_guide
  from public.helpers h
  where h.user_id in (select user_id from public.memberships where name = 'Sprievodkyňa klubu')
  order by h.name;"
