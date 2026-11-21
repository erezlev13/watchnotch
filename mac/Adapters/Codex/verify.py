#!/usr/bin/env python3
"""Verify observation across independent local App Server clients without a model call."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

from monitor import Server, read_snapshot

BASE = Path(__file__).resolve().parent


def await_state(path, state):
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline:
        if path.exists():
            data = json.loads(path.read_text())
            if data["state"] == state:
                assert "request" not in data
                return data
        time.sleep(.2)
    raise RuntimeError(f"Timed out waiting for {state}.")


def main():
    with tempfile.TemporaryDirectory() as sandbox, Server() as owner:
        key = owner.call("thread/start", {"ephemeral": True, "cwd": sandbox,
                         "approvalPolicy": "never", "sandbox": "read-only"})["thread"]["id"]
        with Server() as observer:
            assert read_snapshot(observer, key)["state"] == "ready"
        print("Two connections read the same ephemeral Codex thread.", flush=True)
        path = Path(sandbox) / f"codex-{key}.json"
        env = dict(os.environ, NOTCH_SESSION_DIR=sandbox, PYTHONDONTWRITEBYTECODE="1")
        child = subprocess.Popen([sys.executable, str(BASE / "monitor.py"), key], env=env)
        try:
            await_state(path, "ready")
            # This user-shell action is deliberately constant and takes no external input.
            # It uses a real Codex turn and requires neither an LLM nor a network request.
            owner.call("thread/shellCommand", {"threadId": key, "command": "/bin/sleep 5"})
            await_state(path, "running")
            completed = await_state(path, "ready")
            stable = path.read_bytes()
            time.sleep(2)
            assert stable == path.read_bytes()
            print("Monitor saw ready → running → ready, then left a quiet card unchanged.")
        finally:
            child.terminate()
            child.wait(timeout=5)
        offline = await_state(path, "unavailable")
        assert offline["sentence"] == completed["sentence"]
        print("Disconnect kept the thread's status sentence and marked it unavailable.")
        child = subprocess.Popen([sys.executable, str(BASE / "monitor.py"), key], env=env)
        try:
            assert await_state(path, "ready")["sessionID"] == key
            print("Restart restored the same thread identity and current state.")
        finally:
            child.terminate()
            child.wait(timeout=5)


if __name__ == "__main__":
    main()
