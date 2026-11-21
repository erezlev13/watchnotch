"""Read-only Codex App Server protocol and progress for the Windows companion."""
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import struct
import time
import uuid


class Client:
    def initialize(self):
        self.next_id = 1
        nonce = base64.b64encode(os.urandom(16)).decode()
        self.send_bytes(("GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\n"
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
                  "title": "watchnotch", "version": "1.0"}})
        self.send_frame(1, b'{"method":"initialized","params":{}}')

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
        self.send_bytes(bytes([0x80 | opcode]) + length + mask + masked)

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


def short_text(value, limit=148):
    # A glanceable excerpt from a visible message, without code blocks or link destinations.
    text = re.sub(r"```.*?(?:```|$)", " ", value or "", flags=re.S)
    text = re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", text)
    text = re.sub(r"https?://\S+|(?:sk-|ghp_|github_pat_)[A-Za-z0-9_-]{10,}", "…", text)
    text = " ".join(text.replace("*", "").replace("`", "").split()).strip("# -")
    if len(text) > limit:
        text = (text[:limit - 1].rsplit(" ", 1)[0] or text[:limit - 1]).rstrip(".,;:") + "…"
    return text


# Prefer a concrete clause over a greeting, an acknowledgement or a Markdown heading.
ACK = r"(?:yes|no|ok(?:ay)?|sure|absolutely|certainly|done|great|got it|of course|you're right|good (?:question|point)|thanks(?: for (?:asking|the context))?)"


def message_gist(value):
    visible = re.sub(r"```.*?(?:```|$)", " ", value or "", flags=re.S)
    for raw in visible.splitlines():
        line = re.sub(r"^\s*(?:[-+*•]\s+|\d+[.)]\s+)", "", raw).strip()
        if not line or line.startswith(("#", ">")) or line.endswith(":"):
            continue
        for clause in re.split(r"(?<=[.!?])\s+", line):
            clause = short_text(clause, 500)
            clause = re.sub(r"^" + ACK + r"(?:\s*[,!:—–-]\s*|[.!?]*$)", "", clause, flags=re.I)
            preamble = r"(?:summary|result|what changed|here.s (?:the gist|what (?:I|we) found)|(?:let me|I.ll) (?:check|take a look|look into (?:it|that))|(?:I.m |I am )?(?:working on (?:it|that)|on it))"
            if not clause or re.fullmatch(preamble + r"[.!:]?", clause, re.I):
                continue
            clause = re.sub(r"^(?:I(?:’|')m (?:currently )?|I am (?:currently )?)(?=\w+ing\b)", "", clause, flags=re.I)
            return short_text(clause[:1].upper() + clause[1:], 96)
    return ""


def command_activity(item):
    status = item.get("status")
    if status not in ("inProgress", "completed", "failed", "declined"):
        return ""
    active = status == "inProgress"
    if status == "declined":
        return "Command declined"
    if status == "failed" or (status == "completed" and item.get("exitCode") not in (None, 0)):
        return "Command failed"
    actions = item.get("commandActions") or []
    for action in actions:
        name = Path(action.get("path") or action.get("name") or "").name
        name = short_text(name, 54)
        if action.get("type") == "read" and name:
            return ("Reading " if active else "Read ") + name
        if action.get("type") == "listFiles" and name:
            return ("Listing files in " if active else "Listed files in ") + name
        if action.get("type") == "search" and name:
            return ("Searching " if active else "Searched ") + name
    try:
        parts = shlex.split(item.get("command") or "")
        if len(parts) >= 3 and Path(parts[0]).name in ("sh", "bash", "zsh") and "c" in parts[1]:
            parts = shlex.split(parts[2])
    except ValueError:
        return ""
    # Match command names and recognized subcommands. Arguments and output stay off the tile.
    words = [Path(p).name for p in parts[:4]]
    if any(w in ("test.sh", "pytest", "unittest", "test", "verify.py") for w in words):
        return "Running tests" if active else ("Tests passed" if status == "completed" and item.get("exitCode") == 0 else "The test command stopped")
    if any(w in ("build.sh", "swiftc", "xcodebuild") for w in words):
        return "Building the app" if active else ("The build succeeded" if status == "completed" and item.get("exitCode") == 0 else "The build stopped")
    if words[:2] == ["git", "diff"] or words[:2] == ["git", "status"]:
        return "Checking repository changes" if active else "Checked repository changes"
    return ""


