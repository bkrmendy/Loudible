# Sourced by the other scripts, or by hand (bash or zsh) before running swift commands.
#
# Selects Xcode's toolchain: the Command Line Tools lack the plugins behind #Preview and other
# SwiftUI macros. Then checks that Scripts/build-ffmpeg.sh has built the FFmpeg that
# Package.swift links from Vendor/ffmpeg.
_aex_root="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
source "$_aex_root/Scripts/ffmpeg-version.sh"

if [ -z "${DEVELOPER_DIR:-}" ]; then
    if [ -d /Applications/Xcode.app/Contents/Developer ]; then
        export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
    else
        echo "error: Xcode not found at /Applications/Xcode.app. Install Xcode, or set DEVELOPER_DIR to another Xcode's Contents/Developer" >&2
        unset _aex_root
        return 1 2>/dev/null || exit 1
    fi
fi

FFMPEG_PREFIX="$_aex_root/Vendor/ffmpeg"
unset _aex_root
if [ ! -f "$FFMPEG_PREFIX/lib/pkgconfig/libavformat.pc" ]; then
    echo "error: FFmpeg not found in $FFMPEG_PREFIX. Run Scripts/build-ffmpeg.sh" >&2
    return 1 2>/dev/null || exit 1
fi
case "$(awk -F': ' '/^Version:/{print $2}' "$FFMPEG_PREFIX/lib/pkgconfig/libavformat.pc")" in
    61.*) ;;
    *) echo "error: $FFMPEG_PREFIX is not FFmpeg 7.1 (libavformat 61). Run Scripts/build-ffmpeg.sh" >&2
       return 1 2>/dev/null || exit 1 ;;
esac
export FFMPEG_PREFIX
