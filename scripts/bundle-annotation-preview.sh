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
  "$root"/AllOfMacOS/Models/Annotation*.swift \
  "$root/AllOfMacOS/Services/AnnotationProject.swift" \
  -framework Quartz -o "$preview/MacOS/AOMAnnotationPreview"
cp "$root/Extensions/AnnotationPreview/Info.plist" "$preview/Info.plist"
codesign --force --sign "$sign_identity" --entitlements "$root/Extensions/AnnotationPreview/Preview.entitlements" "$preview/.."

thumbnail="$contents/PlugIns/AOMAnnotationThumbnail.appex/Contents"
mkdir -p "$thumbnail/MacOS"
xcrun swiftc -O -emit-library -parse-as-library -application-extension \
  -module-name AOMAnnotationThumbnail -target "$(uname -m)-apple-macosx14.0" \
  "$root/Extensions/AnnotationThumbnail/ThumbnailProvider.swift" \
  "$root"/AllOfMacOS/Models/Annotation*.swift \
  "$root/AllOfMacOS/Services/AnnotationProject.swift" \
  -framework QuickLookThumbnailing -o "$thumbnail/MacOS/AOMAnnotationThumbnail"
cp "$root/Extensions/AnnotationThumbnail/Info.plist" "$thumbnail/Info.plist"
codesign --force --sign "$sign_identity" --entitlements "$root/Extensions/AnnotationThumbnail/Extension.entitlements" "$thumbnail/.."

share="$contents/PlugIns/AOMAnnotationShare.appex/Contents"
mkdir -p "$share/MacOS"
xcrun swiftc -O -emit-library -parse-as-library -application-extension \
  -module-name AOMAnnotationShare -target "$(uname -m)-apple-macosx14.0" \
  "$root/Extensions/AnnotationShare/ShareViewController.swift" \
  "$root/AllOfMacOS/Services/AOMSharedImageStaging.swift" \
  -o "$share/MacOS/AOMAnnotationShare"
cp "$root/Extensions/AnnotationShare/Info.plist" "$share/Info.plist"
codesign --force --sign "$sign_identity" --entitlements "$root/Extensions/AnnotationShare/Extension.entitlements" "$share/.."

# Keep every extension's version aligned with its containing application.
for extension in "$contents"/PlugIns/*.appex; do
  for key in CFBundleShortVersionString CFBundleVersion; do
    value=$(/usr/libexec/PlistBuddy -c "Print :$key" "$contents/Info.plist")
    /usr/libexec/PlistBuddy -c "Set :$key $value" "$extension/Contents/Info.plist"
  done
  case "$extension" in
    *AOMAnnotationPreview.appex) entitlements="$root/Extensions/AnnotationPreview/Preview.entitlements" ;;
    *AOMAnnotationThumbnail.appex) entitlements="$root/Extensions/AnnotationThumbnail/Extension.entitlements" ;;
    *AOMAnnotationShare.appex) entitlements="$root/Extensions/AnnotationShare/Extension.entitlements" ;;
    *) continue ;;
  esac
  codesign --force --sign "$sign_identity" --entitlements "$entitlements" "$extension"
done
