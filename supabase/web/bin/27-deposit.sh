#!/usr/bin/env bash
# Refundable 100 € deposit before booking a call (LOVABLE_ZALOHA.md, ZALOHA_VRATENIE.md).
#
#   ./27-deposit.sh              install, flag stays as it is (off on first run):
#                                  1. 16.sql (deposit_payment_intent_id, anon insert policy)
#                                  2. deploy book-meeting, stripe-webhook
#   ./27-deposit.sh on           BOOKING_DEPOSIT_REQUIRED=true  (after the website is live)
#   ./27-deposit.sh off          BOOKING_DEPOSIT_REQUIRED=false (booking without a deposit again)
#   ./27-deposit.sh status       flags, recent deposits
# Before the first run: Stripe setup in BOOKING.md → "Záloha".
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

status() {
  echo "Flags:"
  supabase secrets list --project-ref "$REF" | grep -E 'BOOKING_DEPOSIT_REQUIRED' \
    || echo "  not set (= deposit not required)"
  echo ""
  psql "$DIRECT_URL" -c "
    select count(*) filter (where deposit_paid) as paid,
           count(*) filter (where not deposit_paid and deposit_session_id is not null) as started_unpaid,
           max(deposit_paid_at) as last_paid
    from public.consultation_applications where created_at > now() - interval '30 days';"
}

case "${1:-}" in
  on|off)
    value=$([ "$1" = on ] && echo true || echo false)
    if [ "$1" = on ]; then
      confirm "Require the deposit on $REF? Only after the website deposit step is live."
    else
      confirm "Stop requiring the deposit on $REF? Leads can book without paying again."
    fi
    supabase secrets set --project-ref "$REF" "BOOKING_DEPOSIT_REQUIRED=$value"
    echo "BOOKING_DEPOSIT_REQUIRED=$value (applies to new function invocations, no redeploy needed)."
    exit 0
    ;;
  status)
    status
    exit 0
    ;;
  "") ;;
  *)
    sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
    ;;
esac

echo "Target DB:"
psql "$DIRECT_URL" -c "select current_database(), inet_server_addr();"

confirm "About to apply 16.sql and deploy book-meeting, stripe-webhook to $REF (the flag is not changed)."

psql "$DIRECT_URL" -v ON_ERROR_STOP=1 --single-transaction -f "$MIGRATIONS_DIR/16.sql"

# The CLI looks for ./supabase/functions/<name>, so run from trenerzien-backend/.
cd "$BACKEND_DIR"
for fn in book-meeting stripe-webhook; do
  supabase functions deploy "$fn" --project-ref "$REF" --no-verify-jwt --use-api
done

echo ""
status
echo ""
echo "Next: the website ships the deposit step (LOVABLE_ZALOHA.md), then: $0 on"
