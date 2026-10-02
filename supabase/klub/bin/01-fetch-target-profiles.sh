#!/usr/bin/env bash
# Read-only: pull current {id, email} pairs from the target project's
# profiles table. Needed to figure out which of klub's 123 members already
# have an account there (same email, different id, from the vyzva import) so
# 02-transform.py can merge identities instead of creating duplicates.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./00-config.sh

OUT="$EXPORT_DIR/_target-profiles.json"
psql "$DIRECT_URL" -t -A -c "
select coalesce(json_agg(json_build_object('id', id, 'email', email)), '[]'::json)
from public.profiles;
" > "$OUT"

COUNT="$(jq length "$OUT")"
echo "Wrote $COUNT target profiles to $OUT"
