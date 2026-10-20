#!/bin/bash
# Runs a pinned SwiftFormat without Homebrew or SwiftPM build dependencies.
set -euo pipefail
cd "$(dirname "$0")/.."

# Update together from the upstream release's swiftformat.zip and asset SHA-256.
VERSION=0.64.0
SHA256=95ea62625d0b898a7af870293311ae6f09e4a3147ecd900593687e4b9ab2fd98
INSTALL_DIR="$PWD/.build/tools/swiftformat-$VERSION"

if [ ! -x "$INSTALL_DIR/swiftformat" ]; then
    mkdir -p "$PWD/.build/tools"
    staging="$(mktemp -d "$PWD/.build/tools/swiftformat.XXXXXX")"
    trap 'rm -rf "$staging"' EXIT
    curl --fail --location --silent --show-error --retry 3 \
        --connect-timeout 15 --max-time 300 \
        "https://github.com/nicklockwood/SwiftFormat/releases/download/$VERSION/swiftformat.zip" \
        -o "$staging/swiftformat.zip"
    echo "$SHA256  $staging/swiftformat.zip" | shasum -a 256 --check
    unzip -q "$staging/swiftformat.zip" -d "$staging/unpacked"
    mkdir -p "$INSTALL_DIR"
    cp "$staging/unpacked/swiftformat" "$INSTALL_DIR/"
fi

exec "$INSTALL_DIR/swiftformat" Package.swift Sources Tests App/Loudible \
    --config "$PWD/.swiftformat" --cache ignore "$@"
