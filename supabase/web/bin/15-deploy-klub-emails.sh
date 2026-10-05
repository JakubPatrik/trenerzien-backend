#!/usr/bin/env bash
# Deploy the KLUB email functions to the vyzva project:
#   send-invitations  member invitations (admin)
#   notify-emails     notifications: new message, pair request, pair accepted
# JWT verification is off: both verify the caller's token themselves (and
# send-invitations must answer the browser's CORS preflight).
# Needs `supabase login` first; SMARTEMAILING_* (+ optional CLUB_PUBLIC_URL)
# secrets via 12-set-booking-secrets.sh.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./00-config.sh

SUPABASE_URL="$(env_var SUPABASE_URL)"
REF="$(echo "$SUPABASE_URL" | sed -E 's#^https?://([^.]+)\..*#\1#')"
if [ -z "$REF" ] || [ "$REF" = "$SUPABASE_URL" ]; then
  echo "Could not derive project ref from SUPABASE_URL=$SUPABASE_URL" >&2
  exit 1
fi

confirm "About to deploy send-invitations and notify-emails to project $REF."

# The CLI looks for ./supabase/functions/<name>, so run from trenerzien-backend/.
cd "$BACKEND_DIR"
for fn in send-invitations notify-emails; do
  supabase functions deploy "$fn" --project-ref "$REF" --no-verify-jwt --use-api
done

echo ""
echo "Endpoints:"
echo "  https://$REF.supabase.co/functions/v1/send-invitations"
echo "  https://$REF.supabase.co/functions/v1/notify-emails"
echo ""
echo "Secrets currently set:"
supabase secrets list --project-ref "$REF" | grep -E 'SMARTEMAILING_|CLUB_PUBLIC_URL' || echo "  (none of SMARTEMAILING_* / CLUB_PUBLIC_URL)"
