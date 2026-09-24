#!/bin/bash
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
PROJ="$(dirname "$(dirname "$DIR")")"
SET="$DIR/AppIcon.iconset"
rm -rf "$SET"; mkdir -p "$SET"
swiftc -O -sdk "$(xcrun --show-sdk-path)" -target x86_64-apple-macos11.0 \
  "$DIR/main.swift" -framework CoreGraphics -framework CoreText -framework ImageIO \
  -o "$DIR/make_icon"
"$DIR/make_icon" "$SET"
mkdir -p "$PROJ/Resources"
iconutil -c icns "$SET" -o "$PROJ/Resources/AppIcon.icns"
echo "✓ $PROJ/Resources/AppIcon.icns"
