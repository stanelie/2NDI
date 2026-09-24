#!/bin/bash
# Builds NDI's own HX2 reference senders, unmodified, from the Advanced SDK examples.
#
# The point is the A/B: if a receiver refuses our stream but accepts this one, the fault
# is ours; if it refuses both, the fault is at the receiver. Nothing here is our code, so
# a failure against it cannot be a bug in 2NDI.
set -e
ADV="/Library/NDI Advanced SDK for Apple"
SRC="$ADV/examples/C++ (HX2)"
OUT="$(cd "$(dirname "$0")" && pwd)"

# Portable by default: universal, with the dylib resolved next to the binary, so the
# whole folder can be handed to a machine that has no SDK installed. That matters because
# the machine with the awkward receiver on it is rarely the machine with the SDK on it.
PKG="$OUT/hxref"
rm -rf "$PKG"; mkdir -p "$PKG"
cp "$ADV/lib/macOS/libndi_advanced.dylib" "$PKG/"

for NAME in NDIlib_Send_H264 NDIlib_Send_HEVC; do
  BIN="$PKG/${NAME#NDIlib_Send_}_ref"
  echo "==> $NAME"
  clang++ -std=c++17 -O2 -arch x86_64 -arch arm64 \
    -mmacosx-version-min=11.0 \
    -I"$ADV/include" -I"$SRC/$NAME" \
    "$SRC/$NAME/$NAME.cpp" \
    "$PKG/libndi_advanced.dylib" \
    -Wl,-rpath,@loader_path \
    -o "$BIN"
  install_name_tool -change \
    "@rpath/libndi_advanced.dylib" "@loader_path/libndi_advanced.dylib" "$BIN" 2>/dev/null || true
  codesign --force --sign - "$BIN" 2>/dev/null || true
  echo "    -> $BIN"
done
codesign --force --sign - "$PKG/libndi_advanced.dylib" 2>/dev/null || true
