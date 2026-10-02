#!/usr/bin/env bash
# Step 2: re-export current data from the Lovable Cloud (source) project.
# We have no service-role key for the source, so we authenticate as a logged-in
# admin instead — the "Admins can view all ..." RLS policies allow that admin's
# JWT to read every row via the REST API.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./00-config.sh

read -r -p "Admin email on the OLD (Lovable Cloud) project: " ADMIN_EMAIL
read -r -s -p "Admin password: " ADMIN_PASSWORD
echo ""

echo "Signing in..."
AUTH_RESPONSE="$(curl -s -X POST "$OLD_URL/auth/v1/token?grant_type=password" \
  -H "apikey: $OLD_ANON_KEY" -H "Content-Type: application/json" \
  -d "$(jq -nc --arg e "$ADMIN_EMAIL" --arg p "$ADMIN_PASSWORD" '{email:$e,password:$p}')")"
unset ADMIN_PASSWORD

ACCESS_TOKEN="$(echo "$AUTH_RESPONSE" | jq -r '.access_token // empty')"
if [ -z "$ACCESS_TOKEN" ]; then
  echo "Login failed:" >&2
  echo "$AUTH_RESPONSE" >&2
  exit 1
fi
echo "Signed in."

mkdir -p "$EXPORT_DIR"

# back up whatever export we currently have, so this run can be diffed against it
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$EXPORT_DIR/backup-$STAMP"
mkdir -p "$BACKUP_DIR"
for t in profiles user_roles memberships; do
  [ -f "$EXPORT_DIR/$t.json" ] && cp "$EXPORT_DIR/$t.json" "$BACKUP_DIR/$t.json"
done
echo "Backed up previous export to $BACKUP_DIR"

export_table() {
  local table="$1"
  local out="$EXPORT_DIR/$table.json"
  local tmp; tmp="$(mktemp -d)"
  local off=0 page=0

  echo "[]" > "$out"
  while :; do
    page=$((page+1))
    curl -s "$OLD_URL/rest/v1/$table?select=*&order=id&offset=$off&limit=1000" \
      -H "apikey: $OLD_ANON_KEY" -H "Authorization: Bearer $ACCESS_TOKEN" \
      > "$tmp/page.json"
    n="$(jq 'length' "$tmp/page.json")"
    [ "$n" = "0" ] && break
    jq -s '.[0] + .[1]' "$out" "$tmp/page.json" > "$tmp/merged.json"
    mv "$tmp/merged.json" "$out"
    off=$((off+1000))
    echo "  $table: page $page, running total $(jq length "$out")"
  done
  rm -rf "$tmp"
  echo "$table: $(jq length "$out") rows -> $out"
}

echo ""
echo "Exporting..."
export_table profiles
export_table user_roles
export_table memberships

echo ""
echo "--- Compare against previous export ---"
for t in profiles user_roles memberships; do
  old="$BACKUP_DIR/$t.json"
  new="$EXPORT_DIR/$t.json"
  [ -f "$old" ] || continue
  echo "$t: previous $(jq length "$old") -> now $(jq length "$new")"
done

echo ""
echo "Note: profiles.json already contains {id, email, ...} for every user —"
echo "that's what step 3 uses to (re)create auth users, no separate Admin API"
echo "user export is needed since we don't have the source service-role key."
