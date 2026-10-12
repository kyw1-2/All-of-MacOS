#!/usr/bin/env bash
# Compatibility alias for the canonical historical DMG importer.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec bash "$ROOT/scripts/publish-dmg.sh" --import-existing
