#!/bin/bash
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
PROJ="$(dirname "$(dirname "$DIR")")"
ADV="/Library/NDI Advanced SDK for Apple"
SDK=$(xcrun --show-sdk-path)
for NAME in SyphonInput NDISender; do
  clang -arch x86_64 -isysroot "$SDK" -mmacosx-version-min=11.0 -fobjc-arc -fmodules \
    -F"$PROJ/Frameworks" -I"$PROJ/Sources" -I"$ADV/include" \
    -c "$PROJ/Sources/$NAME.m" -o "$DIR/$NAME.o"
done
swiftc -O -sdk "$SDK" -target x86_64-apple-macos11.0 \
  -F"$PROJ/Frameworks" \
  -import-objc-header "$DIR/Bridging.h" \
  -Xcc -I"$PROJ/Sources" -Xcc -I"$ADV/include" \
  -Xlinker -rpath -Xlinker "$PROJ/Frameworks" \
  "$PROJ/Sources/Stats.swift" "$PROJ/Sources/FrameRenderer.swift" "$PROJ/Sources/FramePool.swift" \
  "$PROJ/Sources/Encoder.swift" "$PROJ/Sources/Snapshot.swift" "$PROJ/Sources/VideoInput.swift" "$PROJ/Sources/CameraInput.swift" "$PROJ/Sources/TestPatternInput.swift" \
  "$PROJ/Sources/Pipeline.swift" "$DIR/main.swift" \
  "$DIR/SyphonInput.o" "$DIR/NDISender.o" \
  -framework Cocoa -framework Metal -framework CoreImage -framework CoreVideo \
  -framework CoreMedia -framework VideoToolbox -framework IOSurface \
  -framework AVFoundation -framework Syphon \
  -o "$DIR/profile"
echo "✓ $DIR/profile"
