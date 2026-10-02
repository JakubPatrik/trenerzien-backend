#!/usr/bin/env bash
# Apply 4.sql (booking: helpers, helper_availability, helper_time_off,
# booking_settings, appointments, booking_slots(), book_appointment()) to the
# vyzva project. Re-runnable: IF NOT EXISTS / CREATE OR REPLACE / DROP IF EXISTS.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./00-config.sh

echo "Target DB:"
psql "$DIRECT_URL" -c "select current_database(), inet_server_addr();"

confirm "About to create the booking tables, functions and RLS policies in the DB above."

f="$MIGRATIONS_DIR/4.sql"
echo "== $f"
psql "$DIRECT_URL" -v ON_ERROR_STOP=1 -f "$f"

echo ""
psql "$DIRECT_URL" -c "select * from public.booking_settings;"
psql "$DIRECT_URL" -c "
  select h.name, h.active, count(a.id) as availability_windows
  from public.helpers h left join public.helper_availability a on a.helper_id = h.id
  group by h.id order by h.sort_order, h.name;"
echo "Done. Add helpers with 10-add-helper.sh."
