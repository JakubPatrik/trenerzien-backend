#!/usr/bin/env bash
# Read-only: prints the current auth.users count in the NEW project.
# Run this in a SEPARATE terminal tab while 03-import-users.sh is running,
# via: watch -n 2 ./watch-progress.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./00-config.sh
psql "$DIRECT_URL" -t -c "select count(*) || ' / 3211 users created' from auth.users;"
