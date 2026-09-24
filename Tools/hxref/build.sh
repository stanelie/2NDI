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

for NAME in NDIlib_Send_H264 NDIlib_Send_HEVC; do
  echo "==> $NAME"
  clang++ -std=c++17 -O2 \
    -I"$ADV/include" -I"$SRC/$NAME" \
    "$SRC/$NAME/$NAME.cpp" \
    "$ADV/lib/macOS/libndi_advanced.dylib" \
    -Wl,-rpath,"$ADV/lib/macOS" \
    -o "$OUT/${NAME#NDIlib_Send_}_ref"
  echo "    -> $OUT/${NAME#NDIlib_Send_}_ref"
done
