"""Codex App Server connection, replies and progress for the Windows companion."""
from contextlib import closing
import sqlite3
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


class RPCRejected(RuntimeError):
    pass


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
                    raise RPCRejected(f"{method} failed (RPC {message['error'].get('code')}).")
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
    if limit is not None and len(text) > limit:
        text = (text[:limit - 1].rsplit(" ", 1)[0] or text[:limit - 1]).rstrip(".,;:") + "…"
    return text


# Pick one complete, user-visible thought. A tool result, a prompt, or a code excerpt
# is never a source for prose on the tile.
ACK = r"(?:yes|no|ok(?:ay)?|sure|absolutely|certainly|done|great|got it|of course|you['’]re right|good (?:question|point)|thanks(?: for (?:asking|the context))?)"
FILLER = re.compile(r"(?:summary|result|what changed|here['’]s (?:the gist|what (?:I|we) found)|(?:let me|I['’]ll) (?:check|take a look|look into (?:it|that))|(?:I['’]m |I am )?(?:working on (?:it|that)|on it)|more (?:details?|information)(?: follows?)?|here you go)[.!:]?", re.I)
IMPLEMENTATION = re.compile(
    r"(?:`|(?:^|\s)[~/][^\s]+|\b[\w-]+\.(?:py|swift|tsx?|jsx?|json|ya?ml|sh|sql|rs|cpp)\b|"
    r"\b\w+_\w+\b|\b[a-z][a-z0-9]+[A-Z][a-z]\w*\b|\w+\(\)|"
    r"\b(?i:git (?:diff|status|push)|shlex|stdout|stderr|RPC|JSONL|SQLite|tool call)\b)")
MILESTONE = re.compile(r"\b(?:you can|you['’]ll|now|ready|works?|fixed|restored|available|finished|complete[d]?|verified|confirmed|passed|resolved|found|needs?|waiting|blocked|still|depends on|couldn['’]t|failed|missing)\b", re.I)


def message_gist(value):
    visible = re.sub(r"```.*?(?:```|$)", " ", value or "", flags=re.S)
    best, best_rank = "", -1
    for raw in visible.splitlines():
        line = re.sub(r"^\s*(?:[-+*•]\s+|\d+[.)]\s+)", "", raw).strip()
        if not line or line.startswith(("#", ">")) or line.endswith(":"):
            continue
        # Link labels can describe a result; their targets do not belong in the summary.
        line = re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", line)
        for clause in re.split(r"(?<=[.!?])\s+", line):
            if IMPLEMENTATION.search(clause) or re.search(r"https?://|(?:sk-|ghp_|github_pat_)[A-Za-z0-9_-]{10,}", clause, re.I):
                continue
            clause = short_text(clause, None)
            if re.fullmatch(ACK + r"[.!?]*", clause, re.I):
                continue
            clause = re.sub(r"^(?!no\b)" + ACK + r"\s*[,!:—–-]\s*", "", clause, flags=re.I)
            if (len(clause.split()) < 3 or len(clause) > 360 or FILLER.fullmatch(clause)
                    or re.match(r"^(?:if you (?:want|like)|would you like me to)\b", clause, re.I)):
                continue
            sentence = clause[:1].upper() + clause[1:]
            if re.search(r"\b(?:you can now|you can once again|you can already|is now|are now|now (?:works?|shows?|stays?|keeps?)|before (?:I|we|work) can continue|waiting for your|still blocked|ready to (?:use|open|review|try))\b", sentence, re.I):
                rank = 2
            else:
                rank = int(bool(MILESTONE.search(sentence)))
            if rank > best_rank:
                best, best_rank = sentence, rank
    return best


def command_activity(item):
    """Return whether a signal deserves priority over a routine step, and its sentence."""
    state = item.get("status")
    if state not in ("inProgress", "completed", "failed", "declined"):
        return False, ""
    if state == "declined":
        return True, "This step was skipped because permission was declined"
    try:
        parts = shlex.split(item.get("command") or "")
        if len(parts) >= 3 and Path(parts[0]).name in ("sh", "bash", "zsh") and "c" in parts[1]:
            parts = shlex.split(parts[2])
    except ValueError:
        parts = []
    program = Path(parts[0]).name if parts else ""
    args = parts[1:]
    # Only recognize the program doing the work; arbitrary arguments may mention a test or a build.
    check = (program in ("pytest", "test.sh", "verify.py") or
             (program in ("python", "python3") and args[:2] in (["-m", "unittest"], ["-m", "pytest"])) or
             (program in ("npm", "swift", "cargo", "go", "yarn", "pnpm") and args[:1] == ["test"]))
    build = (program in ("build.sh", "swiftc", "xcodebuild") or
             (program in ("swift", "cargo") and args[:1] == ["build"]) or
             (program == "npm" and args[:2] == ["run", "build"]))
    failed = state == "failed" or (state == "completed" and item.get("exitCode") not in (None, 0))
    if check or build:
        if failed:
            return True, "A check found a problem with the changes" if check else "The new version could not be built"
        if state == "inProgress":
            return True, "I’m checking whether the changes work as expected" if check else "I’m preparing a new version"
        if item.get("exitCode") == 0:
            return True, "The changes passed this check" if check else "The new version built successfully"
        return True, "The check has ended" if check else "The build step has ended"
    if failed:
        return True, "One step could not finish"
    if program == "git" and args[:1] in (["diff"], ["status"]):
        return False, "I’m reviewing what changed" if state == "inProgress" else "I reviewed the latest changes"
    if any(a.get("type") in ("read", "listFiles", "search") for a in item.get("commandActions") or []):
        return False, "I’m looking through the project for relevant details" if state == "inProgress" else "I checked the project for relevant details"
    return False, ""


