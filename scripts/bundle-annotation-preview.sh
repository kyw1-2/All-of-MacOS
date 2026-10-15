#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
contents="$1"
sign_identity="${2:-AOM Dev}"
preview="$contents/PlugIns/AOMAnnotationPreview.appex/Contents"
mkdir -p "$preview/MacOS"
xcrun swiftc -O -emit-library -parse-as-library -application-extension \
  -module-name AOMAnnotationPreview -target "$(uname -m)-apple-macosx14.0" \
  "$root/Extensions/AnnotationPreview/PreviewViewController.swift" \
  "$root/AllOfMacOS/Models/AnnotationDocument.swift" \
  "$root/AllOfMacOS/Services/AnnotationProject.swift" \
  -framework Quartz -o "$preview/MacOS/AOMAnnotationPreview"
cp "$root/Extensions/AnnotationPreview/Info.plist" "$preview/Info.plist"
codesign --force --sign "$sign_identity" --entitlements "$root/Extensions/AnnotationPreview/Preview.entitlements" "$preview/.."
