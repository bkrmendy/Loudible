#!/bin/bash
# The single test command for NativeMac.
#
#   Scripts/test.sh [swift test arguments, e.g. --filter LibraryTests]
#
# 1. Lints Swift and checks that Core and Presentation do not import UI frameworks.
# 2. Builds the package and tests (network allowed, for package resolution).
# 3. Runs the tests inside a sandbox that denies all non-loopback network traffic,
#    so a test that accidentally contacts Audible fails instead of reaching it.
# Every step is bounded by a timeout (TEST_TIMEOUT seconds per step, default 900).
set -euo pipefail
set -m # background jobs get their own process group, so a timeout kills the whole tree

cd "$(dirname "$0")/.."
TIMEOUT="${TEST_TIMEOUT:-900}"
with_timeout() {
    "$@" &
    local pid=$!
    ( sleep "$TIMEOUT"; echo "error: '$*' timed out after ${TIMEOUT}s" >&2
      kill -TERM -"$pid" 2>/dev/null; sleep 5; kill -KILL -"$pid" 2>/dev/null ) &
    local watchdog=$!
    local status=0
    wait "$pid" || status=$?
    kill -TERM -"$watchdog" 2>/dev/null || true
    wait "$watchdog" 2>/dev/null || true
    return "$status"
}

with_timeout Scripts/format.sh --lint
with_timeout Scripts/lint.sh
Scripts/build-ffmpeg.sh   # may download, so it runs before the network sandbox
source Scripts/env.sh
Scripts/check-layering.sh

# Incremental builds with Swift 6.4 (Xcode 27 and the Command Line Tools alike) can lose the Swift Testing macro
# plugin ("plugin for module 'TestingMacros' not found"); naming its directory avoids that.
BUILD_FLAGS=()
TESTING_PLUGINS="$(dirname "$(xcrun --find swift)")/../lib/swift/host/plugins/testing"
if [ -d "$TESTING_PLUGINS" ]; then
    BUILD_FLAGS+=(-Xswiftc -plugin-path -Xswiftc "$TESTING_PLUGINS")
fi

with_timeout swift build --build-tests ${BUILD_FLAGS[@]+"${BUILD_FLAGS[@]}"}

SANDBOX_PROFILE='(version 1)
(allow default)
(deny network-outbound (remote ip "*:*"))
(allow network-outbound (remote ip "localhost:*"))
(allow network-outbound (remote unix-socket))'

LOUDIBLE_TEST_SANDBOX=1 with_timeout \
    sandbox-exec -p "$SANDBOX_PROFILE" swift test --skip-build --disable-sandbox "$@"
