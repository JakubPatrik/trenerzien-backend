#!/usr/bin/env bash
# Deploy application-submitted to the vyzva project: after the questionnaire it
# imports the lead into SmartEmailing list 609 (no email is sent).
# JWT verification is off: the public page calls it with the application token.
# Needs `supabase login` first; uses the existing SMARTEMAILING_USERNAME /
# SMARTEMAILING_API_KEY secrets (12-set-booking-secrets.sh).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./00-config.sh

SUPABASE_URL="$(env_var SUPABASE_URL)"
REF="$(echo "$SUPABASE_URL" | sed -E 's#^https?://([^.]+)\..*#\1#')"
if [ -z "$REF" ] || [ "$REF" = "$SUPABASE_URL" ]; then
  echo "Could not derive project ref from SUPABASE_URL=$SUPABASE_URL" >&2
  exit 1
fi

confirm "About to deploy application-submitted to project $REF."

# The CLI looks for ./supabase/functions/<name>, so run from trenerzien-backend/.
cd "$BACKEND_DIR"
supabase functions deploy application-submitted --project-ref "$REF" --no-verify-jwt --use-api

echo ""
echo "Endpoint:"
echo "  https://$REF.supabase.co/functions/v1/application-submitted"
echo ""
echo "Secrets currently set:"
supabase secrets list --project-ref "$REF" | grep -E 'SMARTEMAILING_|BOOKING_ALLOWED_ORIGINS' || echo "  (none of SMARTEMAILING_* / BOOKING_ALLOWED_ORIGINS)"
