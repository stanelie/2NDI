#!/bin/bash
set -e
PROJ="$(cd "$(dirname "$0")" && pwd)"
SDK=$(xcrun --show-sdk-path)
MIN=11.0
BUILD="$PROJ/.build"
APP="$BUILD/2NDI.app"
MACOS="$APP/Contents/MacOS"
FW="$APP/Contents/Frameworks"

BASE_SDK="/Library/NDI SDK for Apple"
ADV_SDK="/Library/NDI Advanced SDK for Apple"

if [ ! -f "$ADV_SDK/include/Processing.NDI.Advanced.h" ]; then
  echo "!! NDI Advanced SDK not found at $ADV_SDK — install it from ndi.video" >&2
  exit 1
fi

echo "==> Cleaning build dir"
rm -rf "$BUILD"
mkdir -p "$MACOS" "$FW"

# Both dylibs ship in the bundle and neither is linked: they export the same C symbols,
# so NDISender picks one with dlopen at launch. That is what lets a single build offer
# HX (Advanced, 30-minute dev-licence cutoff) and unlimited SpeedHQ (base) side by side.
echo "==> Copying NDI libraries (overwrites anything already in the bundle)"
cp "$ADV_SDK/lib/macOS/libndi_advanced.dylib" "$FW/"
if [ -f "$BASE_SDK/lib/macOS/libndi.dylib" ]; then
  cp "$BASE_SDK/lib/macOS/libndi.dylib" "$FW/"
else
  echo "   (base SDK not installed — the app will offer the Advanced library only)"
fi

echo "==> Copying Syphon.framework"
cp -R "$PROJ/Frameworks/Syphon.framework" "$FW/"
install_name_tool -id \
  "@rpath/Syphon.framework/Versions/A/Syphon" \
  "$FW/Syphon.framework/Versions/A/Syphon"
# The vendored Syphon binary came out of another app's signed bundle, so its original
# signature no longer matches this one; dyld refuses to load it until it is re-signed.
codesign --force --sign - "$FW/Syphon.framework/Versions/A/Syphon" 2>/dev/null

OBJDIR="$BUILD/obj"
OBJC_SRCS=(SyphonInput NDISender)
SWIFT_SRCS=(
  "$PROJ/Sources/main.swift"
  "$PROJ/Sources/Stats.swift"
  "$PROJ/Sources/VideoInput.swift"
  "$PROJ/Sources/CameraInput.swift"
  "$PROJ/Sources/TestPatternInput.swift"
  "$PROJ/Sources/Encoder.swift"
  "$PROJ/Sources/FrameRenderer.swift"
  "$PROJ/Sources/Snapshot.swift"
  "$PROJ/Sources/FramePool.swift"
  "$PROJ/Sources/Pipeline.swift"
  "$PROJ/Sources/PreviewView.swift"
  "$PROJ/Sources/AppDelegate.swift"
)

for ARCH in arm64 x86_64; do
  mkdir -p "$OBJDIR/$ARCH"

  echo "==> Compiling Objective-C ($ARCH)"
  OBJS=()
  for NAME in "${OBJC_SRCS[@]}"; do
    clang \
      -arch $ARCH \
      -isysroot "$SDK" \
      -mmacosx-version-min=$MIN \
      -fobjc-arc \
      -fmodules \
      -Wall \
      -F"$PROJ/Frameworks" \
      -I"$PROJ/Sources" \
      -I"$ADV_SDK/include" \
      -c "$PROJ/Sources/$NAME.m" \
      -o "$OBJDIR/$ARCH/$NAME.o"
    OBJS+=("$OBJDIR/$ARCH/$NAME.o")
  done

  echo "==> Compiling Swift ($ARCH)"
  swiftc \
    -target $ARCH-apple-macos$MIN \
    -sdk "$SDK" \
    -O \
    -import-objc-header "$PROJ/BridgingHeader.h" \
    -F"$PROJ/Frameworks" \
    -Xcc -I"$PROJ/Sources" \
    -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
    "${SWIFT_SRCS[@]}" \
    "${OBJS[@]}" \
    -framework Cocoa \
    -framework AVFoundation \
    -framework Metal \
    -framework MetalKit \
    -framework CoreVideo \
    -framework CoreMedia \
    -framework VideoToolbox \
    -framework IOSurface \
    -framework Syphon \
    -o "$OBJDIR/$ARCH/2NDI"
done

echo "==> Creating universal binary"
lipo -create "$OBJDIR/arm64/2NDI" "$OBJDIR/x86_64/2NDI" -output "$MACOS/2NDI"

cp "$PROJ/Resources/Info.plist" "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources"
cp "$PROJ/Resources/AppIcon.icns" "$APP/Contents/Resources/"

# Finder litters .DS_Store inside bundles, and codesign seals them. A sealed .DS_Store
# breaks the signature the moment Finder rewrites it on another machine, which Gatekeeper
# reports only as "the application can't be opened".
echo "==> Removing .DS_Store before signing"
find "$APP" -name ".DS_Store" -delete

echo "==> Ad-hoc signing"
codesign --force --sign - "$FW/libndi_advanced.dylib" 2>/dev/null
[ -f "$FW/libndi.dylib" ] && codesign --force --sign - "$FW/libndi.dylib" 2>/dev/null
codesign --force --deep --sign - "$APP"

echo ""
lipo -info "$MACOS/2NDI"
echo "✓  Built: $APP"
echo "   Run:   open \"$APP\""
