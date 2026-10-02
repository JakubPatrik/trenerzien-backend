#!/usr/bin/env bash
# Deploy supabase/functions/stripe-webhook to the vyzva project.
# JWT verification is off: Stripe sends no Supabase token, the function
# verifies the Stripe signature itself. Needs `supabase login` first.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./00-config.sh

SUPABASE_URL="$(env_var SUPABASE_URL)"
REF="$(echo "$SUPABASE_URL" | sed -E 's#^https?://([^.]+)\..*#\1#')"
if [ -z "$REF" ] || [ "$REF" = "$SUPABASE_URL" ]; then
  echo "Could not derive project ref from SUPABASE_URL=$SUPABASE_URL" >&2
  exit 1
fi

confirm "About to deploy stripe-webhook to project $REF."

# The CLI looks for ./supabase/functions/<name>, so run from trenerzien-backend/.
cd "$BACKEND_DIR"
supabase functions deploy stripe-webhook \
  --project-ref "$REF" --no-verify-jwt --use-api

echo ""
echo "Stripe endpoint URLs:"
echo "  test: https://$REF.supabase.co/functions/v1/stripe-webhook?env=test"
echo "  live: https://$REF.supabase.co/functions/v1/stripe-webhook?env=live"
