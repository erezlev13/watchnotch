#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
app="$PWD/.build/watchnotch.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" .build/module-cache
MACOSX_DEPLOYMENT_TARGET=13.0 swiftc -swift-version 5 -O -module-cache-path "$PWD/.build/module-cache" Sources/*.swift -o "$app/Contents/MacOS/SessionCompanion"
cp Info.plist "$app/Contents/Info.plist"
cp Adapters/Codex/monitor.py "$app/Contents/Resources/monitor.py"
codesign --force --sign - "$app"
echo "$app"
