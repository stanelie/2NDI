#!/bin/bash
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
PROJ="$(dirname "$DIR")"
swiftc -sdk "$(xcrun --show-sdk-path)" -target x86_64-apple-macos11.0 \
  "$PROJ/Sources/Encoder.swift" "$PROJ/Sources/FrameRenderer.swift" "$PROJ/Sources/FramePool.swift" "$DIR/main.swift" \
  -framework Metal -framework CoreImage -framework VideoToolbox -framework CoreMedia -framework CoreVideo \
  -o "$DIR/encoder_test"
echo "✓ $DIR/encoder_test"
