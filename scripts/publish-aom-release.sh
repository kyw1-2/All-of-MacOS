#!/usr/bin/env bash
# Compatibility alias: one canonical implementation lives in publish-dmg.sh.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [ "$#" -eq 0 ]; then
  exec bash "$ROOT/scripts/publish-dmg.sh" --from-build
elif [ "$#" -eq 1 ]; then
  exec bash "$ROOT/scripts/publish-dmg.sh" --file "$1"
else
  echo "Usage: bash scripts/publish-aom-release.sh [existing-DMG]" >&2
  exit 2
fi
