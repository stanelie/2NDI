#!/bin/bash
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
PROJ="$(dirname "$(dirname "$DIR")")"
swiftc -O -sdk "$(xcrun --show-sdk-path)" -target x86_64-apple-macos11.0 \
  -F"$PROJ/Frameworks" \
  -import-objc-header "$DIR/Bridging.h" \
  -Xlinker -rpath -Xlinker "$PROJ/Frameworks" \
  "$DIR/main.swift" \
  -framework Metal -framework Syphon -framework Cocoa \
  -o "$DIR/syphon_pattern"
echo "✓ $DIR/syphon_pattern"
