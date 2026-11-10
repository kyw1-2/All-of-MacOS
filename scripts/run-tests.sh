#!/bin/bash
# Run the small core regression suite.
set -euo pipefail
cd "$(dirname "$0")/.."
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
exec swift test --scratch-path "${ALLOFMACOS_SCRATCH_PATH:-$PWD/.build}" "$@"
