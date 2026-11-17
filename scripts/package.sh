#!/bin/bash
# Builds build/Sideport.app (self-contained, ad-hoc signed) and build/Sideport-arm64.zip.
set -euo pipefail
cd "$(dirname "$0")/.."
PREFIX="$PWD/.deps/prefix"
[ -f "$PREFIX/lib/libmtp.dylib" ] || scripts/build-deps.sh

PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig" swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)/Sideport"

APP=build/Sideport.app
FW="$APP/Contents/Frameworks"
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$FW" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cp -L "$PREFIX/lib/libmtp.9.dylib" "$PREFIX/lib/libusb-1.0.0.dylib" "$FW/"
chmod u+w "$FW"/*.dylib

# Point every reference into .deps at the bundled copies.
for f in "$APP/Contents/MacOS/Sideport" "$FW"/*.dylib; do
  case "$f" in *.dylib) install_name_tool -id "@rpath/$(basename "$f")" "$f" ;; esac
  otool -L "$f" | awk -v p="$PREFIX" 'index($1, p) == 1 {print $1}' | while read -r dep; do
    install_name_tool -change "$dep" "@rpath/$(basename "$dep")" "$f"
  done
done
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/Sideport"

if otool -L "$APP/Contents/MacOS/Sideport" "$FW"/*.dylib | grep -E "/opt/homebrew|\.deps"; then
  echo "error: unbundled dylib reference left" >&2; exit 1
fi

codesign --force --deep --sign - "$APP"
ditto -c -k --keepParent "$APP" build/Sideport-arm64.zip
echo "built $APP and build/Sideport-arm64.zip"
