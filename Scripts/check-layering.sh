#!/bin/bash
# Fails if the Core or Presentation layers depend on UI or browser frameworks.
set -euo pipefail
cd "$(dirname "$0")/.."

forbidden='^[[:space:]]*(@testable[[:space:]]+)?import[[:space:]]+(SwiftUI|WebKit|AppKit|UIKit|Cocoa)\b'
status=0
for layer in Sources/LoudibleCore Sources/LoudiblePresentation; do
    if grep -rEn "$forbidden" "$layer"; then
        echo "error: $layer must not import UI frameworks" >&2
        status=1
    fi
done

# The manifest must not give these targets other dependencies or linker settings.
if ! swift package dump-package | python3 -c '
import json, sys
targets = {t["name"]: t for t in json.load(sys.stdin)["targets"]}
failed = False
for name in ("LoudibleCore", "LoudiblePresentation"):
    target = targets[name]
    names = [next(iter(d.values()))[0] for d in target.get("dependencies", [])]
    if target.get("settings") or any(n != "LoudibleCore" for n in names):
        print(f"error: {name} may only depend on LoudibleCore, without settings (has {names})", file=sys.stderr)
        failed = True
sys.exit(1 if failed else 0)
'; then
    status=1
fi
exit $status
