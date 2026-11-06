#!/bin/bash
# Portable tests of the production policies/codecs/recovery with fake hardware.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/Sources/AllOfMacOS" "$WORK/Tests/AllOfMacOSTests"
for SOURCE in \
    Services/PointerEngine/WheelSmoothing.swift \
    Services/SystemTools/Sensors/SMCValue.swift \
    Services/BatteryCare/BatteryCarePolicy.swift \
    Services/BatteryCare/SMCWriteSession.swift \
    Services/BatteryCare/HardwareController.swift; do
    cp "$ROOT/AllOfMacOS/$SOURCE" "$WORK/Sources/AllOfMacOS/"
done
cp "$ROOT/AllOfMacOSTests/HardwareCareTests.swift" "$ROOT/AllOfMacOSTests/HardwareControllerTests.swift" "$WORK/Tests/AllOfMacOSTests/"
cat > "$WORK/Package.swift" <<'SWIFT'
// swift-tools-version:5.9
import PackageDescription
let package = Package(name: "HardwareCore", targets: [
    .target(name: "AllOfMacOS"),
    .testTarget(name: "AllOfMacOSTests", dependencies: ["AllOfMacOS"])
])
SWIFT
swift test --package-path "$WORK" -j "${ALLOFMACOS_BUILD_JOBS:-2}"
