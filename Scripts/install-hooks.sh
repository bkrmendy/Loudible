#!/bin/bash
# Enable the versioned Git hooks for this checkout.
set -euo pipefail
cd "$(dirname "$0")/.."
git config --local core.hooksPath .githooks
echo "Git hooks enabled: SwiftFormat and SwiftLint will run before each commit."
