#!/usr/bin/env bash
# Scan and publish only verified AOM Dev disk images, without overwriting originals.
set -euo pipefail
cd "$(dirname "$0")/.."
LIST="$(mktemp "${TMPDIR:-/tmp/}aom-dmg-list.XXXXXXXX")"
trap 'rm -f "$LIST"' EXIT
for root in "$HOME/Downloads" "$HOME/Desktop" "$HOME/Documents" "$PWD/build"; do
  [ -d "$root" ] || continue
  find "$root" -type f \( -iname '*all*of*macos*.dmg' -o -iname '*aom*.dmg' \) -print0 >> "$LIST"
done
found=0
ok=0
failed=0
while IFS= read -r -d '' dmg; do
  found=$((found + 1))
  echo "Checking AOM DMG $found: $dmg"
  if bash "$PWD/scripts/publish-aom-release.sh" "$dmg"; then
    ok=$((ok + 1))
  else
    failed=$((failed + 1))
    echo "WARNING: rejected or upload failed: $dmg" >&2
  fi
done < "$LIST"
printf 'AOM DMGs: candidates=%s published_or_existing=%s rejected_or_failed=%s\n' "$found" "$ok" "$failed"
[ "$failed" -eq 0 ]
