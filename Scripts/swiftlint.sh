#!/bin/bash
# Shared entry point for the pinned SwiftLint, used by lint.sh and dead-code.sh.
set -euo pipefail
cd "$(dirname "$0")/.."

# Update the version and SHA-256 together from the upstream release's portable_swiftlint.zip.
VERSION=0.65.1
SHA256=c1e429b0599cf1b516f369a2d9ec04eaf0e436f3c12b637df8851fa52ff694d0
INSTALL_DIR="$PWD/.build/tools/swiftlint-$VERSION"

if [ ! -x "$INSTALL_DIR/swiftlint" ]; then
    mkdir -p "$PWD/.build/tools"
    staging="$(mktemp -d "$PWD/.build/tools/swiftlint.XXXXXX")"
    trap 'rm -rf "$staging"' EXIT
    curl --fail --location --silent --show-error --retry 3 \
        --connect-timeout 15 --max-time 300 \
        "https://github.com/realm/SwiftLint/releases/download/$VERSION/portable_swiftlint.zip" \
        -o "$staging/swiftlint.zip"
    echo "$SHA256  $staging/swiftlint.zip" | shasum -a 256 --check
    unzip -q "$staging/swiftlint.zip" -d "$staging/unpacked"
    mkdir -p "$INSTALL_DIR"
    cp -R "$staging/unpacked/." "$INSTALL_DIR/"
fi

# SourceKit must use the same Xcode toolchain as the app. Linting needs no FFmpeg build.
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
"$INSTALL_DIR/swiftlint" "$@"
