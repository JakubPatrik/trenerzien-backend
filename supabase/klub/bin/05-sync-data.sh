#!/usr/bin/env bash
# Apply the generated sync SQL: profiles -> user_roles -> memberships.
# Each file is ON CONFLICT-safe, so re-running after a partial failure
# won't duplicate or clobber existing data.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./00-config.sh

for f in 02-profiles.sql 03-user_roles.sql 04-memberships.sql; do
  [ -f "$SQL_DIR/$f" ] || { echo "Missing $SQL_DIR/$f — run 02-transform.sh first." >&2; exit 1; }
done

echo "Rows to sync:"
echo "  profiles:    $(jq length "$EXPORT_DIR/profiles.json")"
echo "  user_roles:  $(jq length "$EXPORT_DIR/user_roles.json")"
echo "  memberships: $(jq length "$EXPORT_DIR/memberships.json")"
confirm "About to write this into $NEW_URL (profiles/memberships upsert, user_roles insert-only)."

for f in 02-profiles.sql 03-user_roles.sql 04-memberships.sql; do
  echo "== $f"
  psql "$DIRECT_URL" -v ON_ERROR_STOP=1 -f "$SQL_DIR/$f"
done

echo ""
echo "Done. Run 06-validate.sh next."