def ranked_activity(item):
    kind = item.get("type")
    if kind == "agentMessage":
        moderation = item.get("moderation") or {}
        if moderation.get("moderated") or (moderation.get("display") or {}).get("mode") in ("block", "hide"):
            return False, ""
        return True, message_gist(item.get("text"))
    if kind == "commandExecution":
        return command_activity(item)
    if kind == "fileChange" and item.get("changes"):
        return item.get("status") in ("failed", "declined"), {"inProgress": "I’m making changes to the project", "completed": "The project changes have been saved",
                "failed": "The project changes could not be saved", "declined": "The proposed changes were declined"}.get(item.get("status"), "")
    if kind == "plan":
        return True, message_gist(item.get("text"))
    if kind == "webSearch":
        return False, "I’m looking for information to support the answer"
    return False, ""


def activity(item):
    return ranked_activity(item)[1]


def recent_progress(server, key, cache):
    turn = None
    try:
        turns = server.call("thread/turns/list", {"threadId": key, "limit": 1,
                            "sortDirection": "desc", "itemsView": "notLoaded"})["data"]
        if not turns:
            return None, ""
        turn = turns[0]
        cache_key = (turn["id"], turn["status"])
        page = server.call("thread/items/list", {"threadId": key, "turnId": turn["id"], "limit": 12,
                           "sortDirection": "desc", "deferOutput": {}})
    except RuntimeError:
        return (turn["status"], cache.get(cache_key, "")) if turn else (None, "")
    items = [entry.get("item") or {} for entry in page["data"] if entry.get("turnId") == turn["id"]]
    completed = turn["status"] == "completed"
    if completed:
        items.sort(key=lambda item: item.get("type") == "agentMessage" and item.get("phase") == "final_answer", reverse=True)
    fallback = ""
    for item in items:
        kind = item.get("type")
        if completed and (kind in ("webSearch", "plan") or item.get("phase") == "commentary" or item.get("status") == "inProgress"):
            continue
        important, line = ranked_activity(item)
        if not line:
            continue
        if not fallback:
            fallback = line
        # A specific visible update or verification result carries more meaning than
        # routine file reads. Stay within the recent activity of this exact turn.
        if important:
            fallback = line
            break
    if fallback:
        cache.clear()
        cache[cache_key] = fallback
    return turn["status"], cache.get(cache_key, "")


def read_snapshot(server, key, link=None, cache=None):
    try:
        thread = server.call("thread/read", {"threadId": key, "includeTurns": False})["thread"]
    except RuntimeError as error:
        raise RuntimeError(f"The local Codex daemon could not read this thread ({error}).") from error
    if thread["id"] != key:
        raise RuntimeError("Codex returned a different thread identity.")
    state, sentence = status(thread)
    title = short_text(thread.get("name"), None) or "Codex session"
    last, line = recent_progress(server, key, cache if cache is not None else {})
    if state == "needsInput":
        if "waitingOnApproval" in thread["status"].get("activeFlags", []):
            sentence = "Your approval is needed before work can continue"
        else:
            sentence = line if last == "inProgress" and line.endswith("?") else "Your answer is needed before work can continue"
    elif state == "running":
        sentence = line if last == "inProgress" and line else "Work is underway on your request"
    elif thread["status"]["type"] in ("idle", "notLoaded"):
        if last == "failed":
            state, sentence = "unavailable", "The work stopped before the request was finished"
        elif last == "interrupted":
            sentence = "The work was interrupted before this step finished"
        elif last == "completed":
            sentence = line or "Work on this request has finished"
    if sentence[-1:] not in ".!?…":
        sentence += "."
    result = {"provider": "Codex", "sessionID": key, "title": title,
              "state": state, "sentence": sentence}
    result["details"] = {"model": thread.get("model"), "effort": thread.get("reasoningEffort")}
    if link:
        result["sessionURL"] = link
    return result


BRANCH_SOURCES = ["cli", "vscode", "appServer", "exec", "subAgent", "subAgentThreadSpawn", "unknown"]


def pages(server, method, params):
    params = dict(params)
    cursors = set()
    while True:
        page = server.call(method, params)
        yield page["data"]
        cursor = page.get("nextCursor")
        if not cursor or cursor in cursors:
            return
        cursors.add(cursor)
        params["cursor"] = cursor


