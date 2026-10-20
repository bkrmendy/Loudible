#!/bin/bash
# Render source-local SwiftUI examples through the sandboxed test host, without launching the app.
set -euo pipefail
usage() {
    cat <<'HELP'
Usage: Scripts/render-previews.sh [--all | --file Name.swift | --state id,id] [--output DIR]
       Scripts/render-previews.sh --list

  --all          Regenerate every preview (the default).
  --file NAME    Render a single source file, e.g. BookTile.swift.
  --state IDS    Render comma-separated state IDs; may be combined with --file.
  --output DIR   Put all <View>-Previews folders under DIR instead of beside the Swift files.
  --list         List source files, state IDs and titles without rendering.
  --help         Show this help.

Each folder contains <View>Preview.html and images/<state>.png. Requires Xcode
and a logged-in macOS graphical session; no app or visible window is launched.
HELP
}
fail() { echo "error: $*" >&2; exit 2; }
mode=render
all=0
file=
states=
output=
while [ "$#" -gt 0 ]; do
    case "$1" in
        --all) all=1; shift ;;
        --file|--state|--output)
            option="$1"
            [ "$#" -ge 2 ] && [ -n "$2" ] && [[ "$2" != --* ]] || fail "$option requires a value"
            case "$option" in
                --file) file="$(basename "$2")" ;;
                --state) states="$2" ;;
                --output) output="$2" ;;
            esac
            shift 2 ;;
        --list) mode=list; shift ;;
        --help|-h) usage; exit 0 ;;
        *) fail "Unknown argument: $1 (see --help)" ;;
    esac
done
if [ "$all" = 1 ] && { [ -n "$file" ] || [ -n "$states" ]; }; then
    fail "--all cannot be combined with --file or --state"
fi
if [ "$mode" = list ] && { [ "$all" = 1 ] || [ -n "$file$states$output" ]; }; then
    fail "--list cannot be combined with rendering options"
fi
# Resolve relative output paths before test.sh changes the working directory.
if [ -n "$output" ] && [[ "$output" != /* ]]; then output="$PWD/$output"; fi
export LOUDIBLE_PREVIEWS_MODE="$mode" LOUDIBLE_PREVIEWS_FILE="$file"
export LOUDIBLE_PREVIEWS_STATES="$states" LOUDIBLE_PREVIEWS_OUTPUT="$output"
exec "$(dirname "$0")/test.sh" --filter SnapshotTests/previewGalleries
