#!/usr/bin/env bash
# Apply the web schema (0.sql: consultation_applications table + RLS) and the
# static seed data (1.sql, generated once from supabase/web/export/*.json —
# no live Supabase export needed, the data is frozen) to the vyzva project.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./00-config.sh

echo "Target DB:"
psql "$DIRECT_URL" -c "select current_database(), inet_server_addr();"

confirm "About to create public.consultation_applications and insert its 3 seed rows into the DB above."

for f in "$MIGRATIONS_DIR"/{0,1}.sql; do
  echo "== $f"
  psql "$DIRECT_URL" -v ON_ERROR_STOP=1 -f "$f"
done

echo ""
echo "Done. Run 02-validate.sh to check."
