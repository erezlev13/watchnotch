#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
app="$PWD/.build/watchnotch.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" .build/module-cache
MACOSX_DEPLOYMENT_TARGET=13.0 swiftc -swift-version 5 -O -module-cache-path "$PWD/.build/module-cache" Sources/*.swift Adapters/ChatGPT/DesktopChoices.swift -o "$app/Contents/MacOS/SessionCompanion"
cp Resources/watchnotch.icns "$app/Contents/Resources/watchnotch.icns"
cp docs/media/owl-small.png "$app/Contents/Resources/watching-owl.png"
cp Info.plist "$app/Contents/Info.plist"
cp Adapters/Codex/requests_bridge.py "$app/Contents/Resources/requests_bridge.py"
cp Adapters/Codex/monitor.py "$app/Contents/Resources/monitor.py"
cp Adapters/ChatGPT/library.py "$app/Contents/Resources/library.py"
codesign --force --options runtime --sign - "$app"
echo "$app"
