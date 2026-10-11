#!/usr/bin/env bash
set -euo pipefail

# SwiftUI macros (@State, @Preview) ship only in the Xcode toolchain; the
# Command Line Tools toolchain has no libSwiftUIMacros, so a CLT-selected
# environment fails to compile the Views layer. Prefer Xcode when it is
# installed, without overriding a DEVELOPER_DIR the caller already chose.
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

CONFIG="${1:-release}"
APP_NAME="All of MacOS"
BUNDLE_ID="com.kyw.allofmacos"
BUNDLE_DIR="build/${APP_NAME}.app"

echo "→ Building ${CONFIG}…"
swift build -c "$CONFIG" --product AllOfMacOS

BIN_PATH="$(swift build -c "$CONFIG" --product AllOfMacOS --show-bin-path)"
EXEC_PATH="$BIN_PATH/AllOfMacOS"
test -f "$EXEC_PATH" || { echo "Binary not found at $EXEC_PATH"; exit 1; }

echo "→ Assembling ${BUNDLE_DIR}…"
rm -rf "$BUNDLE_DIR"
mkdir -p "$BUNDLE_DIR/Contents/MacOS"
mkdir -p "$BUNDLE_DIR/Contents/Resources"

cp AllOfMacOS/App/Info.plist "$BUNDLE_DIR/Contents/Info.plist"
cp AllOfMacOS/AllOfMacOS.entitlements "$BUNDLE_DIR/Contents/Resources/AllOfMacOS.entitlements"
cp "$EXEC_PATH" "$BUNDLE_DIR/Contents/MacOS/AllOfMacOS"

echo "→ Signing with explicitly configured All of MacOS identity…"
SIGN_FLAG="${ALLOFMACOS_SIGN_ID:?Specify the All of MacOS signing identity; use - only for CI}"

codesign --force --deep --sign "$SIGN_FLAG" \
    --identifier "$BUNDLE_ID" \
    --entitlements "$BUNDLE_DIR/Contents/Resources/AllOfMacOS.entitlements" \
    "$BUNDLE_DIR" 2>&1 | head -5

echo "→ Done. App bundle created at $BUNDLE_DIR"
