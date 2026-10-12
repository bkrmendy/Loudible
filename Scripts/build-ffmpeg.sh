#!/bin/bash
# Builds the minimal, LGPL-licensed FFmpeg that Loudible links and bundles:
# arm64 shared libraries (libavformat, libavcodec, libavutil) with only the components
# needed to decrypt AAX/AAXC and remux into M4B. Installs into Vendor/ffmpeg-<version>, with a
# Vendor/ffmpeg symlink to it that Package.swift uses.
#
# Does nothing when that build is already current. Needs only the Command Line Tools.
set -euo pipefail
cd "$(dirname "$0")/.."
source Scripts/ffmpeg-version.sh

ROOT="$PWD/Vendor"
PREFIX="$ROOT/ffmpeg-$FFMPEG_VERSION"
WORK="$ROOT/build"
TARBALL="$ROOT/downloads/ffmpeg-$FFMPEG_VERSION.tar.xz"

CONFIGURE_FLAGS=(
    --prefix="$PREFIX"
    --arch=arm64 --target-os=darwin --cc=clang
    --extra-cflags="-mmacosx-version-min=$FFMPEG_MINIMUM_MACOS"
    --extra-ldflags="-mmacosx-version-min=$FFMPEG_MINIMUM_MACOS"
    --enable-shared --disable-static
    --disable-programs --disable-doc --disable-network --disable-autodetect
    --disable-avdevice --disable-avfilter --disable-swscale --disable-swresample --disable-postproc
    --disable-everything
    --enable-protocol=file
    --enable-demuxer=mov
    --enable-muxer=ipod,mp4
    # Stream probing fills in audio and cover-art parameters with these.
    --enable-parser=aac,mjpeg,png
    --enable-decoder=aac,mjpeg,png
    --enable-zlib
)
STAMP="$FFMPEG_VERSION $FFMPEG_SHA256 ${CONFIGURE_FLAGS[*]}"

# Package.swift finds the headers and libraries here, whatever the version.
link_current() { ln -sfn "ffmpeg-$FFMPEG_VERSION" "$ROOT/ffmpeg"; }

if [ -f "$PREFIX/.build-stamp" ] && [ "$(cat "$PREFIX/.build-stamp")" = "$STAMP" ]; then
    link_current
    echo "FFmpeg $FFMPEG_VERSION is up to date in $PREFIX"
    exit 0
fi

mkdir -p "$ROOT/downloads"
if [ ! -f "$TARBALL" ]; then
    echo "Downloading $FFMPEG_URL"
    curl --fail --location --silent --show-error --output "$TARBALL.part" "$FFMPEG_URL"
    mv "$TARBALL.part" "$TARBALL"
fi
actual="$(shasum -a 256 "$TARBALL" | awk '{print $1}')"
if [ "$actual" != "$FFMPEG_SHA256" ]; then
    echo "error: $TARBALL has SHA-256 $actual, expected $FFMPEG_SHA256" >&2
    rm -f "$TARBALL"
    exit 1
fi

rm -rf "$WORK" "$PREFIX"
mkdir -p "$WORK"
tar -xf "$TARBALL" -C "$WORK"
SOURCE="$WORK/ffmpeg-$FFMPEG_VERSION"

echo "Configuring FFmpeg ${FFMPEG_VERSION}…"
(cd "$SOURCE" && ./configure "${CONFIGURE_FLAGS[@]}" > "$WORK/configure.log") || {
    tail -30 "$SOURCE/ffbuild/config.log" >&2
    exit 1
}

# Refuse anything that would change the license away from the LGPL.
if grep -qE '^#define CONFIG_(GPL|GPLV3|VERSION3|NONFREE) 1' "$SOURCE/config.h"; then
    echo "error: FFmpeg configuration enables GPL or non-free components" >&2
    exit 1
fi

echo "Building…"
make -C "$SOURCE" -j"$(sysctl -n hw.ncpu)" > "$WORK/make.log" 2>&1 || { tail -30 "$WORK/make.log" >&2; exit 1; }
make -C "$SOURCE" install > "$WORK/install.log" 2>&1 || { tail -30 "$WORK/install.log" >&2; exit 1; }

for dylib in "$PREFIX"/lib/*.dylib; do
    [ -L "$dylib" ] && continue
    minos="$(otool -l "$dylib" | awk '/LC_BUILD_VERSION/{found=1} found && /minos/{print $2; exit}')"
    if [ "$minos" != "$FFMPEG_MINIMUM_MACOS" ]; then
        echo "error: $dylib targets macOS $minos, expected $FFMPEG_MINIMUM_MACOS" >&2
        exit 1
    fi
    [ "$(lipo -archs "$dylib")" = "arm64" ] || { echo "error: $dylib is not arm64-only" >&2; exit 1; }
done

# License texts for the app's notices.
mkdir -p "$PREFIX/share/licenses"
cp "$SOURCE/COPYING.LGPLv2.1" "$SOURCE/LICENSE.md" "$PREFIX/share/licenses/"

cat > "$PREFIX/BUILD-INFO.txt" <<INFO
version=$FFMPEG_VERSION
url=$FFMPEG_URL
sha256=$FFMPEG_SHA256
license=LGPL-2.1-or-later
configure=${CONFIGURE_FLAGS[*]/#--prefix=*/--prefix=<install dir>}
INFO

echo "$STAMP" > "$PREFIX/.build-stamp"
link_current
rm -rf "$WORK"
echo "FFmpeg $FFMPEG_VERSION installed in $PREFIX"
