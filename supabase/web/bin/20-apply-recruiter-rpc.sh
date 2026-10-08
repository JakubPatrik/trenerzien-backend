#!/usr/bin/env bash
# Apply 7.sql: RPCs add_recruiter(p_email) / remove_recruiter(p_email) — the
# same as 18-recruiter.sh add|remove, callable from the KLUB / WEB app by an
# admin (supabase.rpc('add_recruiter', { p_email })). Needs 6.sql. Re-runnable.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./00-config.sh

echo "Target DB:"
psql "$DIRECT_URL" -c "select current_database(), inet_server_addr();"

confirm "About to apply 7.sql (add_recruiter / remove_recruiter RPCs, admin only)."

psql "$DIRECT_URL" -v ON_ERROR_STOP=1 -f "$MIGRATIONS_DIR/7.sql"
echo "Done."
