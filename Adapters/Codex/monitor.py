#!/usr/bin/env python3
"""Publish a single user-selected Codex thread through the local App Server."""
import argparse
import base64
import hashlib
from contextlib import contextmanager
from datetime import datetime, timezone
import fcntl
import json
import os
from pathlib import Path
import socket
import struct
import signal
import sys
import tempfile
import time
import uuid


def thread_id(value):
    prefix = "codex://threads/"
    key = value[len(prefix):] if value.startswith(prefix) else value
    try:
        return str(uuid.UUID(key))
    except ValueError:
        raise argparse.ArgumentTypeError("Enter a Codex thread UUID or codex://threads/UUID link.")


def default_directory():
    return Path(os.environ.get("NOTCH_SESSION_DIR") or
                Path.home() / "Library/Application Support/Mac Notch Session Companion/Sessions")


def default_socket():
    config = Path(os.environ.get("CODEX_HOME") or Path.home() / ".codex")
    return config / "app-server-control/app-server-control.sock"


class Server:
    """JSON-RPC over the local Codex Unix WebSocket control endpoint."""
    def __init__(self, path=None):
        self.path = path or default_socket()

    def __enter__(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(8)
        self.reader = self.sock.makefile("rb")
        self.next_id = 1
        try:
            self.sock.connect(str(self.path))
            nonce = base64.b64encode(os.urandom(16)).decode()
            self.sock.sendall(("GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\n"
                "Connection: Upgrade\r\nSec-WebSocket-Version: 13\r\n"
                f"Sec-WebSocket-Key: {nonce}\r\n\r\n").encode())
            status_line = self.reader.readline(1024)
            if status_line.split()[1:2] != [b"101"]:
                raise ConnectionError("The Codex socket declined the WebSocket connection.")
            headers = {}
            for _ in range(64):
                line = self.reader.readline(8192)
                if line == b"\r\n":
                    break
                name, _, value = line.partition(b":")
                headers[name.lower()] = value.strip()
            signature = nonce + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
            expected = base64.b64encode(hashlib.sha1(signature.encode()).digest())
            if headers.get(b"sec-websocket-accept") != expected:
                raise ConnectionError("Invalid WebSocket upgrade response.")
            self.call("initialize", {"clientInfo": {"name": "notch_companion",
                      "title": "Mac Notch Session Companion", "version": "1.0"}})
            self.send_frame(1, b'{"method":"initialized","params":{}}')
        except BaseException:
            self.__exit__(None, None, None)
            raise
        return self

    def __exit__(self, *args):
        self.reader.close()
        self.sock.close()

    def send_frame(self, opcode, payload):
        size = len(payload)
        if size < 126:
            length = bytes([0x80 | size])
        elif size <= 65535:
            length = b"\xfe" + struct.pack("!H", size)
        else:
            length = b"\xff" + struct.pack("!Q", size)
        mask = os.urandom(4)
        masked = bytes(byte ^ mask[i % 4] for i, byte in enumerate(payload))
        self.sock.sendall(bytes([0x80 | opcode]) + length + mask + masked)

    def read_exact(self, count):
        data = self.reader.read(count)
        if len(data) != count:
            raise ConnectionError("The Codex App Server connection closed.")
        return data

    def read_message(self):
        text = bytearray()
        while True:
            first, second = self.read_exact(2)
            opcode, size = first & 15, second & 127
            if second & 128 or first & 112:
                raise ValueError("Invalid server frame.")
            if size in (126, 127):
                size = int.from_bytes(self.read_exact(2 if size == 126 else 8), "big")
            if size + len(text) > 8 * 1024 * 1024:
                raise ValueError("Codex reply exceeded the size limit.")
            payload = self.read_exact(size)
            if opcode == 8:
                raise ConnectionError("The Codex server closed the connection.")
            if opcode == 9:
                self.send_frame(10, payload)
            elif opcode in (0, 1):
                text.extend(payload)
                if first & 128:
                    return json.loads(text)

    def call(self, method, params):
        key = self.next_id
        self.next_id += 1
        self.send_frame(1, json.dumps({"id": key, "method": method, "params": params}).encode())
        deadline = time.monotonic() + 12
        while time.monotonic() < deadline:
            message = self.read_message()
            if message.get("id") == key and "method" not in message:
                if "error" in message:
                    raise RuntimeError(f"{method} failed (RPC {message['error'].get('code')}).")
                return message["result"]
        raise TimeoutError(f"{method} timed out.")


def status(thread):
    runtime = thread["status"]
    flags = runtime.get("activeFlags", [])
    if runtime["type"] == "active":
        if "waitingOnApproval" in flags:
            return "needsInput", "Codex needs you to review an approval in the original session."
        if "waitingOnUserInput" in flags:
            return "needsInput", "Codex is waiting for your answer in the original session."
        return "running", "Codex is working on the current turn."
    if runtime["type"] == "idle":
        return "ready", "Codex is ready for your next message."
    if runtime["type"] == "systemError":
        return "unavailable", "Codex reported a session error."
    return "unavailable", "This server has no live status for the session."


def last_turn_status(server, key):
    try:
        turns = server.call("thread/turns/list", {"threadId": key, "limit": 1,
                            "sortDirection": "desc", "itemsView": "notLoaded"})["data"]
    except RuntimeError:
        # Ephemeral sessions and older servers can lack persisted turn metadata.
        return None
    return turns[0]["status"] if turns else None


def read_snapshot(server, key, link=None):
    try:
        thread = server.call("thread/read", {"threadId": key, "includeTurns": False})["thread"]
    except RuntimeError as error:
        raise RuntimeError(f"The local Codex daemon could not read this thread ({error}).") from error
    if thread["id"] != key:
        raise RuntimeError("Codex returned a different thread identity.")
    state, sentence = status(thread)
    runtime_type = thread["status"]["type"]
    if runtime_type in ("idle", "notLoaded"):
        last = last_turn_status(server, key)
        updates = {"completed": "The last Codex turn finished.",
                   "interrupted": "The last Codex turn was interrupted.",
                   "failed": "The last Codex turn ended with an error."}
        if last in updates:
            sentence = updates[last]
            if last == "failed":
                state = "unavailable"
    result = {"provider": "Codex", "sessionID": key, "title": thread.get("name") or "Codex session",
              "state": state, "sentence": sentence}
    if link:
        result["sessionURL"] = link
    return result


def publish(path, snapshot):
    snapshot = dict(snapshot, updatedAt=datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))
    with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, delete=False) as f:
        try:
            json.dump(snapshot, f)
            f.flush()
            os.replace(f.name, path)
        finally:
            Path(f.name).unlink(missing_ok=True)


