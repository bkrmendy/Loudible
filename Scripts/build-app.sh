#!/bin/bash
# Builds a self-contained, ad-hoc signed build/AudibleExporter.app for Apple Silicon from
# App/AudibleExporter.xcodeproj (derived data in .build/xcode).
#
#   Scripts/build-app.sh            # release build
#   CONFIGURATION=debug Scripts/build-app.sh
#
# The minimal LGPL FFmpeg from Scripts/build-ffmpeg.sh is copied into Contents/Frameworks
# with @rpath install names; notices, licenses, and About-panel credits go to
# Contents/Resources. Run Scripts/verify-app.sh afterwards to check the bundle.
set -euo pipefail
cd "$(dirname "$0")/.."
Scripts/build-ffmpeg.sh
source Scripts/env.sh

CONFIGURATION="${CONFIGURATION:-release}"
case "$CONFIGURATION" in
    release) XCODE_CONFIGURATION=Release ;;
    debug) XCODE_CONFIGURATION=Debug ;;
    *) echo "error: CONFIGURATION must be release or debug" >&2; exit 1 ;;
esac
APP_NAME="AudibleExporter"
APP="build/$APP_NAME.app"
DERIVED_DATA=".build/xcode"

# Bundle id, version, Info.plist, and deployment target are set in the Xcode project.
xcodebuild -quiet \
    -project App/AudibleExporter.xcodeproj -scheme "$APP_NAME" \
    -configuration "$XCODE_CONFIGURATION" -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$DERIVED_DATA" build

rm -rf "$APP"
mkdir -p build
ditto "$DERIVED_DATA/Build/Products/$XCODE_CONFIGURATION/$APP_NAME.app" "$APP"
mkdir -p "$APP/Contents/Frameworks" "$APP/Contents/Resources/Licenses"

# Debug builds put the code in AudibleExporter.debug.dylib next to a small launcher.
BINARY="$APP/Contents/MacOS/$APP_NAME"
if [ -f "$BINARY.debug.dylib" ]; then BINARY="$BINARY.debug.dylib"; fi

echo "Bundling libraries…"
Scripts/bundle_dylibs.py "$BINARY" "$APP/Contents/Frameworks" > build/bundled-libraries.tsv
echo "  $(wc -l < build/bundled-libraries.tsv | tr -d ' ') libraries"

MINIMUM_OS="$FFMPEG_MINIMUM_MACOS"
PLIST_MINIMUM="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP/Contents/Info.plist")"
if [ "$PLIST_MINIMUM" != "$MINIMUM_OS" ]; then
    echo "error: the Xcode project targets macOS $PLIST_MINIMUM, but FFmpeg is built for $MINIMUM_OS" >&2
    exit 1
fi

echo "Writing third-party notices…"
Scripts/write-notices.py "$FFMPEG_PREFIX" "$APP/Contents/Resources"

echo "Signing (ad-hoc)…"
for dylib in "$APP/Contents/Frameworks/"*.dylib "$APP/Contents/MacOS/"*.dylib; do
    if [ -f "$dylib" ]; then codesign --force --sign - --timestamp=none "$dylib"; fi
done
codesign --force --sign - --timestamp=none "$APP"

echo "Built $APP (minimum macOS $MINIMUM_OS)"
