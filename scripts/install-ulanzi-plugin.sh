#!/bin/bash
set -euo pipefail
APP="/Applications/All of MacOS.app"
if [ "$#" -gt 0 ]; then APP="$1"; fi
SRC="$APP/Contents/Resources/Ulanzi/com.ulanzi.aom.ulanziPlugin"
DST="$HOME/Library/Application Support/Ulanzi/UlanziDeck/Plugins/com.ulanzi.aom.ulanziPlugin"
test -f "$SRC/manifest.json" && test -f "$SRC/plugin/app.html" || { echo "Bundled Ulanzi plugin missing" >&2; exit 1; }
if [ -e "$DST" ]; then
    if cmp -s "$SRC/manifest.json" "$DST/manifest.json"; then echo "Already installed: $DST"; exit 0; fi
    echo "Existing Ulanzi plugin differs; refusing overwrite: $DST" >&2
    exit 2
fi
mkdir -p "$(dirname "$DST")"
ditto "$SRC" "$DST"
echo "Ulanzi Deck plugin installed in: $DST"
echo "Restart Ulanzi Studio and assign AOM Key actions."
