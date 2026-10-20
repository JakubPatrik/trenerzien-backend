#!/usr/bin/env bash
# Support: send the "Potvrď svoj e-mail" link again (BOOKING_OPT_IN.md, decision 11).
# Only for a hold that is still valid ('pending_opt_in'). Issues a new link (the old
# one stops working), holds the slot again for opt_in_hold_minutes from now, and
# optionally corrects the lead's email first.
#
#   ./25-resend-opt-in.sh <appointment id | lead's email as she typed it> [corrected email]
#
# Expired hold → refused; she books again on the web (or the assistant books with her).
# Needs 24-booking-opt-in.sh (booking-holds + its secret in Vault).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./00-config.sh

who="${1:?usage: $0 <appointment id | lead email> [corrected email]}"
new_email="${2:-}"

SUPABASE_URL="$(env_var SUPABASE_URL)"
REF="$(echo "$SUPABASE_URL" | sed -E 's#^https?://([^.]+)\..*#\1#')"
FN_URL="https://$REF.supabase.co/functions/v1/booking-holds"

# Latest opt-in appointment of that id / email (any status, so we can explain refusals).
row="$(psql "$DIRECT_URL" -At -F '|' -v who="$who" <<'SQL'
SELECT a.id, a.status, coalesce(a.cancel_reason, ''), c.name, c.email, coalesce(c.phone, ''),
       to_char(a.starts_at AT TIME ZONE 'Europe/Bratislava', 'DD.MM. HH24:MI'),
       coalesce(to_char(a.opt_in_expires_at AT TIME ZONE 'Europe/Bratislava', 'DD.MM. HH24:MI'), '')
FROM public.appointments a JOIN public.consultation_applications c ON c.id = a.application_id
WHERE a.opt_in_token IS NOT NULL
  AND (a.id::text = :'who' OR lower(c.email) = lower(btrim(:'who')))
ORDER BY a.created_at DESC LIMIT 1;
SQL
)"
if [ -z "$row" ]; then
  echo "No double opt-in booking for '$who'." >&2
  exit 1
fi
IFS='|' read -r id status reason name email phone starts expires <<<"$row"
echo "Booking:  $id"
echo "Lead:     $name <$email> $phone"
echo "Meeting:  $starts (Bratislava), status $status${reason:+ ($reason)}, hold until $expires"

if [ "$status" != "pending_opt_in" ]; then
  echo "Can't resend: the hold is $status${reason:+/$reason}. If it expired, she books again on the web." >&2
  exit 1
fi

secret="$(psql "$DIRECT_URL" -Atc "select decrypted_secret from vault.decrypted_secrets where name = 'booking_holds_secret'")"
[ -n "$secret" ] || { echo "No booking_holds_secret in Vault — run 24-booking-opt-in.sh first." >&2; exit 1; }

confirm "Send a new confirmation link to ${new_email:-$email}${new_email:+ (email corrected from $email)}?"

payload="$(NEW_EMAIL="$new_email" ID="$id" python3 -c '
import json, os
body = {"action": "resend", "appointment_id": os.environ["ID"]}
if os.environ["NEW_EMAIL"]: body["email"] = os.environ["NEW_EMAIL"]
print(json.dumps(body))')"
curl -sS -X POST "$FN_URL" -H "Authorization: Bearer $secret" -H "Content-Type: application/json" -d "$payload"
echo ""
