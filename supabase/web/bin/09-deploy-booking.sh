#!/usr/bin/env bash
# Deploy the booking edge functions (book-meeting, cancel-meeting) to the
# vyzva project. JWT verification is off: book-meeting is public (authorized
# by the application token), cancel-meeting verifies the user's token itself.
# Needs `supabase login` first; secrets via 12-set-booking-secrets.sh.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./00-config.sh

SUPABASE_URL="$(env_var SUPABASE_URL)"
REF="$(echo "$SUPABASE_URL" | sed -E 's#^https?://([^.]+)\..*#\1#')"
if [ -z "$REF" ] || [ "$REF" = "$SUPABASE_URL" ]; then
  echo "Could not derive project ref from SUPABASE_URL=$SUPABASE_URL" >&2
  exit 1
fi

confirm "About to deploy book-meeting and cancel-meeting to project $REF."

# The CLI looks for ./supabase/functions/<name>, so run from trenerzien-backend/.
cd "$BACKEND_DIR"
for fn in book-meeting cancel-meeting; do
  supabase functions deploy "$fn" --project-ref "$REF" --no-verify-jwt --use-api
done

echo ""
echo "Endpoints:"
echo "  https://$REF.supabase.co/functions/v1/book-meeting"
echo "  https://$REF.supabase.co/functions/v1/cancel-meeting"
echo ""
echo "Secrets currently set:"
supabase secrets list --project-ref "$REF" | grep -E 'GOOGLE_|SMARTEMAILING_|BOOKING_' || echo "  (none of GOOGLE_* / SMARTEMAILING_* / BOOKING_*)"
