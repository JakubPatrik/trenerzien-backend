#!/usr/bin/env bash
# Set the booking secrets on the vyzva project from environment variables.
# Only variables that are set are pushed, so run it again for later additions
# (e.g. SmartEmailing once you have the credentials).
#
#   GOOGLE_CLIENT_ID=… GOOGLE_CLIENT_SECRET=… GOOGLE_REFRESH_TOKEN=… \
#   BOOKING_ALLOWED_ORIGINS=https://trenerzien.sk,https://www.trenerzien.sk \
#   ./12-set-booking-secrets.sh
#
# Google:         GOOGLE_CLIENT_ID, GOOGLE_CLIENT_SECRET, GOOGLE_REFRESH_TOKEN,
#                 GOOGLE_CALENDAR_ID (optional, default "primary")
# Browser access: BOOKING_ALLOWED_ORIGINS (comma-separated; unset = any origin)
# SmartEmailing:  SMARTEMAILING_USERNAME, SMARTEMAILING_API_KEY,
#                 SMARTEMAILING_SENDER_EMAIL, SMARTEMAILING_SENDER_NAME,
#                 SMARTEMAILING_REPLY_TO (sender + reply-to must be confirmed in SmartEmailing)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./00-config.sh

NAMES=(
  GOOGLE_CLIENT_ID GOOGLE_CLIENT_SECRET GOOGLE_REFRESH_TOKEN GOOGLE_CALENDAR_ID
  BOOKING_ALLOWED_ORIGINS
  SMARTEMAILING_USERNAME SMARTEMAILING_API_KEY SMARTEMAILING_SENDER_EMAIL
  SMARTEMAILING_SENDER_NAME SMARTEMAILING_REPLY_TO
)

ARGS=()
for n in "${NAMES[@]}"; do
  if [ -n "${!n:-}" ]; then ARGS+=("$n=${!n}"); fi
done
if [ ${#ARGS[@]} -eq 0 ]; then
  sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'
  exit 1
fi

SUPABASE_URL="$(env_var SUPABASE_URL)"
REF="$(echo "$SUPABASE_URL" | sed -E 's#^https?://([^.]+)\..*#\1#')"

echo "Will set on project $REF:"
for a in "${ARGS[@]}"; do echo "  ${a%%=*}"; done
confirm "About to set ${#ARGS[@]} secret(s)."

supabase secrets set --project-ref "$REF" "${ARGS[@]}"
