#!/bin/bash
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
PROJ="$(dirname "$(dirname "$DIR")")"
swiftc -sdk "$(xcrun --show-sdk-path)" -target x86_64-apple-macos11.0 \
  -F"$PROJ/Frameworks" \
  -import-objc-header "$DIR/Bridging.h" \
  -Xlinker -rpath -Xlinker "$PROJ/Frameworks" \
  "$DIR/main.swift" -framework Cocoa -framework Syphon \
  -o "$DIR/syphon_list"
echo "✓ $DIR/syphon_list"
