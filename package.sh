#!/bin/bash
# Packages the built app for copying to another Mac.
#
# ditto rather than Finder's "Compress" or `zip`: the Syphon framework is held together by
# four symlinks, and an archiver that flattens or drops them produces a bundle whose code
# signature no longer verifies. Gatekeeper then reports that only as "the application
# can't be opened", with no hint as to why.
set -e
PROJ="$(cd "$(dirname "$0")" && pwd)"
APP="$PROJ/.build/2NDI.app"
ZIP="$PROJ/2NDI.zip"

[ -d "$APP" ] || { echo "!! $APP not found — run ./build.sh first" >&2; exit 1; }

find "$APP" -name ".DS_Store" -delete
codesign --verify --deep --strict "$APP" || {
  echo "!! signature is not valid; re-signing" >&2
  codesign --force --deep --sign - "$APP"
}

rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

echo "✓  $ZIP"
echo
echo "   On the other Mac, after copying:"
echo "     xattr -cr /path/to/2NDI.app     # clear the quarantine flag"
echo "     open /path/to/2NDI.app"
echo
echo "   If it still refuses, run the binary directly for the real reason:"
echo "     /path/to/2NDI.app/Contents/MacOS/2NDI"
