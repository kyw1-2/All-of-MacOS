#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
contents="$1"
sign_identity="${2:-AOM Dev}"

SOURCE_SWISH=""
if [ -d "/Applications/Swish.app" ]; then
    SOURCE_SWISH="/Applications/Swish.app"
elif [ -d "$root/Bundled/Swish.app" ]; then
    SOURCE_SWISH="$root/Bundled/Swish.app"
fi

if [ -n "$SOURCE_SWISH" ]; then
    echo "==> Bundling Swish from $SOURCE_SWISH into $contents/Helpers/Swish.app"
    mkdir -p "$contents/Helpers"
    rm -rf "$contents/Helpers/Swish.app"
    cp -R "$SOURCE_SWISH" "$contents/Helpers/Swish.app"
    
    # Resolve exact identity hash if not ad-hoc (-)
    sign_target="$sign_identity"
    if [ "$sign_identity" != "-" ]; then
        resolved="$("$root/scripts/resolve-signing-identity.sh" "$sign_identity" 2>/dev/null || true)"
        if [ -n "$resolved" ]; then
            sign_target="$resolved"
        fi
    fi
    
    # Sign nested frameworks and dylibs first
    if [ -d "$contents/Helpers/Swish.app/Contents/Frameworks" ]; then
        for fw in "$contents/Helpers/Swish.app/Contents/Frameworks"/*.framework; do
            if [ -d "$fw" ]; then
                codesign --force --sign "$sign_target" "$fw" 2>/dev/null || true
            fi
        done
        for lib in "$contents/Helpers/Swish.app/Contents/Frameworks"/*.dylib; do
            if [ -f "$lib" ]; then
                codesign --force --sign "$sign_target" "$lib" 2>/dev/null || true
            fi
        done
    fi
    
    codesign --force --sign "$sign_target" "$contents/Helpers/Swish.app"
    echo "==> Successfully bundled and signed Swish.app"
else
    echo "==> Swish.app not found, skipping Swish embedding"
fi
