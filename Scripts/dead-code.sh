#!/bin/bash
# Builds a clean compiler log and reports unused Swift declarations without changing sources.
set -euo pipefail
cd "$(dirname "$0")/.."

Scripts/build-ffmpeg.sh
source Scripts/env.sh
# Resolve the pinned tool before spending time on the clean build.
Scripts/swiftlint.sh version > /dev/null

mkdir -p "$PWD/.build/dead-code"
work_dir="$(mktemp -d "$PWD/.build/dead-code/scan.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT
build_log="$PWD/.build/dead-code/build.log"

echo "Building package and tests for analysis (log: $build_log)…"
# The native build system emits the swiftc invocations that SwiftLint's log parser needs.
# A fresh scratch directory guarantees a complete log without cleaning the development build.
if ! swift build --build-system native --build-tests --verbose \
    --scratch-path "$work_dir" > "$build_log" 2>&1; then
    cat "$build_log" >&2
    exit 1
fi
if ! grep -q -- ' -module-name LoudibleCore ' "$build_log"; then
    echo "error: No LoudibleCore compiler invocation found in $build_log" >&2
    exit 1
fi

# SwiftPM's verbose log adds -v to swiftc arguments. SourceKit replays those arguments for
# every symbol lookup, printing the compiler version thousands of times. Keep the full log
# for troubleshooting, but remove that flag from the compiler invocations used for analysis.
analysis_log="$work_dir/compiler.log"
sed '/\/swiftc /s/ -v / /g' "$build_log" > "$analysis_log"

echo "Checking for unused declarations…"
Scripts/swiftlint.sh analyze --config "$PWD/.swiftlint.yml" \
    --compiler-log-path "$analysis_log" --only-rule unused_declaration \
    --force-exclude --strict --quiet "$@"
echo "No unused declarations found."
