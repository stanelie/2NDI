#!/bin/bash
# The NDI SDK's own PNG sender and receiver, built as-is. They are the tiebreaker when a
# receiver disagrees with this app about which way up a frame is: both pass the lodepng
# buffer straight to and from NDIlib_video_frame_v2_t::p_data with no flip of their own,
# so they define NDI's row order rather than assuming it.
#
# The receiver differs from the shipped example by one line: it loops until a video frame
# arrives instead of giving up when the first capture returns a status change. The
# lodepng_encode_file call that determines row order is untouched.
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
ADV="/Library/NDI Advanced SDK for Apple"
for NAME in ndi_send_png ndi_recv_png; do
  clang++ -std=c++17 -O2 \
    -I"$ADV/include" \
    -I"$ADV/examples/C++/NDIlib_Recv_PNG" \
    "$DIR/$NAME.cpp" \
    "$ADV/lib/macOS/libndi_advanced.dylib" \
    -Xlinker -rpath -Xlinker "$ADV/lib/macOS" \
    -o "$DIR/$NAME" 2>&1 | grep -v "was built for newer" || true
  echo "✓ $DIR/$NAME"
done
