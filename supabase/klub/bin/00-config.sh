#!/usr/bin/env bash
# Shared config, sourced by every 0N-*.sh script. Do not run directly.
# klub syncs into the SAME target project as vyzva/web (trenerzien-backend/.env) —
# profiles/user_roles/memberships are shared tables across all three apps.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KLUB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BACKEND_DIR="$(cd "$KLUB_DIR/../.." && pwd)"
EXPORT_DIR="$KLUB_DIR/export"
SQL_DIR="$SCRIPT_DIR/sql"

if [ ! -f "$BACKEND_DIR/.env" ]; then
  echo "Missing $BACKEND_DIR/.env" >&2
  exit 1
fi

env_var() {
  grep "^$1=" "$BACKEND_DIR/.env" | cut -d= -f2- | sed -E 's/^[[:space:]]*"?//; s/"?[[:space:]]*$//'
}
NEW_URL="$(env_var SUPABASE_URL)"
NEW_SERVICE_KEY="$(env_var SUPABASE_SECRET_KEY)"
DIRECT_URL="$(env_var DIRECT_URL)"

for v in NEW_URL NEW_SERVICE_KEY DIRECT_URL; do
  if [ -z "${!v}" ]; then
    echo "Failed to read $v from $BACKEND_DIR/.env" >&2
    exit 1
  fi
done

confirm() {
  echo ""
  echo "$1"
  read -r -p "Type YES to continue: " reply < /dev/tty
  if [ "$reply" != "YES" ]; then
    echo "Aborted." >&2
    exit 1
  fi
}