def attached_children(parents, directory=None):
    # The daemon can omit attached workers from thread/list, even while they are running.
    root = directory or Path(os.environ.get("CODEX_HOME") or Path.home() / ".codex")
    try:
        with closing(sqlite3.connect((root / "state_5.sqlite").as_uri() + "?mode=ro", uri=True, timeout=0.1)) as db:
            db.execute("PRAGMA trusted_schema=OFF")
            return {row[0] for parent in parents for row in db.execute(
                "SELECT child_thread_id FROM thread_spawn_edges WHERE parent_thread_id = ?", (parent,))}
    except (sqlite3.Error, ValueError):
        return set()


def spawn_metadata(thread):
    source = thread.get("source")
    sub = source.get("subAgent") if isinstance(source, dict) else None
    return sub.get("thread_spawn") if isinstance(sub, dict) else None


def branch_row(thread, parent, kind, title):
    child = str(uuid.UUID(thread["id"]))
    state = status(thread)[0] if thread.get("status") else "unavailable"
    return {"provider": "Codex", "sessionID": child, "parentID": parent, "branchKind": kind,
            "title": " ".join(title.split())[:120], "updated": thread.get("updatedAt") or 0, "state": state}


def branch_items(server, parents, include_forks=True, directory=None):
    params = {"currentAccountOnly": True, "limit": 100, "sourceKinds": BRANCH_SOURCES}
    selected = server.call("thread/list", dict(params, includedThreadIds=sorted(parents)))["data"]
    parents = parents.intersection(row["id"] for row in selected)
    if not parents:
        return []
    attached = attached_children(parents, directory)
    found = {}
    for loaded in pages(server, "thread/loaded/list", {"limit": 100}):
        if not loaded:
            continue
        listed = server.call("thread/list", dict(params, includedThreadIds=loaded))["data"]
        candidates = attached.intersection(loaded)
        for row in listed:
            spawn = spawn_metadata(row)
            if row.get("parentThreadId") in parents or isinstance(spawn, dict) and spawn.get("parent_thread_id") in parents:
                candidates.add(row["id"])
        for child in candidates:
            try:
                thread = server.call("thread/read", {"threadId": child, "includeTurns": False})["thread"]
            except RPCRejected:
                continue  # The worker may finish between listing and reading it.
            spawn = spawn_metadata(thread)
            if thread["id"] != child or not isinstance(spawn, dict):
                continue
            parent = thread.get("parentThreadId") or spawn.get("parent_thread_id")
            if parent not in parents or child == parent or (thread.get("status") or {}).get("type") != "active":
                continue
            path = (spawn.get("agent_path") or "").rstrip("/").rsplit("/", 1)[-1]
            label = thread.get("name") or path.replace("_", " ").replace("-", " ") or thread.get("agentRole") or "Subagent"
            found[parent, child] = branch_row(thread, parent, "Subagent", label)
    if include_forks:
        for rows in pages(server, "thread/list", params):
            for thread in rows:
                parent = thread.get("forkedFromId")
                source = thread.get("source")
                if (parent not in parents or parent == thread["id"] or thread.get("parentThreadId")
                        or (isinstance(source, dict) and "subAgent" in source)):
                    continue
                found[parent, thread["id"]] = branch_row(thread, parent, "Fork", thread.get("name") or "Fork")
    return sorted(found.values(), key=lambda r: (r["state"] in ("needsInput", "running"), r["updated"]), reverse=True)


def send_reply(server, key, text):
    if not text.strip() or len(text.encode("utf-8")) > 65536:
        return "invalid"
    thread = server.call("thread/read", {"threadId": key, "includeTurns": False})["thread"]
    if thread.get("id") != key or status(thread)[0] not in ("ready", "running"):
        return "openSession"
    try:
        result = server.call("turn/start", {"threadId": key, "input": [{"type": "text", "text": text}]})
        return "sent" if (result.get("turn") or {}).get("id") else "uncertain"
    except RPCRejected:
        return "rejected"
    except (OSError, RuntimeError, ValueError, EOFError, KeyError):
        # Delivery may have succeeded before the connection closed. Never replay automatically.
        return "uncertain"


def library_page(server, cursor=None, loaded=False):
    params = {"limit": 60, "currentAccountOnly": True}
    if cursor:
        params["cursor"] = cursor
    if loaded:
        ids = server.call("thread/loaded/list", {"limit": 100, "cursor": cursor})
        rows = server.call("thread/list", {"currentAccountOnly": True, "limit": 100,
                           "includedThreadIds": ids["data"]})["data"] if ids["data"] else []
        page = {"data": rows, "nextCursor": ids.get("nextCursor")}
    else:
        page = server.call("thread/list", params)
    items = []
    for row in page["data"]:
        key = str(uuid.UUID(row["id"]))
        title = " ".join((row.get("name") or "").split())[:120]
        items.append({"provider": "Codex", "sessionID": key, "title": title or "Thread " + key[:8],
                      "updated": row.get("updatedAt") or 0, "state": status(row)[0] if row.get("status") else None})
    return {"items": items, "next": page.get("nextCursor")}
