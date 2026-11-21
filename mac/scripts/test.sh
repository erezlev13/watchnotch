#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/module-cache
swiftc -swift-version 5 -module-cache-path "$PWD/.build/module-cache" Sources/Session.swift Sources/SessionJump.swift Sources/Store.swift Adapters/ChatGPT/DesktopChoices.swift Tests/main.swift -o .build/store-tests
.build/store-tests
swiftc -swift-version 5 -module-cache-path "$PWD/.build/module-cache" Sources/Session.swift Sources/SessionJump.swift Adapters/ChatGPT/DesktopChoices.swift Adapters/ChatGPT/Tests/DesktopChoices/main.swift -o .build/desktop-choices-tests
.build/desktop-choices-tests
swiftc -swift-version 5 -module-cache-path "$PWD/.build/module-cache" Sources/StatusScript.swift Tests/StatusScript/main.swift -o .build/status-script-tests
.build/status-script-tests
swiftc -swift-version 5 -module-cache-path "$PWD/.build/module-cache" Sources/Session.swift Sources/SessionJump.swift Sources/DesktopChatReply.swift Sources/TileReply.swift Tests/DesktopChatReply/main.swift -o .build/desktop-chat-reply-tests
.build/desktop-chat-reply-tests
PYTHONDONTWRITEBYTECODE=1 /usr/bin/python3 -m unittest discover -s Adapters/ChatGPT -p 'test_*.py'
PYTHONDONTWRITEBYTECODE=1 /usr/bin/python3 -m unittest discover -s Adapters/Codex -p 'test_*.py'
