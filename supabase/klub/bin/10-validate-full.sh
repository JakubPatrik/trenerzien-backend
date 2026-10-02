#!/usr/bin/env bash
# Read-only: compare row counts for every klub table against the export.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./00-config.sh

echo "--- Expected (from export) vs actual (target) ---"
while read -r fname table expected; do
  actual="$(psql "$DIRECT_URL" -t -A -c "select count(*) from public.$table;" 2>/dev/null || echo 'ERR')"
  status="ok"
  [ "$actual" != "$expected" ] && status="MISMATCH"
  printf '  %-24s expected=%-6s actual=%-6s %s\n' "$table" "$expected" "$actual" "$status"
done < <(jq -r '.[] | "\(.[0]) \(.[1]) \(.[2])"' "$SQL_DIR/_other-tables-index.json")

echo ""
echo "--- odm_knowledge sanity: vector search works ---"
psql "$DIRECT_URL" -c "
select count(*) as rows_with_embedding
from public.odm_knowledge where embedding is not null;"
