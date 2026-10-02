#!/usr/bin/env bash
# Apply all 59 klub migration files for every table OTHER than
# profiles/user_roles/memberships (those are already fully migrated).
#
# Rather than hand-filtering which statements touch the already-migrated
# tables, this runs every file with psql's ON_ERROR_ROLLBACK mode: each
# statement gets its own savepoint, so a statement that legitimately
# conflicts (profiles/user_roles/memberships already exist in their final
# shape, the auth.users trigger already exists, etc.) is skipped without
# aborting the whole run — everything else (the other 44 tables, their
# functions/triggers/policies/indexes) applies normally.
#
# Every skipped statement is logged to $LOG so you can review it — this was
# verified clean in a rolled-back dry run first; see klub_dryrun.log review.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./00-config.sh

MIGRATIONS_DIR="$KLUB_DIR/migrations"
LOG="$(mktemp)"

echo "Target DB:"
psql "$DIRECT_URL" -c "select current_database(), inet_server_addr();"

confirm "About to apply all 59 klub migration files (minus what already exists) to the DB above."

{
  echo "\\set ON_ERROR_ROLLBACK on"
  echo "\\set ON_ERROR_STOP off"
  echo "BEGIN;"
  for f in "$MIGRATIONS_DIR"/*.sql; do
    echo "\\echo === $(basename "$f") ==="
    echo "\\i $f"
  done
  echo "COMMIT;"
} > "$LOG.sql"

psql "$DIRECT_URL" -f "$LOG.sql" > "$LOG" 2>&1
STATUS=$?

echo ""
echo "Full log: $LOG"
echo ""
echo "--- Errors (review these — expected ones mention profiles/user_roles/memberships/already exists) ---"
grep -B3 "ERROR:" "$LOG" || echo "(none)"

if [ $STATUS -ne 0 ]; then
  echo ""
  echo "psql exited non-zero ($STATUS) — check $LOG before continuing." >&2
  exit $STATUS
fi

echo ""
echo "Done. Run 09-sync-other-tables.sh next."
