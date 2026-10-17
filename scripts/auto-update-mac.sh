#!/bin/bash
# Local automatic updates from PRIVATE GitHub Releases; uses the owner's gh login.
# Intentionally never downloads or executes an unauthenticated URL or unpinned signer.
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
umask 077
REPO="kyw1-2/All-of-MacOS"
APP="/Applications/All of MacOS.app"
HELPER="Contents/XPCServices/ScriptRunner.xpc"
PB="/usr/libexec/PlistBuddy"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STATE="$HOME/Library/Application Support/AllOfMacOS/AutoUpdate"
mkdir -p "$STATE"
exec 9>"$STATE/update.lock"
if ! /usr/bin/lockf -t 0 9 true 2>/dev/null; then
  # flock/lockf availability varies; a mkdir lock is used below.
  :
fi
if ! mkdir "$STATE/in-progress" 2>/dev/null; then
  echo "Another update attempt is active (or stale lock)."
  exit 0
fi
trap 'rmdir "$STATE/in-progress" 2>/dev/null || true' EXIT
TMP="$(mktemp -d -t aom-autoupdate)"
STAGE="/Applications/.All-of-MacOS-update-$$.app"
MOUNT="$TMP/mount"
mounted=0
cleanup() {
  if [ "$mounted" = 1 ]; then hdiutil detach -quiet "$MOUNT" >/dev/null 2>&1 || true; fi
  if [ -d "$STAGE" ]; then rm -rf "$STAGE"; fi
  rm -rf "$TMP"
  rmdir "$STATE/in-progress" 2>/dev/null || true
}
trap cleanup EXIT
mkdir -p "$MOUNT"
mode="${1:---check}"
if [ "$mode" = "--self-test" ]; then
  command -v gh >/dev/null
  gh auth status -h github.com >/dev/null 2>&1
  test -d "$APP"
  codesign --verify --deep --strict "$APP"
  echo "SELF_TEST_OK: gh authenticated, existing app signature valid"
  exit 0
fi
[ "$mode" = "--check" ] || { echo "Usage: $0 [--check|--self-test]" >&2; exit 2; }
command -v gh >/dev/null || { echo "gh not installed; skip auto-update" >&2; exit 3; }
gh auth status -h github.com >/dev/null 2>&1 || { echo "gh login unavailable; skip auto-update" >&2; exit 3; }
test -d "$APP" || { echo "App is not installed at $APP" >&2; exit 4; }
codesign --verify --deep --strict "$APP"
gh api "repos/$REPO/releases/latest" > "$TMP/release.json"
python3 - "$TMP/release.json" "$TMP/metadata" <<'PY'
import json, re, sys
d=json.load(open(sys.argv[1]))
tag=d.get("tag_name","")
match=re.fullmatch(r"aom(?:-dev)?-v([0-9]+(?:\.[0-9]+){1,3})-b([0-9]+)-[A-Za-z0-9]+",tag)
if not match: raise SystemExit("Rejected unrecognized release tag")
assets=[a for a in d.get("assets",[]) if a.get("name","").endswith(".dmg")]
if len(assets)!=1: raise SystemExit("Expected exactly one DMG asset")
name=assets[0]["name"]; digest=assets[0].get("digest","")
if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*\.dmg",name) or ".." in name:
 raise SystemExit("Rejected asset name")
if not re.fullmatch(r"sha256:[0-9a-f]{64}",digest):
 raise SystemExit("Release is missing a verifiable GitHub SHA-256 digest")
with open(sys.argv[2],"w") as f:
 for v in (tag,match.group(1),match.group(2),name,digest.split(":",1)[1]):f.write(str(v)+"\n")
PY
{
  IFS= read -r tag
  IFS= read -r remote_version
  IFS= read -r remote_build
  IFS= read -r name
  IFS= read -r digest
} < "$TMP/metadata"
installed_version="$("$PB" -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
installed_build="$("$PB" -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
decision="$(python3 - "$installed_version" "$installed_build" "$remote_version" "$remote_build" <<'PY'
import sys
old_v,old_b,new_v,new_b=sys.argv[1:]
try:
 old=tuple(int(x) for x in old_v.split("."))
 new=tuple(int(x) for x in new_v.split("."))
 newer=(new+(0,)*(4-len(new))) > (old+(0,)*(4-len(old)))
 if new == old and old_b.isdecimal() and new_b.isdecimal():
  newer=int(new_b)>int(old_b)
 print("update" if newer else "up-to-date")
