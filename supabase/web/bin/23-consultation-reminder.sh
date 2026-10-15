#!/usr/bin/env bash
# Daily consultation reminder (11.sql + edge function consultation-reminder):
#   1. CONSULTATION_REMINDER_SECRET: the one already in Vault, else a new one
#   2. function secret, deploy
#   3. Vault: function URL + secret (read by consultation_reminder_tick())
#   4. 11.sql: pg_net, notification_prefs.email_consultations, recipients, cron job
# Re-runnable.
#
#   ./23-consultation-reminder.sh
#   ./23-consultation-reminder.sh test <email>   one reminder to <email> (today's or the next session)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./00-config.sh

SUPABASE_URL="$(env_var SUPABASE_URL)"
REF="$(echo "$SUPABASE_URL" | sed -E 's#^https?://([^.]+)\..*#\1#')"
if [ -z "$REF" ] || [ "$REF" = "$SUPABASE_URL" ]; then
  echo "Could not derive project ref from SUPABASE_URL=$SUPABASE_URL" >&2
  exit 1
fi
FN_URL="https://$REF.supabase.co/functions/v1/consultation-reminder"

vault_secret() {
  psql "$DIRECT_URL" -Atc "select decrypted_secret from vault.decrypted_secrets where name = 'consultation_reminder_secret'"
}

if [ "${1:-}" = "test" ]; then
  to="${2:?usage: $0 test <email>}"
  secret="$(vault_secret)"
  [ -n "$secret" ] || { echo "No secret in Vault yet — run $0 without arguments first." >&2; exit 1; }
  curl -sS -X POST "$FN_URL" -H "Authorization: Bearer $secret" -H "Content-Type: application/json" \
    -d "{\"test_to\":\"$to\"}"
  echo ""
  exit 0
fi

echo "Upcoming consultations:"
psql "$DIRECT_URL" -c "select held_on, starts_at at time zone 'Europe/Bratislava' as starts_local, title
                       from public.consultation_sessions where held_on >= current_date order by held_on limit 5;"

confirm "About to deploy consultation-reminder to project $REF and apply 11.sql (daily job at 8:00 Bratislava)."

secret="$(vault_secret 2>/dev/null || true)"
[ -n "$secret" ] || secret="$(openssl rand -hex 32)"

# The CLI looks for ./supabase/functions/<name>, so run from trenerzien-backend/.
cd "$BACKEND_DIR"
supabase secrets set --project-ref "$REF" "CONSULTATION_REMINDER_SECRET=$secret"
supabase functions deploy consultation-reminder --project-ref "$REF" --no-verify-jwt --use-api

psql "$DIRECT_URL" -v ON_ERROR_STOP=1 -q -v url="$FN_URL" -v secret="$secret" <<'SQL'
SELECT vault.update_secret(id, :'url') FROM vault.secrets WHERE name = 'consultation_reminder_url';
SELECT vault.create_secret(:'url', 'consultation_reminder_url')
WHERE NOT EXISTS (SELECT 1 FROM vault.secrets WHERE name = 'consultation_reminder_url');
SELECT vault.update_secret(id, :'secret') FROM vault.secrets WHERE name = 'consultation_reminder_secret';
SELECT vault.create_secret(:'secret', 'consultation_reminder_secret')
WHERE NOT EXISTS (SELECT 1 FROM vault.secrets WHERE name = 'consultation_reminder_secret');
SQL

psql "$DIRECT_URL" -v ON_ERROR_STOP=1 --single-transaction -f "$MIGRATIONS_DIR/11.sql"

echo ""
psql "$DIRECT_URL" -c "select jobname, schedule, active from cron.job where jobname = 'consultation-reminder';"
psql "$DIRECT_URL" -c "select count(*) as recipients_now from public.consultation_reminder_recipients(gen_random_uuid());"
echo "Test: $0 test <your email>"
echo "Secrets currently set:"
supabase secrets list --project-ref "$REF" | grep -E 'CONSULTATION_REMINDER_SECRET|CLUB_PUBLIC_URL' || true
