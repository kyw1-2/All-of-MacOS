#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONTENTS="$1"
SIGN_ID="$("$ROOT/scripts/resolve-signing-identity.sh" "${2:-${ALLOFMACOS_SIGN_ID:-AOM Dev}}")"
HELPER="$CONTENTS/XPCServices/ScriptRunner.xpc"
mkdir -p "$HELPER/Contents/MacOS"
xcrun swiftc -O -target "$(uname -m)-apple-macosx14.0" "$ROOT/AllOfMacOS/Services/ScriptRunnerClient.swift" "$ROOT/XPC/ScriptRunnerMain.swift" -o "$HELPER/Contents/MacOS/ScriptRunner"
cp "$ROOT/XPC/Info.plist" "$HELPER/Contents/Info.plist"
codesign --force --sign "$SIGN_ID" "$HELPER"
