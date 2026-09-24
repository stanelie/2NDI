#!/bin/bash
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
ADV="/Library/NDI Advanced SDK for Apple"
for NAME in ndi_probe ndi_watch; do
clang++ -std=c++17 -O2 \
  -I"$ADV/include" \
  "$DIR/$NAME.cpp" \
  "$ADV/lib/macOS/libndi_advanced.dylib" \
  -Xlinker -rpath -Xlinker "$ADV/lib/macOS" \
  -framework ImageIO -framework CoreGraphics -framework CoreFoundation \
  -o "$DIR/$NAME"
echo "✓ $DIR/$NAME"
done
