#!/bin/bash
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
PROJ="$(dirname "$(dirname "$DIR")")"
swiftc -O -sdk "$(xcrun --show-sdk-path)" -target x86_64-apple-macos11.0 \
  -F"$PROJ/Frameworks" \
  -import-objc-header "$DIR/Bridging.h" \
  -Xlinker -rpath -Xlinker "$PROJ/Frameworks" \
  "$DIR/main.swift" \
  -framework Cocoa -framework Metal -framework Syphon -framework CoreGraphics -framework ImageIO \
  -o "$DIR/syphon_dump"
echo "✓ $DIR/syphon_dump"