def activity(item):
    kind = item.get("type")
    if kind == "agentMessage":
        moderation = item.get("moderation") or {}
        if moderation.get("moderated") or (moderation.get("display") or {}).get("mode") in ("block", "hide"):
            return ""
        return message_gist(item.get("text"))
    if kind == "commandExecution":
        return command_activity(item)
    if kind == "fileChange":
        names = [short_text(Path(c["path"]).name, 48) for c in item.get("changes", []) if c.get("path")]
        if names:
            target = names[0] + (" and " + str(len(names) - 1) + " more" if len(names) > 1 else "")
            verb = {"inProgress": "Editing ", "completed": "Updated ", "failed": "Couldn’t update ", "declined": "Skipped edits to "}.get(item.get("status"))
            return verb + target if verb else ""
    if kind == "plan":
        return message_gist(item.get("text"))
    if kind == "webSearch":
        return "Checking sources for " + (short_text(item.get("query"), 72) or "the current task")
    return ""


def recent_progress(server, key, cache):
    turn = None
    try:
        turns = server.call("thread/turns/list", {"threadId": key, "limit": 1,
                            "sortDirection": "desc", "itemsView": "notLoaded"})["data"]
        if not turns:
            return None, ""
        turn = turns[0]
        page = server.call("thread/items/list", {"threadId": key, "turnId": turn["id"], "limit": 12,
                           "sortDirection": "desc", "deferOutput": {}})
    except RuntimeError:
        # Older and ephemeral sessions may only provide thread-level status.
        return (turn["status"], cache.get(turn["id"], "")) if turn else (None, "")
    items = [entry.get("item") or {} for entry in page["data"] if entry.get("turnId") == turn["id"]]
    if turn["status"] == "completed":
        # The final response is authoritative even if a tool finishes after it.
        items.sort(key=lambda item: item.get("type") == "agentMessage" and item.get("phase") == "final_answer", reverse=True)
    for item in items:
        line = activity(item)
        if line:
            cache.clear()
            cache[turn["id"]] = line
            return turn["status"], line
    return turn["status"], cache.get(turn["id"], "")


def read_snapshot(server, key, link=None, cache=None):
    try:
        thread = server.call("thread/read", {"threadId": key, "includeTurns": False})["thread"]
    except RuntimeError as error:
        raise RuntimeError(f"The local Codex daemon could not read this thread ({error}).") from error
    if thread["id"] != key:
        raise RuntimeError("Codex returned a different thread identity.")
    state, sentence = status(thread)
    title = short_text(thread.get("name"), 110) or "Codex session"
    last, line = recent_progress(server, key, cache if cache is not None else {})
    if state == "needsInput":
        reason = "Approval needed" if "waitingOnApproval" in thread["status"].get("activeFlags", []) else "Your input is needed"
        sentence = reason + " — " + (line or title)
    elif state == "running":
        sentence = line if last == "inProgress" and line else "Working on “" + title + "”"
    elif thread["status"]["type"] in ("idle", "notLoaded"):
        if last == "failed":
            state, sentence = "unavailable", "Turn failed — " + (line or title)
        elif last == "interrupted":
            sentence = "Turn interrupted — " + (line or title)
        elif last == "completed":
            sentence = line or ("Finished · " + title)
    if sentence[-1:] not in ".!?…":
        sentence += "."
    result = {"provider": "Codex", "sessionID": key, "title": title,
              "state": state, "sentence": sentence}
    result["details"] = {"model": thread.get("model"), "effort": thread.get("reasoningEffort")}
    if link:
        result["sessionURL"] = link
    return result


def library_page(server, cursor=None):
    params = {"limit": 60, "currentAccountOnly": True}
    if cursor:
        params["cursor"] = cursor
    page = server.call("thread/list", params)
    items = []
    for row in page["data"]:
        key = str(uuid.UUID(row["id"]))
        title = " ".join((row.get("name") or "").split())[:120]
        items.append({"provider": "Codex", "sessionID": key, "title": title or "Thread " + key[:8],
                      "updated": row.get("updatedAt") or 0})
    return {"items": items, "next": page.get("nextCursor")}
