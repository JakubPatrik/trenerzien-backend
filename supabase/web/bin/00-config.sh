#!/usr/bin/env bash
# Shared config, sourced by every 0N-*.sh script. Do not run directly.
# Targets the SAME project as supabase/vyzva (trenerzien-backend/.env) —
# consultation_applications has no auth/user dependency, so it lives in the
# same database as the membership tables.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WEB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BACKEND_DIR="$(cd "$WEB_DIR/../.." && pwd)"
MIGRATIONS_DIR="$WEB_DIR/migrations"

if [ ! -f "$BACKEND_DIR/.env" ]; then
  echo "Missing $BACKEND_DIR/.env" >&2
  exit 1
fi

# .env values are wrapped in double quotes (KEY="value") — strip them.
env_var() {
  grep "^$1=" "$BACKEND_DIR/.env" | cut -d= -f2- | sed -E 's/^[[:space:]]*"?//; s/"?[[:space:]]*$//'
}
DIRECT_URL="$(env_var DIRECT_URL)"

if [ -z "$DIRECT_URL" ]; then
  echo "Failed to read DIRECT_URL from $BACKEND_DIR/.env" >&2
  exit 1
fi

confirm() {
  echo ""
  echo "$1"
  read -r -p "Type YES to continue: " reply < /dev/tty
  if [ "$reply" != "YES" ]; then
    echo "Aborted." >&2
    exit 1
  fi
}
