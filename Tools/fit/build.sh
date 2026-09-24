#!/bin/bash
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
PROJ="$(dirname "$(dirname "$DIR")")"
swiftc -O -sdk "$(xcrun --show-sdk-path)" -target x86_64-apple-macos11.0 \
  "$PROJ/Sources/FrameRenderer.swift" "$PROJ/Sources/FramePool.swift" "$DIR/main.swift" \
  -framework Metal -framework CoreImage -framework CoreVideo \
  -framework CoreGraphics -framework ImageIO \
  -o "$DIR/fit_test"
echo "✓ $DIR/fit_test"
