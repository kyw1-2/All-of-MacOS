#!/usr/bin/env bash
# Re-sign a copied All of MacOS.app with the independent AOM Dev identity.
# Does not overwrite any previous app bundle or DMG.
set -euo pipefail
cd "$(dirname "$0")/.."
SOURCE_APP="build/All of MacOS.app"
[ -d "$SOURCE_APP" ] || { echo "Missing app bundle" >&2; exit 1; }
/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$SOURCE_APP/Contents/Info.plist" |
    grep -qx 'com.kyw.allofmacos'

STAGE="$(mktemp -d "${TMPDIR:-/tmp/}aom-sign.XXXXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/All of MacOS.app"
ditto "$SOURCE_APP" "$APP"
codesign --force --sign "AOM Dev" "$APP/Contents/XPCServices/ScriptRunner.xpc"
codesign --force --sign "AOM Dev" \
    --entitlements AllOfMacOS/AllOfMacOS.entitlements "$APP"
codesign --verify --deep --strict "$APP"
codesign -dv --verbose=2 "$APP" 2>&1 | grep -Fx 'Authority=AOM Dev'
codesign -dv --verbose=2 "$APP/Contents/XPCServices/ScriptRunner.xpc" 2>&1 |
    grep -Fx 'Authority=AOM Dev'
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
OUTPUT="$HOME/Downloads/All-of-MacOS-${VERSION}-AOM-Dev.dmg"
[ ! -e "$OUTPUT" ] || { echo "Output already exists: $OUTPUT" >&2; exit 1; }
hdiutil create -quiet -volname "All of MacOS ${VERSION}" -srcfolder "$APP" -format UDZO "$OUTPUT"
hdiutil verify "$OUTPUT" >/dev/null
shasum -a 256 "$OUTPUT"
echo "SIGNED_DMG=$OUTPUT"
