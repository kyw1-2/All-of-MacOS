#!/usr/bin/env bash
# Exercises actual platform-independent helpers. This is NOT the macOS app suite.
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/Sources/AllOfMacOS" "$fixture/Tests/AllOfMacOSTests"
for file in BoundedLRUCache BoundedFileData FileWatcherPolling; do
  cp "$repo/AllOfMacOS/Services/$file.swift" "$fixture/Sources/AllOfMacOS/"
done
cp "$repo/AllOfMacOSTests/ResourceEfficiencyTests.swift" "$fixture/Tests/AllOfMacOSTests/"
cat > "$fixture/Package.swift" <<'SWIFT'
// swift-tools-version:5.9
import PackageDescription
let package = Package(name: "AOMResourcePolicies", targets: [
    .target(name: "AllOfMacOS"),
    .testTarget(name: "AllOfMacOSTests", dependencies: ["AllOfMacOS"])
])
SWIFT
swift test --package-path "$fixture" -j 2
