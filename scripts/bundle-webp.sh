#!/bin/bash
# Bundle the existing BSD-licensed codec; recipients do not need Homebrew.
set -euo pipefail
contents="$1"
sign_identity="${2:-AOM Dev}"
codec_root="${AOM_WEBP_ROOT:-/opt/homebrew/opt/webp}"
if [ ! -d "$codec_root" ]; then codec_root="/usr/local/opt/webp"; fi
mkdir -p "$contents/Frameworks" "$contents/Resources/Licenses"
cp "$codec_root/lib/libwebp.7.dylib" "$contents/Frameworks/libwebp.7.dylib"
cp "$codec_root/lib/libsharpyuv.0.dylib" "$contents/Frameworks/libsharpyuv.0.dylib"
cp "$codec_root/COPYING" "$contents/Resources/Licenses/libwebp.txt"
cp "$codec_root/AUTHORS" "$contents/Resources/Licenses/libwebp-authors.txt"
install_name_tool -id '@loader_path/libsharpyuv.0.dylib' "$contents/Frameworks/libsharpyuv.0.dylib"
install_name_tool -id '@loader_path/libwebp.7.dylib' -change '@rpath/libsharpyuv.0.dylib' '@loader_path/libsharpyuv.0.dylib' "$contents/Frameworks/libwebp.7.dylib"
codesign --force --sign "$sign_identity" "$contents/Frameworks/libsharpyuv.0.dylib"
codesign --force --sign "$sign_identity" "$contents/Frameworks/libwebp.7.dylib"
