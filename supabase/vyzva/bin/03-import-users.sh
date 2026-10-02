#!/usr/bin/env bash
# Step 3: create auth users in the NEW project, preserving the original `id`
# (UUID) from the source so profiles/user_roles/memberships FKs resolve.
# Regular users get no password (they'll reset via invite email). Admin
# accounts (detected from user_roles.json role=admin) get a temp password
# you type in now.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./00-config.sh

PROFILES="$EXPORT_DIR/profiles.json"
ROLES="$EXPORT_DIR/user_roles.json"
[ -f "$PROFILES" ] || { echo "Missing $PROFILES — run 02-export-source.sh first." >&2; exit 1; }
[ -f "$ROLES" ] || { echo "Missing $ROLES — run 02-export-source.sh first." >&2; exit 1; }

TOTAL="$(jq length "$PROFILES")"
ADMIN_IDS="$(jq -r '[.[] | select(.role=="admin") | .user_id]' "$ROLES")"
ADMIN_COUNT="$(echo "$ADMIN_IDS" | jq length)"

echo "This will create $TOTAL users in the NEW project ($NEW_URL)."
echo "$ADMIN_COUNT detected admin(s):"
jq -r --argjson ids "$ADMIN_IDS" '.[] | select(.id as $i | $ids | index($i)) | "  - \(.email)"' "$PROFILES"
confirm "This creates REAL auth accounts and cannot be trivially undone."

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# collect passwords for admins up front (bash 3.2 on macOS has no associative
# arrays, so stash them in a tab-separated file and look up by exact match)
ADMIN_PW_FILE="$TMP_DIR/admin_pw.tsv"
: > "$ADMIN_PW_FILE"
chmod 600 "$ADMIN_PW_FILE"
# Collected via command substitution (not a pipe/process-substitution loop),
# so nothing here competes with the loop's own stdin for the password reads.
ADMIN_EMAILS="$(jq -r --argjson ids "$ADMIN_IDS" '.[] | select(.id as $i | $ids | index($i)) | .email' "$PROFILES")"
while IFS= read -r email; do
  [ -z "$email" ] && continue
  # explicitly read from the terminal, not from any redirected stdin
  read -r -s -p "Temporary password for admin $email: " pw < /dev/tty
  echo ""
  printf '%s\t%s\n' "$email" "$pw" >> "$ADMIN_PW_FILE"
done <<< "$ADMIN_EMAILS"

FAIL_LOG="$TMP_DIR/failures.log"
: > "$FAIL_LOG"
i=0
jq -c '.[]' "$PROFILES" | while read -r row; do
  i=$((i+1))
  id="$(echo "$row" | jq -r '.id')"
  email="$(echo "$row" | jq -r '.email')"
  pw="$(awk -F'\t' -v e="$email" '$1==e{print $2; exit}' "$ADMIN_PW_FILE")"

  if [ -n "$pw" ]; then
    payload="$(jq -nc --arg id "$id" --arg email "$email" --arg pw "$pw" \
      '{id:$id, email:$email, email_confirm:true, password:$pw}')"
  else
    payload="$(jq -nc --arg id "$id" --arg email "$email" \
      '{id:$id, email:$email, email_confirm:true}')"
  fi

  resp="$(curl -s -o /dev/null -w '%{http_code}' -X POST "$NEW_URL/auth/v1/admin/users" \
    -H "apikey: $NEW_SERVICE_KEY" -H "Authorization: Bearer $NEW_SERVICE_KEY" \
    -H "Content-Type: application/json" -d "$payload")"

  if [ "$resp" != "200" ] && [ "$resp" != "201" ]; then
    echo "$email ($id): HTTP $resp" >> "$FAIL_LOG"
  fi

  if [ $((i % 100)) -eq 0 ]; then
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
echo ""
echo "Verify: select count(*) from auth.users;  -- should be close to $TOTAL"
