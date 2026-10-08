#!/usr/bin/env bash
# Apply 6.sql: role 'personalistka' (KLUB) takes over the interview calendar
# from 'Sprievodkyňa klubu' — guides' helpers rows become inactive, recruiters
# get one automatically. Also member_badges() (RL / Z / S / P). Re-runnable.
#
# Until at least one recruiter is set (18-recruiter.sh or KLUB admin), the WEB
# offers only helpers outside the club (10-add-helper.sh).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./00-config.sh

echo "Target DB:"
psql "$DIRECT_URL" -c "select current_database(), inet_server_addr();"

echo "Helpers today:"
psql "$DIRECT_URL" -c "
  select h.name, h.email, h.active,
         (select count(*) from public.appointments a
          where a.helper_id = h.id and a.status = 'confirmed' and a.starts_at > now()) as upcoming
  from public.helpers h order by h.name;"

confirm "About to apply 6.sql. Guides without the 'personalistka' role stop being offered on the WEB (upcoming meetings stay)."

psql "$DIRECT_URL" -v ON_ERROR_STOP=1 -f "$MIGRATIONS_DIR/6.sql"

echo ""
psql "$DIRECT_URL" -c "select h.name, h.email, h.active from public.helpers h order by h.active desc, h.name;"
echo "Done. Add recruiters: ./18-recruiter.sh add <email>"
