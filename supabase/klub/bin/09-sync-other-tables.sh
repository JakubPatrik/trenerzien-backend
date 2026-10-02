#!/usr/bin/env bash
# Apply the generated sync SQL for every table besides profiles/user_roles/
# memberships (sql/10-*.sql onward, in the order 08-transform-other-tables.py
# wrote them — already FK-dependency-safe). Each file is ON CONFLICT-safe.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./00-config.sh

[ -f "$SQL_DIR/_other-tables-index.json" ] || { echo "Missing $SQL_DIR/_other-tables-index.json — run 08-transform-other-tables.py first." >&2; exit 1; }

echo "Tables to sync:"
jq -r '.[] | "  \(.[1]): \(.[2]) rows"' "$SQL_DIR/_other-tables-index.json"
confirm "About to write this into $NEW_URL."

while read -r fname; do
  echo "== $fname"
  psql "$DIRECT_URL" -v ON_ERROR_STOP=1 -f "$SQL_DIR/$fname"
done < <(jq -r '.[] | .[0]' "$SQL_DIR/_other-tables-index.json")

echo ""
echo "Done."
