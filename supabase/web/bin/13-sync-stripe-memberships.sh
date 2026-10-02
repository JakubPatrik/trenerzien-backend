#!/usr/bin/env bash
# Sync linked memberships with their Stripe subscriptions (status, end date,
# name) using the stripe-webhook logic. Shows a dry-run report first and
# writes only after confirmation. Re-runnable; unchanged rows are skipped.
#
#   STRIPE_SECRET_KEY=rk_live_… ./13-sync-stripe-memberships.sh
#   STRIPE_SECRET_KEY=rk_live_… ./13-sync-stripe-memberships.sh --create-missing
#
# --create-missing also creates memberships for live subscriptions that have
# none (check the report: "NEW account would be created" means the Stripe
# email has no account — maybe the person signed up with a different email).
# Key needs Subscriptions + Customers: read. Uses SUPABASE_URL and
# SUPABASE_SECRET_KEY from trenerzien-backend/.env. Needs deno (or npx).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./00-config.sh

if [ -z "${STRIPE_SECRET_KEY:-}" ]; then
  echo "Set STRIPE_SECRET_KEY (e.g. STRIPE_SECRET_KEY=rk_live_… $0)" >&2
  exit 1
fi
export STRIPE_SECRET_KEY
export SUPABASE_URL="$(env_var SUPABASE_URL)"
export SUPABASE_SECRET_KEY="$(env_var SUPABASE_SECRET_KEY)"

if command -v deno >/dev/null; then DENO=(deno); else DENO=(npx -y deno@latest); fi
RUN=("${DENO[@]}" run --quiet --allow-net --allow-env --allow-read ./13-sync-stripe-memberships.ts)

"${RUN[@]}" "$@"

confirm "About to write the UPDATE list above${*:+ ($*)} to public.memberships."
"${RUN[@]}" --apply "$@"
