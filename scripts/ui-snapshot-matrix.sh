#!/bin/bash
# Renders AOM's preview windows with AOM's own renderer (--aom-preview-snapshot),
# so no Screen Recording permission is needed. Used by .github/workflows/ui-snapshots.yml.
# usage: scripts/ui-snapshot-matrix.sh <AllOfMacOS binary> <output dir> [sizes] [tabs]
set -u
BIN="$1"; OUT="$2"
SIZES="${3:-980x600 1320x860}"
TABS="${4:-$(seq 1 13)}"
mkdir -p "$OUT"
DOMAIN=AllOfMacOS
defaults write "$DOMAIN" AOMHasSeenTutorial -bool true

shot() { # name, extra args...
  local name="$1"; shift
  local pdir; pdir="$(mktemp -d "${TMPDIR:-/tmp}/AOMPreview-XXXX")"
  local sdir; sdir="$(mktemp -d "${TMPDIR:-/tmp}/AOMSnap-XXXX")"
  "$BIN" --aom-ui-preview "$pdir" --aom-preview-snapshot "$sdir" --aom-preview-snapshot-delay 7 "$@" >/dev/null 2>&1 &
  local pid=$!
  for _ in $(seq 1 40); do
    sleep 1
    ls "$sdir"/window-*.png >/dev/null 2>&1 && { sleep 1; break; }
  done
  kill "$pid" 2>/dev/null; sleep 0.5; kill -9 "$pid" 2>/dev/null
  local n=0
  for f in "$sdir"/window-*.png; do
    [ -f "$f" ] || continue
    cp "$f" "$OUT/${name}-w${n}.png"; n=$((n+1))
  done
  echo "$name: $n window(s)"
  rm -rf "$pdir" "$sdir"
}

for mode in light dark; do
  defaults write "$DOMAIN" AOMAppearance "$mode"
  for size in $SIZES; do
    for tab in $TABS; do
      shot "tab$(printf %02d "$tab")-${size}-${mode}" --aom-preview-size "$size" --aom-preview-tab "$tab" \
        --aom-preview-activate --aom-preview-insights-sample --aom-preview-menubar-sample --aom-preview-sample-data
    done
  done
  shot "settings-${mode}" --aom-preview-settings --aom-preview-activate
  shot "launcher-${mode}" --aom-preview-launcher --aom-preview-activate
  shot "menubarpanel-${mode}" --aom-preview-menubar-panel --aom-preview-menubar-sample --aom-preview-activate
done
defaults delete "$DOMAIN" AOMAppearance 2>/dev/null || true
ls "$OUT" | wc -l
