#!/bin/bash
# Builds libusb + libmtp (arm64, macOS 14+) into .deps/prefix.
# Homebrew's bottles target the build machine's macOS, so release builds use these instead.
set -euo pipefail
cd "$(dirname "$0")/.."
PREFIX="$PWD/.deps/prefix"
SRC="$PWD/.deps/src"
export MACOSX_DEPLOYMENT_TARGET=14.0
export CFLAGS="-arch arm64 -O2"
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"
mkdir -p "$SRC"
cd "$SRC"

fetch() { # url file sha256
  [ -f "$2" ] || curl -fsSL -o "$2" "$1"
  echo "$3  $2" | shasum -a 256 -c -
  tar xf "$2"
}

fetch https://github.com/libusb/libusb/releases/download/v1.0.30/libusb-1.0.30.tar.bz2 libusb.tar.bz2 \
  fea36f34f9156400209595e300840767ab1a385ede1dc7ee893015aea9c6dbaf
(cd libusb-1.0.30 && ./configure --prefix="$PREFIX" --disable-static >/dev/null && make -j8 install >/dev/null)

fetch https://downloads.sourceforge.net/project/libmtp/libmtp/1.1.23/libmtp-1.1.23.tar.gz libmtp.tar.gz \
  74a2b6e8cb4a0304e95b995496ea3ac644c29371649b892b856e22f12a0bdeed
(cd libmtp-1.1.23 && ./configure --prefix="$PREFIX" --disable-static --disable-mtpz >/dev/null && make -j8 install >/dev/null)

echo "deps installed in $PREFIX"
