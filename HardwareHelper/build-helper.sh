#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONTENTS="${1:?Usage: build-helper.sh Contents signing-identity}"
SIGN_ID="${2:--}"
DEST="$CONTENTS/Library/HelperTools"
mkdir -p "$DEST" "$CONTENTS/Library/LaunchDaemons"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
SENSORS="$ROOT/AllOfMacOS/Services/SystemTools/Sensors"
BATTERY="$ROOT/AllOfMacOS/Services/BatteryCare"
ARCHES="${ARCHS:-$(uname -m)}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
BINARIES=()
for ARCH in $ARCHES; do
    xcrun swiftc -O -swift-version 5 -target "$ARCH-apple-macosx14.0" -sdk "$SDK" \
        "$SENSORS/SMCValue.swift" "$SENSORS/SMCTransport.swift" "$SENSORS/HardwareReader.swift" \
        "$BATTERY/BatteryCarePolicy.swift" "$BATTERY/HardwareHelperProtocol.swift" \
        "$BATTERY/SMCWriteSession.swift" "$BATTERY/HardwareController.swift" \
        "$ROOT/HardwareHelper/main.swift" -o "$WORK/$ARCH"
    BINARIES+=("$WORK/$ARCH")
done
xcrun lipo -create "${BINARIES[@]}" -output "$DEST/AOMHardwareHelper"
chmod 755 "$DEST/AOMHardwareHelper"
codesign --force --sign "$SIGN_ID" --identifier com.kyw.allofmacos.HardwareHelper "$DEST/AOMHardwareHelper"
cp "$ROOT/HardwareHelper/com.kyw.allofmacos.HardwareHelper.plist" "$CONTENTS/Library/LaunchDaemons/"
