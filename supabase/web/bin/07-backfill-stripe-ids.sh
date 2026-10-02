#!/usr/bin/env bash
# Backfill memberships.stripe_subscription_id / stripe_customer_id for the
# existing Stripe-sourced memberships (source = 'stripe'), matched by customer
# email against the subscriptions in Stripe. Run AFTER 05-apply-subscriptions.sh.
#
#   STRIPE_SECRET_KEY=rk_live_… ./07-backfill-stripe-ids.sh
#
# The key needs Subscriptions + Customers: read. Writes the report, the Stripe
# snapshot and backfill.sql to supabase/web/backfill/ (contains customer
# emails — don't commit), shows the report and applies the SQL only after
# confirmation. Re-runnable: already-linked rows/subscriptions are skipped.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./00-config.sh

if [ -z "${STRIPE_SECRET_KEY:-}" ]; then
  echo "Set STRIPE_SECRET_KEY (e.g. STRIPE_SECRET_KEY=rk_live_… $0)" >&2
  exit 1
fi

OUT_DIR="$WEB_DIR/backfill"
mkdir -p "$OUT_DIR"

echo "Target DB:"
psql "$DIRECT_URL" -c "select current_database(), inet_server_addr();"

cols="$(psql "$DIRECT_URL" -At -c "
  select count(*) from information_schema.columns
  where table_schema = 'public' and table_name = 'memberships'
    and column_name in ('stripe_subscription_id', 'stripe_customer_id');")"
if [ "$cols" != "2" ]; then
  echo "memberships.stripe_* columns are missing — run 05-apply-subscriptions.sh first." >&2
  exit 1
fi

psql "$DIRECT_URL" -At -v ON_ERROR_STOP=1 -c "
  select json_build_object(
    'rows', coalesce((
      select json_agg(json_build_object(
        'id', m.id, 'user_id', m.user_id, 'name', m.name, 'status', m.status,
        'ends_at', m.ends_at, 'email', lower(p.email)) order by p.email)
      from public.memberships m
      left join public.profiles p on p.id = m.user_id
      where m.source = 'stripe' and m.stripe_subscription_id is null), '[]'::json),
    'linked_subscription_ids', coalesce((
      select json_agg(stripe_subscription_id)
      from public.memberships where stripe_subscription_id is not null), '[]'::json)
  );" > "$OUT_DIR/memberships.json"

echo ""
echo "Fetching subscriptions from Stripe…"
python3 ./07-backfill-stripe-ids.py "$OUT_DIR/memberships.json" "$OUT_DIR"

matched="$(grep -c '^UPDATE' "$OUT_DIR/backfill.sql" || true)"
if [ "${matched:-0}" = "0" ]; then
  echo "Nothing to link."
  exit 0
fi

echo "Report: $OUT_DIR/report.txt   SQL: $OUT_DIR/backfill.sql"
confirm "About to link $matched memberships to their Stripe subscriptions in the DB above."

psql "$DIRECT_URL" -v ON_ERROR_STOP=1 -f "$OUT_DIR/backfill.sql"

echo ""
psql "$DIRECT_URL" -c "
  select name, count(stripe_subscription_id) as linked, count(*) - count(stripe_subscription_id) as unlinked
  from public.memberships where source = 'stripe' group by name order by name;"
