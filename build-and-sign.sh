#!/bin/bash
# Build All of MacOS from the independent SwiftPM snapshot and sign with the local user development identity.
# Preserve the certificate and bundle identifier in the designated requirement
# so TCC can recognize updates. The CDHash changes with every changed binary.
set -euo pipefail
cd "$(dirname "$0")"

# SwiftUI macros (@State, @Preview) ship only in the Xcode toolchain; the
# Command Line Tools toolchain has no libSwiftUIMacros, so a CLT-selected
# environment fails to compile the Views layer. Prefer Xcode when it is
# installed, without overriding a DEVELOPER_DIR the caller already chose.
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

# Stable local self-signed Code Signing certificate, created in Keychain Access.
# CI passes ALLOFMACOS_SIGN_ID=- for an ad-hoc, non-distributable test build.
SIGN_ID="${ALLOFMACOS_SIGN_ID:-AOM Dev}"
if [ "$SIGN_ID" != "AOM Dev" ] && [ "$SIGN_ID" != "-" ]; then
    echo "ERROR: Expected AOM Dev (local) or - (CI test only)." >&2
    exit 1
fi
APP="build/All of MacOS.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
BINARY_NAME="AllOfMacOS"

echo "==> swift build (release; limited parallelism)"
swift build -c release -j "${ALLOFMACOS_BUILD_JOBS:-2}"

BIN="$(swift build -c release --show-bin-path)/AllOfMacOS"
echo "==> Assembling app bundle at $APP"
rm -rf "$APP"
mkdir -p "$MACOS"
cp "$BIN" "$MACOS/$BINARY_NAME"
cp AllOfMacOS/App/Info.plist "$CONTENTS/Info.plist"
# SwiftPM excludes asset catalogs. Package the same complete icon set used by Xcode.
ICON_SET="$PWD/AllOfMacOS/Assets.xcassets/AppIcon.appiconset"
ICON_WORK="$(mktemp -d)"
trap 'rm -rf "$ICON_WORK"' EXIT
mkdir -p "$ICON_WORK/AppIcon.iconset" "$CONTENTS/Resources"
cp "$ICON_SET"/icon_*.png "$ICON_WORK/AppIcon.iconset/"
iconutil -c icns "$ICON_WORK/AppIcon.iconset" -o "$CONTENTS/Resources/AppIcon.icns"
/usr/libexec/PlistBuddy -c "Set :CFBundleIconFile AppIcon" "$CONTENTS/Info.plist"

"$PWD/XPC/build-runner.sh" "$CONTENTS" "$SIGN_ID"

echo "==> Codesigning with '$SIGN_ID'"
codesign --force --sign "$SIGN_ID" \
    --entitlements AllOfMacOS/AllOfMacOS.entitlements \
    "$APP"

echo "==> Verifying"
codesign -dv --verbose=2 "$APP" 2>&1 | grep -E "Identifier|TeamIdentifier|Authority" || true
codesign --verify --deep --strict "$APP" 2>&1

echo "==> Done: $APP"
echo "    Install separately to avoid overwriting an existing application"
