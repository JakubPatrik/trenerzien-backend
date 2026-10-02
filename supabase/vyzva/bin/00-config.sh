#!/usr/bin/env bash
# Shared config, sourced by every 0N-*.sh script. Do not run directly.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKEND_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
EXPORT_DIR="$BACKEND_DIR/supabase/export"

# --- New (target) project — loaded from trenerzien-backend/.env ---
if [ ! -f "$BACKEND_DIR/.env" ]; then
  echo "Missing $BACKEND_DIR/.env" >&2
  exit 1
fi
# .env values are wrapped in double quotes (KEY="value") — strip them, and
# any surrounding whitespace, after cutting the value out.
env_var() {
  grep "^$1=" "$BACKEND_DIR/.env" | cut -d= -f2- | sed -E 's/^[[:space:]]*"?//; s/"?[[:space:]]*$//'
}
NEW_URL="$(env_var SUPABASE_URL)"
NEW_ANON_KEY="$(env_var SUPABASE_PUBLISHABLE_KEY)"
NEW_SERVICE_KEY="$(env_var SUPABASE_SECRET_KEY)"
DIRECT_URL="$(env_var DIRECT_URL)"

for v in NEW_URL NEW_ANON_KEY NEW_SERVICE_KEY DIRECT_URL; do
  if [ -z "${!v}" ]; then
    echo "Failed to read $v from $BACKEND_DIR/.env" >&2
    exit 1
  fi
done

# --- Old (source, Lovable Cloud) project — from MIGRATION.md footer.
# This is the only credential available for the source: no service-role key,
# no DB password. Data must be pulled as a logged-in admin (RLS lets admins
# read all rows), not via the Admin API.
OLD_URL="https://krqjvrzqxhczpmgrynwz.supabase.co"
OLD_ANON_KEY="sb_publishable_Y2L7DAW4vUvrs3ufCe_zVQ_ojZIIyIY"

confirm() {
  # confirm "message" — exits unless the user types YES
  echo ""
  echo "$1"
  read -r -p "Type YES to continue: " reply
  if [ "$reply" != "YES" ]; then
    echo "Aborted." >&2
    exit 1
  fi
}