except (ValueError,TypeError): raise SystemExit("Invalid version")
PY
)"
echo "Installed $installed_version ($installed_build); latest $remote_version ($remote_build): $decision"
[ "$decision" = "update" ] || exit 0
gh release download "$tag" --repo "$REPO" --pattern "$name" --dir "$TMP" --clobber
[ "$(shasum -a 256 "$TMP/$name" | awk '{print $1}')" = "$digest" ] || { echo "DMG digest mismatch" >&2; exit 5; }
hdiutil verify "$TMP/$name" >/dev/null
hdiutil attach -quiet -readonly -nobrowse -noautoopen -mountpoint "$MOUNT" "$TMP/$name"
mounted=1
newapp="$MOUNT/All of MacOS.app"
test -d "$newapp" || { echo "No AOM bundle in DMG" >&2; exit 6; }
test "$("$PB" -c 'Print :CFBundleIdentifier' "$newapp/Contents/Info.plist")" = 'com.kyw.allofmacos'
test "$("$PB" -c 'Print :CFBundleShortVersionString' "$newapp/Contents/Info.plist")" = "$remote_version"
test "$("$PB" -c 'Print :CFBundleVersion' "$newapp/Contents/Info.plist")" = "$remote_build"
codesign --verify --deep --strict "$newapp"
test -d "$newapp/$HELPER"
codesign --verify --strict "$newapp/$HELPER"
# Compare the exact embedded leaf certificates (not just the easily duplicated CN).
signer() {
  local src="$1" out="$2"
  ( cd "$out"; codesign -d --extract-certificates "$src" >/dev/null 2>&1 )
  test -s "$out/codesign0"
  shasum -a 256 "$out/codesign0" | awk '{print $1}'
}
mkdir -p "$TMP/cert-installed" "$TMP/cert-new" "$TMP/cert-helper"
old_cert="$(signer "$APP" "$TMP/cert-installed")"
new_cert="$(signer "$newapp" "$TMP/cert-new")"
helper_cert="$(signer "$newapp/$HELPER" "$TMP/cert-helper")"
[ "$old_cert" = "$new_cert" ] && [ "$new_cert" = "$helper_cert" ] ||
  { echo "Refusing an update signed with a different identity" >&2; exit 7; }
ditto "$newapp" "$STAGE"
codesign --verify --deep --strict "$STAGE"
# Keep a roll-back copy; do not touch the current installation until validation passed.
backup="$STATE/previous-$installed_version-$installed_build.app"
if [ -e "$backup" ]; then
  backup="$STATE/previous-$installed_version-$installed_build-$(date +%s).app"
fi
# Ask running app to exit cleanly, then require it to be stopped before replacing.
osascript -e 'tell application id "com.kyw.allofmacos" to quit' >/dev/null 2>&1 || true
for attempt in 1 2 3 4 5 6 7 8 9 10; do
  if ! pgrep -f '^/Applications/All of MacOS.app/Contents/MacOS/AllOfMacOS$' >/dev/null; then break; fi
  sleep 1
done
if pgrep -f '^/Applications/All of MacOS.app/Contents/MacOS/AllOfMacOS$' >/dev/null; then
  echo "App is still running; update postponed safely" >&2
  exit 8
fi
mv "$APP" "$backup"
if ! mv "$STAGE" "$APP"; then
  mv "$backup" "$APP"
  echo "Install failed; old app restored" >&2
  exit 9
fi
if ! codesign --verify --deep --strict "$APP"; then
  mv "$APP" "$STATE/failed-$(date +%s).app"
  mv "$backup" "$APP"
  echo "Verification failed; old app restored" >&2
  exit 9
fi
open -a "$APP" || true
echo "UPDATED $installed_version ($installed_build) -> $remote_version ($remote_build)"
