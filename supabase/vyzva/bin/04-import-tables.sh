#!/usr/bin/env bash
# Step 4: import profiles -> user_roles -> memberships into the NEW project.
# profiles/user_roles are upserted (the auth trigger from step 3 already
# created stub rows); memberships is inserted with original ids so a re-run
# after a partial failure is safe (duplicates are rejected, not duplicated).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./00-config.sh

for t in profiles user_roles memberships; do
  [ -f "$EXPORT_DIR/$t.json" ] || { echo "Missing $EXPORT_DIR/$t.json — run 02-export-source.sh first." >&2; exit 1; }
done

echo "Row counts to import:"
for t in profiles user_roles memberships; do
  echo "  $t: $(jq length "$EXPORT_DIR/$t.json")"
done
confirm "About to write this into $NEW_URL."

echo ""
echo "Importing profiles (upsert on id)..."
curl -s -X POST "$NEW_URL/rest/v1/profiles?on_conflict=id" \
  -H "apikey: $NEW_SERVICE_KEY" -H "Authorization: Bearer $NEW_SERVICE_KEY" \
  -H "Content-Type: application/json" -H "Prefer: resolution=merge-duplicates" \
  --data-binary @"$EXPORT_DIR/profiles.json" -o /dev/null -w "HTTP %{http_code}\n"

echo "Importing user_roles (upsert on user_id,role, ignore duplicates)..."
curl -s -X POST "$NEW_URL/rest/v1/user_roles?on_conflict=user_id,role" \
  -H "apikey: $NEW_SERVICE_KEY" -H "Authorization: Bearer $NEW_SERVICE_KEY" \
  -H "Content-Type: application/json" -H "Prefer: resolution=ignore-duplicates" \
  --data-binary @"$EXPORT_DIR/user_roles.json" -o /dev/null -w "HTTP %{http_code}\n"

echo "Importing memberships (batches of 500, on_conflict=id so re-runs are safe)..."
MEMBERSHIPS="$EXPORT_DIR/memberships.json"
TOTAL="$(jq length "$MEMBERSHIPS")"
BATCH=500
off=0
while [ "$off" -lt "$TOTAL" ]; do
  jq -c ".[$off:$((off+BATCH))]" "$MEMBERSHIPS" > /tmp/memberships-batch.json
  code="$(curl -s -X POST "$NEW_URL/rest/v1/memberships?on_conflict=id" \
    -H "apikey: $NEW_SERVICE_KEY" -H "Authorization: Bearer $NEW_SERVICE_KEY" \
    -H "Content-Type: application/json" -H "Prefer: resolution=merge-duplicates" \
    --data-binary @/tmp/memberships-batch.json -o /dev/null -w '%{http_code}')"
  echo "  rows $off-$((off+BATCH)): HTTP $code"
  off=$((off+BATCH))
done
rm -f /tmp/memberships-batch.json

echo ""
echo "Import done. Run 05-validate.sh next."
