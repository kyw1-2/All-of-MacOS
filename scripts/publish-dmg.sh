#!/usr/bin/env bash
# Local AOM development distribution. No certificate or private key leaves the Mac.
set -euo pipefail
# Oracle remote shells do not inherit the interactive Homebrew PATH.
if [ -x /opt/homebrew/bin/gh ]; then export PATH="/opt/homebrew/bin:$PATH"; fi
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO="kyw1-2/All-of-MacOS"
PB="/usr/libexec/PlistBuddy"
die() { echo "ERROR: $*" >&2; exit 1; }
for cmd in hdiutil codesign shasum; do
  command -v "$cmd" >/dev/null 2>&1 || die "Missing $cmd (macOS and GitHub CLI required)"
done
[ -x "$PB" ] || die "macOS PlistBuddy not found"

publish_one() (
  set -euo pipefail
  local dmg="$1" tmp bundle count app ident details signing version build sha short tag asset
  [ -f "$dmg" ] || die "Missing DMG: $dmg"
  [ "$(stat -f %z "$dmg")" -lt 2147483648 ] || die "DMG exceeds GitHub 2 GiB asset limit: $dmg"
  hdiutil verify "$dmg" >/dev/null || die "Damaged DMG: $dmg"
  tmp="$(mktemp -d -t aom-release)"
  mkdir -p "$tmp/mount"
  trap 'hdiutil detach -quiet "$tmp/mount" >/dev/null 2>&1 || true; rm -rf "$tmp"' EXIT
  hdiutil attach -quiet -readonly -nobrowse -noautoopen -mountpoint "$tmp/mount" "$dmg" ||
    die "Cannot mount DMG: $dmg"
  app=""
  count=0
  for bundle in "$tmp/mount"/*.app; do
    [ -d "$bundle" ] || continue
    app="$bundle"
    count=$((count + 1))
  done
  [ "$count" -eq 1 ] || die "Expected one application: $dmg"
  ident="$("$PB" -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")"
  [ "$ident" = "com.kyw.allofmacos" ] || die "Refusing unrelated app: $dmg"
  codesign --verify --deep --strict "$app" || die "Bad code signature: $dmg"
  details="$(codesign -dv --verbose=2 "$app" 2>&1)"
  if printf '%s\n' "$details" | grep -Fx 'Authority=AOM Dev' >/dev/null; then
    signing="AOM Dev self-signed"
  elif printf '%s\n' "$details" | grep -Fx 'Signature=adhoc' >/dev/null; then
    signing="ad-hoc"
  else
    echo "SKIPPED: Historical DMG has a different signing identity: $dmg" >&2
    exit 10
  fi
  helper="$app/Contents/XPCServices/ScriptRunner.xpc"
  [ -d "$helper" ] || die "Missing XPC helper: $dmg"
  if [ "$signing" = "AOM Dev self-signed" ]; then
    codesign -dv --verbose=2 "$helper" 2>&1 | grep -Fx 'Authority=AOM Dev' >/dev/null ||
      die "XPC helper has wrong signing identity: $dmg"
  else
    codesign -dv --verbose=2 "$helper" 2>&1 | grep -Fx 'Signature=adhoc' >/dev/null ||
      die "Ad-hoc DMG has an inconsistent XPC helper: $dmg"
  fi
  version="$("$PB" -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
  build="$("$PB" -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")"
  # Version 1.0.1 was intentionally retired; never recreate its release.
  if [ "$version" = "1.0.1" ]; then
    echo "SKIPPED: 1.0.1 is retired and excluded from GitHub releases" >&2
    exit 10
  fi
  for value in "$version" "$build"; do
    printf '%s\n' "$value" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]*$' ||
      die "Invalid version or build number: $dmg"
  done
  sha="$(shasum -a 256 "$dmg" | awk '{print $1}')"
  short="$(printf '%s' "$sha" | cut -c1-12)"
  tag="aom-dev-v$version-b$build-$short"
  asset="$(basename "$dmg")"
  cat > "$tmp/notes.md" <<EOF
All of MacOS development build; NOT Apple-notarized.

- App version: $version ($build)
- Code signing: $signing
- DMG SHA-256: $sha
- Artifact is from a local build or historic archive; tag does not establish reproducible source provenance.
- Intended for private testing. Keep macOS Gatekeeper enabled.
EOF
  command -v gh >/dev/null 2>&1 || die "Install gh to publish; DMG remains local"
  gh auth status -h github.com >/dev/null 2>&1 || die "Authenticate gh to publish; DMG remains local"
  if ! gh release view "$tag" --repo "$REPO" >/dev/null 2>&1; then
    if [ "$mode" = "--from-build" ]; then
      # Only a successful fresh local AOM Dev build becomes Latest.
      gh release create "$tag" --repo "$REPO" \
        --title "All of MacOS $version ($build) - $signing" \
        --latest --notes-file "$tmp/notes.md"
    else
      gh release create "$tag" --repo "$REPO" \
        --title "All of MacOS $version ($build) - $signing" \
        --prerelease --latest=false --notes-file "$tmp/notes.md"
    fi
  fi
  if gh release view "$tag" --repo "$REPO" --json assets --jq '.assets[].name' |
    grep -Fx "$asset" >/dev/null; then
    echo "Already published: $tag / $asset"
  else
    gh release upload "$tag" "$dmg" --repo "$REPO"
    echo "Published: $tag / $asset"
  fi
  if [ "$mode" = "--from-build" ]; then
    # Preserve Latest even when a matching release already existed.
    gh release edit "$tag" --repo "$REPO" --prerelease=false --latest >/dev/null
  fi
)

mode="--from-build"
if [ "$#" -gt 0 ]; then mode="$1"; fi
case "$mode" in
  --from-build)
    app="$ROOT/build/All of MacOS.app"
    [ -d "$app" ] || die "Build the application first"
    [ "$("$PB" -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")" = "com.kyw.allofmacos" ] ||
      die "Unexpected app bundle"
    codesign --verify --deep --strict "$app" || die "App failed signature verification"
    codesign -dv --verbose=2 "$app" 2>&1 | grep -Fx 'Authority=AOM Dev' >/dev/null ||
      die "AOM Dev signature required; CI ad-hoc builds cannot use this channel"
    version="$("$PB" -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
    build="$("$PB" -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")"
    stamp="$(date -u +%Y%m%dT%H%M%SZ)"
    mkdir -p "$ROOT/build/releases"
    dmg="$ROOT/build/releases/All-of-MacOS-$version-b$build-$stamp-$$-AOM-Dev.dmg"
    [ ! -e "$dmg" ] || die "Existing output: $dmg"
    hdiutil create -quiet -volname "All of MacOS $version" \
      -srcfolder "$app" -format UDZO "$dmg"
    publish_one "$dmg"
    ;;
  --import-existing)
    found=0
    skipped=0
    failed=0
    for root in "$HOME/Downloads" "$HOME/Desktop" "$HOME/Documents" "$ROOT/build"; do
      [ -d "$root" ] || continue
      while IFS= read -r -d '' dmg; do
        found=$((found + 1))
        if publish_one "$dmg"; then
          :
        else
          result=$?
          if [ "$result" -eq 10 ]; then
            skipped=$((skipped + 1))
          else
            failed=$((failed + 1))
            echo "WARNING: Invalid or unpublished AOM DMG: $dmg" >&2
          fi
        fi
      done < <(find "$root" -maxdepth 4 -type f \( \
        -iname 'All-of-MacOS*.dmg' -o -iname 'All of MacOS*.dmg' -o -iname 'AOM*.dmg' \
      \) -print0)
    done
    printf 'Historical DMGs examined: %s, skipped other identities: %s, failed: %s\n' "$found" "$skipped" "$failed"
    [ "$failed" -eq 0 ]
    ;;
  --file)
    [ "$#" -eq 2 ] || die "Usage: $0 --file PATH_TO_DMG"
    publish_one "$2"
    ;;
  *)
    die "Usage: $0 [--from-build|--import-existing|--file PATH]"
    ;;
esac
