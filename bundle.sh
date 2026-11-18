#!/usr/bin/env bash
# Kept for old habits and notes that still call ./bundle.sh. It used to
# assemble its own bundle at the same path as build-and-sign.sh, without the
# script runner XPC service, the AppleScript dictionary, the aomctl CLI or the
# app icon (Codex audit F10), so shell and AppleScript actions failed in that
# build. There is one assembly now: build-and-sign.sh.
set -euo pipefail
cd "$(dirname "$0")"
if [ "${1:-release}" != "release" ]; then
    echo "bundle.sh builds release only; for a debug run use 'swift run AllOfMacOS'." >&2
    exit 2
fi
exec ./build-and-sign.sh
