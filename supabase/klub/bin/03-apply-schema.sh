#!/usr/bin/env bash
# Apply the shared-schema alignment (sql/01-shared-schema.sql) to the target
# project. Safe to re-run (every change is guarded/IF NOT EXISTS).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./00-config.sh

echo "Target DB:"
psql "$DIRECT_URL" -c "select current_database(), inet_server_addr();"

confirm "About to ALTER public.profiles and public.memberships (add klub columns, add 'client' role, drop redundant plan_name) on the DB above."

psql "$DIRECT_URL" -v ON_ERROR_STOP=1 -f "$SQL_DIR/01-shared-schema.sql"

echo ""
echo "Done. Run 04-import-users.sh next."
