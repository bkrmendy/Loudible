#!/bin/bash
# Runs strict lint checks using the shared pinned SwiftLint.
set -euo pipefail
cd "$(dirname "$0")/.."

exec Scripts/swiftlint.sh lint --config "$PWD/.swiftlint.yml" \
    --cache-path "$PWD/.build/tools/swiftlint-cache" --force-exclude --strict "$@"
