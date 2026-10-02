#!/usr/bin/env bash
# Add (or update) a helper who leads consultation calls, optionally with a
# weekly availability window. Links helpers.user_id to the existing account
# with the same email, so the helper can manage availability after login.
#
#   ./10-add-helper.sh "Zuzana Kováčová" zuzana@trenerzien.sk
#   ./10-add-helper.sh "Zuzana Kováčová" zuzana@trenerzien.sk 1-5 09:00 12:00
#
# Days are ISO: 1 = Monday … 7 = Sunday; "1-5" or "1,3,5". Times in
# Europe/Bratislava. Re-running with other times adds another window (e.g.
# afternoons); identical windows are skipped.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./00-config.sh

if [ $# -ne 2 ] && [ $# -ne 5 ]; then
  sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
  exit 1
fi
NAME="$1"; EMAIL="$2"; DAYS="${3:-}"; START="${4:-}"; END="${5:-}"

DAY_LIST=""
if [ -n "$DAYS" ]; then
  if [[ "$DAYS" =~ ^([1-7])-([1-7])$ ]]; then
    DAY_LIST="$(seq "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" | paste -sd, -)"
  elif [[ "$DAYS" =~ ^[1-7](,[1-7])*$ ]]; then
    DAY_LIST="$DAYS"
  else
    echo "Invalid days: $DAYS (use 1-5 or 1,3,5)" >&2; exit 1
  fi
  [[ "$START" =~ ^[0-2][0-9]:[0-5][0-9]$ && "$END" =~ ^[0-2][0-9]:[0-5][0-9]$ ]] || { echo "Times must be HH:MM" >&2; exit 1; }
fi

confirm "About to add helper '$NAME' <$EMAIL>${DAY_LIST:+ with availability days $DAY_LIST $START–$END}."

psql "$DIRECT_URL" -v ON_ERROR_STOP=1 -q \
  -v name="$NAME" -v email="$EMAIL" -v days="$DAY_LIST" -v start_t="$START" -v end_t="$END" <<'SQL'
BEGIN;
INSERT INTO public.helpers (name, email, user_id)
VALUES (:'name', lower(:'email'), (SELECT id FROM auth.users WHERE lower(email) = lower(:'email') LIMIT 1))
ON CONFLICT (lower(email)) DO UPDATE
  SET name = EXCLUDED.name, user_id = coalesce(EXCLUDED.user_id, public.helpers.user_id), active = true;

INSERT INTO public.helper_availability (helper_id, day_of_week, start_time, end_time)
SELECT h.id, d::smallint, nullif(:'start_t', '')::time, nullif(:'end_t', '')::time
FROM public.helpers h, unnest(string_to_array(nullif(:'days', ''), ',')) d
WHERE lower(h.email) = lower(:'email')
  AND NOT EXISTS (
    SELECT 1 FROM public.helper_availability x
    WHERE x.helper_id = h.id AND x.day_of_week = d::smallint
      AND x.start_time = nullif(:'start_t', '')::time AND x.end_time = nullif(:'end_t', '')::time
  );
COMMIT;

\pset footer off
SELECT h.name, h.email, h.user_id IS NOT NULL AS has_login, a.day_of_week, a.start_time, a.end_time, a.timezone
FROM public.helpers h LEFT JOIN public.helper_availability a ON a.helper_id = h.id
WHERE lower(h.email) = lower(:'email')
ORDER BY a.day_of_week, a.start_time;
SQL
