#!/usr/bin/env bash
# Deploy the booking edge functions (book-meeting, cancel-meeting, and the
# double opt-in ones: confirm-meeting, booking-holds) to the vyzva project.
# JWT verification is off: book-meeting is public (authorized by the
# application token), confirm-meeting by the link token, booking-holds by
# BOOKING_HOLDS_SECRET, cancel-meeting verifies the user's token itself.
# First install of double opt-in: 24-booking-opt-in.sh (migrations, secret, cron).
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

confirm "About to deploy book-meeting, cancel-meeting, confirm-meeting and booking-holds to project $REF."

# The CLI looks for ./supabase/functions/<name>, so run from trenerzien-backend/.
cd "$BACKEND_DIR"
for fn in book-meeting cancel-meeting confirm-meeting booking-holds; do
  supabase functions deploy "$fn" --project-ref "$REF" --no-verify-jwt --use-api
done

echo ""
echo "Endpoints:"
echo "  https://$REF.supabase.co/functions/v1/book-meeting"
echo "  https://$REF.supabase.co/functions/v1/cancel-meeting"
echo "  https://$REF.supabase.co/functions/v1/confirm-meeting"
echo "  https://$REF.supabase.co/functions/v1/booking-holds"
echo ""
echo "Secrets currently set:"
supabase secrets list --project-ref "$REF" | grep -E 'GOOGLE_|SMARTEMAILING_|BOOKING_' || echo "  (none of GOOGLE_* / SMARTEMAILING_* / BOOKING_*)"