@contextmanager
def session_lock(path):
    with open(path.with_suffix(".lock"), "a") as handle:
        try:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RuntimeError("Another monitor is already watching this thread.")
        yield


def watch(key, link, socket, directory):
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    path = directory / f"codex-{key}.json"
    previous = None
    with session_lock(path):
        try:
            while True:
                try:
                    with Server(socket) as server:
                        while True:
                            current = read_snapshot(server, key, link)
                            if current != previous:
                                publish(path, current)
                                previous = current
                            time.sleep(1.5)
                except (RuntimeError, OSError, ValueError) as error:
                    if previous is None:
                        raise
                    offline = dict(previous, state="unavailable")
                    if offline != previous:
                        publish(path, offline)
                        previous = offline
                    print(f"Codex connection unavailable: {error}", file=sys.stderr, flush=True)
                    time.sleep(3)
        finally:
            if previous and previous["state"] != "unavailable":
                publish(path, dict(previous, state="unavailable"))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("session", help="Desktop thread link or UUID")
    parser.add_argument("--socket", type=Path, help="Optional App Server control socket")
    args = parser.parse_args()
    try:
        key = thread_id(args.session)
    except argparse.ArgumentTypeError as error:
        parser.error(str(error))
    link = "codex://threads/" + key if args.session.startswith("codex://threads/") else None
    def stop(signum, frame):
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, stop)
    try:
        watch(key, link, args.socket, default_directory())
    except KeyboardInterrupt:
        return 0
    except FileNotFoundError:
        print("The Codex control socket is missing. Start the local Codex daemon.", file=sys.stderr)
        return 1
    except (RuntimeError, OSError, ValueError) as error:
        print(str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
