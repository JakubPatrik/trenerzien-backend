#!/usr/bin/env bash
# Apply 2.sql (stripe_events — idempotency for the stripe-webhook function) to
# the vyzva project. Re-runnable: everything is IF NOT EXISTS / DROP IF EXISTS.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./00-config.sh

echo "Target DB:"
psql "$DIRECT_URL" -c "select current_database(), inet_server_addr();"

confirm "About to create public.stripe_events in the DB above."

f="$MIGRATIONS_DIR/2.sql"
echo "== $f"
psql "$DIRECT_URL" -v ON_ERROR_STOP=1 -f "$f"

echo ""
echo "Done. Check with: psql \"\$DIRECT_URL\" -c '\\d public.stripe_events'"
