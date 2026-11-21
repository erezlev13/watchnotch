#!/usr/bin/env python3
"""Exercise the packaged app against a real synthetic Codex turn and save its panel."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

project = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(project / "Adapters/Codex"))
sys.path.insert(0, str(project / "Adapters/ChatGPT"))
from monitor import Server
from register import register

app = project / ".build/watchnotch.app/Contents/MacOS/SessionCompanion"
five = "--five" in sys.argv
preview = project / ("Demo/five-sessions.png" if five else "Demo/mixed-sessions.png")
with tempfile.TemporaryDirectory() as workspace, Server() as owner:
    root = Path(workspace)
    directory = root / "Sessions"
    key = owner.call("thread/start", {"ephemeral": True, "cwd": workspace,
                     "approvalPolicy": "never", "sandbox": "read-only"})["thread"]["id"]
    chat = "20c1c6ed-e513-4e5e-bc99-a03f899fd34d"
    register("https://chatgpt.com/c/" + chat, "Sample research conversation", directory)
    watch = {"origin": "adapter", "provider": "Codex", "sessionID": key}
    pins = [watch, {"origin": "adapter", "provider": "ChatGPT", "sessionID": chat},
            {"origin": "fixture", "provider": "Codex", "sessionID": "demo-0"}]
    if five:
        pins += [{"origin": "fixture", "provider": "ChatGPT", "sessionID": "demo-1"},
                 {"origin": "fixture", "provider": "ChatGPT", "sessionID": "demo-2"}]
    (root / "selection.json").write_text(json.dumps({"pins": pins, "watches": [watch], "lastKnown": []}))
    owner.call("thread/shellCommand", {"threadId": key, "command": "/bin/sleep 10"})
    env = dict(os.environ, NOTCH_DATA_DIR=workspace, NOTCH_SESSION_DIR=str(directory),
               NOTCH_CAPTURE_PATH=str(preview), PYTHONDONTWRITEBYTECODE="1")
    proc = subprocess.Popen([str(app)], env=env)
    snapshot = directory / ("codex-" + key + ".json")
    try:
        deadline = time.monotonic() + 12
        while time.monotonic() < deadline:
            if snapshot.exists() and json.loads(snapshot.read_text())["state"] == "running":
                break
            time.sleep(.1)
        else:
            raise RuntimeError("Packaged monitor did not publish the live running state")
        if proc.wait(timeout=12) != 0 or not preview.exists():
            raise RuntimeError("Panel capture failed")
        print("PASS  Packaged monitor observed the live Codex turn; mixed panel captured at", preview)
    finally:
        if proc.poll() is None:
            proc.terminate()
            proc.wait(timeout=5)
