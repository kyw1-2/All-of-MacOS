#!/usr/bin/env bash
# Only AOM Dev signed builds are distributed. No certificate/private key leaves the Mac.
set -euo pipefail
CALL_PWD="$PWD"
cd "$(dirname "$0")/.."
REPO="kyw1-2/All-of-MacOS"
WORK="$(mktemp -d "${TMPDIR:-/tmp/}aom-release.XXXXXXXX")"
MOUNTED=0
MOUNT="$WORK/mount"
cleanup() {
  if [ "$MOUNTED" -eq 1 ]; then hdiutil detach -quiet "$MOUNT" || true; fi
  rm -rf "$WORK"
}
trap cleanup EXIT

verify_app() {
  local app="$1"
  local helper="$app/Contents/XPCServices/ScriptRunner.xpc"
  test -d "$app" && test -d "$helper" || { echo "Missing app or XPC helper" >&2; return 1; }
  test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")" = "com.kyw.allofmacos" || {
    echo "Refusing unrelated application" >&2; return 1;
  }
  codesign --verify --deep --strict "$app"
  codesign -dv --verbose=2 "$app" 2>&1 | grep -Fxq "Authority=AOM Dev" || {
    echo "Application must use AOM Dev signing; ad-hoc test build rejected" >&2; return 1;
  }
  codesign -dv --verbose=2 "$helper" 2>&1 | grep -Fxq "Authority=AOM Dev" || {
    echo "XPC helper must use AOM Dev signing" >&2; return 1;
  }
  VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
  BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")"
  [[ "$VERSION" =~ ^[0-9]+(\.[0-9]+){1,3}$ ]] || { echo "Invalid version" >&2; return 1; }
  [[ "$BUILD" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "Invalid build number" >&2; return 1; }
}

test "$#" -le 1 || { echo "Usage: publish-aom-release.sh [AOM-DMG-file]" >&2; exit 2; }
MODE="build"
if [ "$#" -eq 1 ]; then
  MODE="archive"
  DMG="$1"
  case "$DMG" in /*) ;; *) DMG="$CALL_PWD/$DMG";; esac
  [[ "$DMG" == *.dmg ]] && [ -f "$DMG" ] || { echo "Expected DMG file" >&2; exit 2; }
  hdiutil verify "$DMG" >/dev/null
  mkdir -p "$MOUNT"
  hdiutil attach -quiet -readonly -nobrowse -mountpoint "$MOUNT" "$DMG"
  MOUNTED=1
  verify_app "$MOUNT/All of MacOS.app"
  hdiutil detach -quiet "$MOUNT"
  MOUNTED=0
else
  verify_app "build/All of MacOS.app"
  OUTPUT_DIR="${ALLOFMACOS_RELEASE_DIR:-$HOME/Downloads}"
  mkdir -p "$OUTPUT_DIR"
  UTC="$(date -u +%Y%m%dT%H%M%SZ)"
  ID="$(uuidgen | cut -c1-8 | tr '[:upper:]' '[:lower:]')"
  DMG="$OUTPUT_DIR/All-of-MacOS-$VERSION-b$BUILD-$UTC-$ID-AOM-Dev.dmg"
  [ ! -e "$DMG" ] || { echo "DMG already exists; not overwriting" >&2; exit 1; }
  ditto "build/All of MacOS.app" "$WORK/All of MacOS.app"
  hdiutil create -quiet -volname "All of MacOS $VERSION" -srcfolder "$WORK/All of MacOS.app" -format UDZO "$DMG"
  hdiutil verify "$DMG" >/dev/null
fi

BYTES="$(stat -f '%z' "$DMG")"
[ "$BYTES" -lt 2147483648 ] || { echo "DMG exceeds GitHub 2GiB asset limit" >&2; exit 1; }
CHECKSUM="$(shasum -a 256 "$DMG" | awk '{print $1}')"
NAME="$(basename "$DMG")"
if [ "$MODE" = "archive" ]; then
  TAG="aom-archive-v$VERSION-b$BUILD-$(printf '%s' "$CHECKSUM" | cut -c1-12)"
  TITLE="AOM $VERSION - archived AOM Dev DMG"
  SHA_FILE="$WORK/$NAME.sha256"
  SOURCE_NOTE="Historical DMG: original source revision not independently verified"
else
  TAG="aom-v$VERSION-b$BUILD-$UTC-$ID"
  TITLE="AOM $VERSION ($BUILD) - AOM Dev build"
  SHA_FILE="$DMG.sha256"
  SOURCE_NOTE="Current local build"
fi
printf '%s  %s\n' "$CHECKSUM" "$NAME" > "$SHA_FILE"
echo "Verified signed DMG: $DMG"
echo "SHA256=$CHECKSUM"

command -v gh >/dev/null || { echo "Install/authenticate gh; DMG remains local" >&2; exit 3; }
gh auth status >/dev/null 2>&1 || { echo "gh auth login required; DMG remains local" >&2; exit 3; }
REMOTE="$(git remote get-url origin 2>/dev/null || true)"
case "$REMOTE" in
  git@github.com:kyw1-2/All-of-MacOS|git@github.com:kyw1-2/All-of-MacOS.git|https://github.com/kyw1-2/All-of-MacOS|https://github.com/kyw1-2/All-of-MacOS.git) ;;
  *) echo "Wrong git origin; refusing release" >&2; exit 3;;
esac
COMMIT="$(git rev-parse HEAD)"
gh api "repos/$REPO/commits/$COMMIT" --jq '.sha' >/dev/null 2>&1 || {
  echo "Push the source commit to GitHub first; DMG remains local" >&2; exit 3;
}
if [ "$MODE" = "build" ] && { ! git diff --quiet -- || ! git diff --cached --quiet --; }; then
  SOURCE_NOTE="Local build contains uncommitted changes; tag targets $COMMIT only"
fi
cat > "$WORK/notes.md" <<EOF
Private AOM Dev development build. Self-signed locally; NOT notarized by Apple.

App: All of MacOS $VERSION ($BUILD)
Bundle ID: com.kyw.allofmacos
Signature: AOM Dev (app + XPC helper)
Source: $COMMIT
Provenance: $SOURCE_NOTE
SHA-256: $CHECKSUM

Manual macOS Gatekeeper approval may be necessary.
EOF
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  if gh release view "$TAG" --repo "$REPO" --json assets --jq '.assets[].name' | grep -Fxq "$NAME"; then
    echo "Already released: $TAG"
    exit 0
  fi
  gh release upload "$TAG" "$DMG" "$SHA_FILE" --repo "$REPO"
else
  gh release create "$TAG" "$DMG" "$SHA_FILE" --repo "$REPO" \
    --target "$COMMIT" --title "$TITLE" --notes-file "$WORK/notes.md" --prerelease
fi
echo "PUBLISHED_TAG=$TAG"
