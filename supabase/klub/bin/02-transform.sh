#!/usr/bin/env bash
# Wrapper around 02-transform.py: builds the identity map, rewrites the
# export JSON files, and generates the sync SQL. Run 01-fetch-target-profiles.sh
# first (it needs a fresh _target-profiles.json).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./00-config.sh

if [ ! -f "$EXPORT_DIR/_target-profiles.json" ]; then
  echo "Missing $EXPORT_DIR/_target-profiles.json — run 01-fetch-target-profiles.sh first." >&2
  exit 1
fi

python3 ./02-transform.py
