#!/usr/bin/env bash
# Create auth users (no password — reset via invite link, same as vyzva) for
# every klub profile. profiles.json already carries id+email for all 123
# rows (both new and identity-merged) — no separate "new users" file needed:
# the 37 already-merged rows just get a harmless "already exists" from the
# Admin API and are logged in FAIL_LOG, same as vyzva's duplicate handling.
# Both klub admins are among those 37, so nothing admin-specific is needed here.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./00-config.sh

PROFILES="$EXPORT_DIR/profiles.json"
[ -f "$PROFILES" ] || { echo "Missing $PROFILES — run 02-transform.sh first." >&2; exit 1; }

TOTAL="$(jq length "$PROFILES")"
echo "This will attempt to create $TOTAL users in the target project ($NEW_URL)."
echo "(~37 will fail as 'already exists' — that's expected, they're identity-merged.)"
confirm "This creates REAL auth accounts and cannot be trivially undone."

FAIL_LOG="$(mktemp)"
trap 'rm -f "$FAIL_LOG"' EXIT
i=0
jq -c '.[] | {id, email}' "$PROFILES" | while read -r row; do
  i=$((i+1))
  id="$(echo "$row" | jq -r '.id')"
  email="$(echo "$row" | jq -r '.email')"
  payload="$(jq -nc --arg id "$id" --arg email "$email" '{id:$id, email:$email, email_confirm:true}')"

  resp="$(curl -s -o /dev/null -w '%{http_code}' -X POST "$NEW_URL/auth/v1/admin/users" \
    -H "apikey: $NEW_SERVICE_KEY" -H "Authorization: Bearer $NEW_SERVICE_KEY" \
    -H "Content-Type: application/json" -d "$payload")"

  if [ "$resp" != "200" ] && [ "$resp" != "201" ]; then
    echo "$email ($id): HTTP $resp" >> "$FAIL_LOG"
  fi
  if [ $((i % 25)) -eq 0 ]; then
    echo "  $i / $TOTAL"
  fi
done

echo ""
if [ -s "$FAIL_LOG" ]; then
  echo "Done with failures (often duplicates if re-run — safe to ignore those):"
  cat "$FAIL_LOG"
else
  echo "Done, no failures."
fi
