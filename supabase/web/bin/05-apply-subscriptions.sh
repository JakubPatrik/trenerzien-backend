#!/usr/bin/env bash
# Apply 3.sql (memberships.stripe_* columns + is_club_member() membership names
# for the stripe-webhook function) to the vyzva project.
# Re-runnable: IF NOT EXISTS / CREATE OR REPLACE.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./00-config.sh

echo "Target DB:"
psql "$DIRECT_URL" -c "select current_database(), inet_server_addr();"

confirm "About to add memberships.stripe_* columns and update is_club_member() in the DB above."

f="$MIGRATIONS_DIR/3.sql"
echo "== $f"
psql "$DIRECT_URL" -v ON_ERROR_STOP=1 -f "$f"

echo ""
echo "Done. Check with: psql \"\$DIRECT_URL\" -c '\\d public.memberships'"
