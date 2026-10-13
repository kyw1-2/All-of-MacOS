#!/usr/bin/env bash
# Exercise the production timeline/cursor code on Linux or macOS without AppKit.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/Sources/AllOfMacOS" "$scratch/Tests/AllOfMacOSTests"
cp "$root/AllOfMacOS/Services/AOMStudioTimeline.swift" \
   "$root/AllOfMacOS/Services/AOMCursorTrack.swift" "$scratch/Sources/AllOfMacOS/"
cp "$root/AllOfMacOSTests/StudioTimelineTests.swift" "$scratch/Tests/AllOfMacOSTests/"
cat > "$scratch/Package.swift" <<'SWIFT'
// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "AOMStudioCore", targets: [
    .target(name: "AllOfMacOS"),
    .testTarget(name: "AllOfMacOSTests", dependencies: ["AllOfMacOS"])
])
SWIFT
"${SWIFT_EXECUTABLE:-swift}" test --package-path "$scratch" -j 2
