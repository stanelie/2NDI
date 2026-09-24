#!/bin/bash
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
PROJ="$(dirname "$(dirname "$DIR")")"
ADV="/Library/NDI Advanced SDK for Apple"
SDK=$(xcrun --show-sdk-path)
clang -arch x86_64 -isysroot "$SDK" -mmacosx-version-min=11.0 -fobjc-arc -fmodules \
  -I"$PROJ/Sources" -I"$ADV/include" -c "$PROJ/Sources/NDISender.m" -o "$DIR/NDISender.o"
swiftc -O -sdk "$SDK" -target x86_64-apple-macos11.0 \
  -import-objc-header "$DIR/Bridging.h" \
  -Xcc -I"$PROJ/Sources" -Xcc -I"$ADV/include" \
  "$PROJ/Sources/LibraryLog.swift" "$PROJ/Sources/Encoder.swift" "$DIR/main.swift" "$DIR/NDISender.o" \
  -framework Foundation -framework CoreVideo -framework IOSurface -framework VideoToolbox -framework CoreMedia \
  -o "$DIR/soak"
echo "✓ $DIR/soak"
