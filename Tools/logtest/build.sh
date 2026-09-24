#!/bin/bash
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
PROJ="$(dirname "$(dirname "$DIR")")"
swiftc -O -sdk "$(xcrun --show-sdk-path)" -target x86_64-apple-macos11.0 \
  "$PROJ/Sources/LibraryLog.swift" "$DIR/main.swift" -o "$DIR/logtest"
echo "✓ $DIR/logtest"
