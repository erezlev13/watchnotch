"""Session library and read-only Codex connection for the Windows companion."""
from contextlib import contextmanager
from dataclasses import asdict, dataclass, field
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import threading
from urllib.parse import urlsplit
from uuid import UUID

from adapters.codex_client import Client, library_page, read_snapshot

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "shared"))
from account_usage import read_usage


@dataclass(frozen=True)
class Session:
    provider: str
    sessionID: str
    title: str
    updated: float = 0

    def __post_init__(self):
        if self.provider not in ("Codex", "ChatGPT"):
            raise ValueError("Unknown session provider.")
        object.__setattr__(self, "sessionID", str(UUID(self.sessionID)))
        title = " ".join(str(self.title or "").split())
        object.__setattr__(self, "title", "".join(c for c in title if c.isprintable())[:120]
                           or self.provider + " " + self.sessionID[:8])

    @property
    def key(self):
        return self.provider, self.sessionID

    @property
    def url(self):
        prefix = "codex://threads/" if self.provider == "Codex" else "https://chatgpt.com/c/"
        return prefix + self.sessionID


def from_link(text, title):
    value = text.strip()
    if value.startswith("https://"):
        url = urlsplit(value)
        match = re.fullmatch(r"/c/([0-9a-fA-F-]{36})/?", url.path)
        if url.netloc.lower() != "chatgpt.com" or not match:
            raise ValueError("Enter a private https://chatgpt.com/c/<UUID> conversation link.")
        return Session("ChatGPT", match[1], title)
    try:
        return Session("Codex", value.removeprefix("codex://threads/"), title)
    except ValueError as error:
        raise ValueError("Enter a Codex thread UUID, desktop thread link, or private ChatGPT link.") from error


@dataclass
class Library:
    pins: list = field(default_factory=list)
    chats: dict = field(default_factory=dict)

    def import_chats(self, rows):
        for row in rows:
            session = Session(**row)
            old = self.chats.get(session.key)
            if old is None or session.updated >= old.updated:
                self.chats[session.key] = session

    def pin(self, session):
        for i, old in enumerate(self.pins):
            if old.key == session.key:
                self.pins[i] = session
                return
        self.pins.append(session)

    @classmethod
    def load(cls, path):
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except FileNotFoundError:
            return cls()
        library = cls()
        library.import_chats(data["chats"])
        for row in data["pins"]:
            library.pin(Session(**row))
        return library

    def save(self, path):
        path.parent.mkdir(parents=True, exist_ok=True)
        data = {"pins": [asdict(p) for p in self.pins], "chats": [asdict(c) for c in self.chats.values()]}
        temp = None
        try:
            with tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=path.parent, delete=False) as f:
                temp = Path(f.name)
                json.dump(data, f, allow_nan=False)
            os.replace(temp, path)
        finally:
            if temp is not None:
                temp.unlink(missing_ok=True)


def codex_executable():
    home = Path(os.environ.get("CODEX_HOME") or Path.home() / ".codex")
    standalone = home / "packages/standalone/current/bin/codex.exe"
    if standalone.is_file():
        return str(standalone.resolve())
    # Search explicit, absolute PATH entries only. Never launch a shell shim.
    for directory in os.get_exec_path():
        if Path(directory).is_absolute():
            path = Path(directory) / "codex.exe"
            if path.is_file():
                return str(path)
    raise FileNotFoundError("A native installation of codex.exe is required.")


@contextmanager
def connection(executable=None):
    """The official proxy relays raw WebSocket bytes to the existing user's daemon."""
    process = subprocess.Popen([executable or codex_executable(), "app-server", "proxy"],
                               stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                               bufsize=-1, creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
    # Bound each exchange, including a stalled HTTP upgrade or partial frame.
    timeout = None
    def send(data):
        nonlocal timeout
        if timeout is not None:
            timeout.cancel()
        timeout = threading.Timer(18, process.kill)
        timeout.daemon = True
        timeout.start()
        process.stdin.write(data)
        process.stdin.flush()
    try:
        client = Client()
        client.reader = process.stdout
        client.send_bytes = send
        client.initialize()
        yield client
    finally:
        if timeout is not None:
            timeout.cancel()
        process.kill()
        process.wait()
        try:
            process.stdin.close()
        except OSError:
            pass
        process.stdout.close()


def account_usage():
    try:
        with connection() as server:
            return read_usage(server)
    except (OSError, RuntimeError, ValueError):
        return []


def codex_library():
    rows, seen = {}, set()
    cursor = None
    while True:
        with connection() as server:
            page = library_page(server, cursor)
        for row in page["items"]:
            session = Session(**row)
            rows[session.key] = session
        cursor = page["next"]
        if not cursor or cursor in seen:
            return rows
        seen.add(cursor)


def poll(pins, previous, cache, connect=connection):
    current = {}
    def offline(pin):
        prior = previous.get(pin.key, {})
        return {"title": prior.get("title", pin.title), "state": "unavailable",
                "sentence": prior.get("sentence", "Open Codex to check this thread.")}
    if pins:
        try:
            with connect() as server:
                for pin in pins:
                    try:
                        current[pin.key] = read_snapshot(server, pin.sessionID, cache=cache.setdefault(pin.key, {}))
                    except RuntimeError:
                        current[pin.key] = offline(pin)
        except (OSError, RuntimeError, ValueError, KeyError):
            for pin in pins:
                current.setdefault(pin.key, offline(pin))
    return current
