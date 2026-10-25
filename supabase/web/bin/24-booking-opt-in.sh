#!/usr/bin/env bash
# Double opt-in before the meeting invitation (BOOKING_OPT_IN.md).
#
#   ./24-booking-opt-in.sh            install, flag stays as it is (off on first run):
#                                       1. 12.sql (holds, claim, reissue, RLS)
#                                       2. BOOKING_HOLDS_SECRET: the one in Vault, else a new one
#                                       3. deploy book-meeting, confirm-meeting, booking-holds, cancel-meeting
#                                       4. Vault: booking-holds URL + secret, 13.sql (cron every 5 min)
#   ./24-booking-opt-in.sh on         BOOKING_DOUBLE_OPT_IN=true  (after the website is live)
#   ./24-booking-opt-in.sh off        BOOKING_DOUBLE_OPT_IN=false (back to direct booking)
#   ./24-booking-opt-in.sh status     flag, holds, cron runs
# Re-runnable.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./00-config.sh

SUPABASE_URL="$(env_var SUPABASE_URL)"
REF="$(echo "$SUPABASE_URL" | sed -E 's#^https?://([^.]+)\..*#\1#')"
if [ -z "$REF" ] || [ "$REF" = "$SUPABASE_URL" ]; then
  echo "Could not derive project ref from SUPABASE_URL=$SUPABASE_URL" >&2
  exit 1
fi
FN_URL="https://$REF.supabase.co/functions/v1/booking-holds"

status() {
  echo "Flag:"
  supabase secrets list --project-ref "$REF" | grep -E 'BOOKING_DOUBLE_OPT_IN|BOOKING_HOLDS_SECRET|BOOKING_SITE_URL' || echo "  BOOKING_DOUBLE_OPT_IN not set (= off)"
  echo ""
  psql "$DIRECT_URL" -c "
    select a.status, a.cancel_reason, count(*), max(a.created_at) as last
    from public.appointments a where a.opt_in_token is not null
    group by 1, 2 order by 1, 2;"
  psql "$DIRECT_URL" -c "select jobname, schedule, active from cron.job where jobname = 'booking-holds';"
  psql "$DIRECT_URL" -c "
    select d.start_time, d.status, left(d.return_message, 80) as message
    from cron.job_run_details d join cron.job j on j.jobid = d.jobid
    where j.jobname = 'booking-holds' order by d.start_time desc limit 5;"
}

case "${1:-}" in
  on|off)
    value=$([ "$1" = on ] && echo true || echo false)
    if [ "$1" = on ]; then
      confirm "Turn ON double opt-in on $REF? Only after the website (/pohovor/potvrdenie) is live."
    else
      confirm "Turn OFF double opt-in on $REF? New bookings get the invitation right away again; existing holds still work."
    fi
    supabase secrets set --project-ref "$REF" "BOOKING_DOUBLE_OPT_IN=$value"
    echo "BOOKING_DOUBLE_OPT_IN=$value (applies to new function invocations, no redeploy needed)."
    exit 0
    ;;
  status)
    status
    exit 0
    ;;
  "") ;;
  *)
    sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
    ;;
esac

echo "Target DB:"
psql "$DIRECT_URL" -c "select current_database(), inet_server_addr();"

confirm "About to apply 12.sql + 13.sql and deploy book-meeting, confirm-meeting, booking-holds, cancel-meeting to $REF (the flag is not changed)."

psql "$DIRECT_URL" -v ON_ERROR_STOP=1 --single-transaction -f "$MIGRATIONS_DIR/12.sql"

vault_secret() {
  psql "$DIRECT_URL" -Atc "select decrypted_secret from vault.decrypted_secrets where name = 'booking_holds_secret'"
}
secret="$(vault_secret 2>/dev/null || true)"
[ -n "$secret" ] || secret="$(openssl rand -hex 32)"

# The CLI looks for ./supabase/functions/<name>, so run from trenerzien-backend/.
cd "$BACKEND_DIR"
supabase secrets set --project-ref "$REF" "BOOKING_HOLDS_SECRET=$secret"
for fn in book-meeting confirm-meeting booking-holds cancel-meeting; do
  supabase functions deploy "$fn" --project-ref "$REF" --no-verify-jwt --use-api
done

psql "$DIRECT_URL" -v ON_ERROR_STOP=1 -q -v url="$FN_URL" -v secret="$secret" <<'SQL'
SELECT vault.update_secret(id, :'url') FROM vault.secrets WHERE name = 'booking_holds_url';
SELECT vault.create_secret(:'url', 'booking_holds_url')
WHERE NOT EXISTS (SELECT 1 FROM vault.secrets WHERE name = 'booking_holds_url');
SELECT vault.update_secret(id, :'secret') FROM vault.secrets WHERE name = 'booking_holds_secret';
SELECT vault.create_secret(:'secret', 'booking_holds_secret')
WHERE NOT EXISTS (SELECT 1 FROM vault.secrets WHERE name = 'booking_holds_secret');
SQL

psql "$DIRECT_URL" -v ON_ERROR_STOP=1 --single-transaction -f "$MIGRATIONS_DIR/13.sql"

echo ""
echo "Smoke tests:"
printf '  confirm-meeting, unknown token → '
curl -sS -X POST "https://$REF.supabase.co/functions/v1/confirm-meeting" -H "Content-Type: application/json" \
  -d "{\"token\":\"$(openssl rand -hex 32)\"}"
echo ""
printf '  booking-holds tick → '
curl -sS -X POST "$FN_URL" -H "Authorization: Bearer $secret" -H "Content-Type: application/json" -d '{"action":"tick"}'
echo ""
echo ""
status
echo ""
echo "Next: the website ships /pohovor/potvrdenie + /pohovor/dakujem?t=, then: $0 on"
