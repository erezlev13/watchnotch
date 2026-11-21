#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/module-cache
swiftc -swift-version 5 -module-cache-path "$PWD/.build/module-cache" Sources/Session.swift Sources/SessionJump.swift Sources/Store.swift Tests/main.swift -o .build/store-tests
.build/store-tests
PYTHONDONTWRITEBYTECODE=1 /usr/bin/python3 -m unittest discover -s Adapters/ChatGPT -p 'test_*.py'
