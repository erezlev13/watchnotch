"""Return only local ChatGPT conversation titles, IDs and dates to the session picker."""
from contextlib import closing
import io
import json
from pathlib import Path
import re
import sqlite3
from urllib.parse import urlsplit
from uuid import UUID
import zipfile

MAX_EXPORT_BYTES = 1024 * 1024 * 1024
MAX_RECORD_CHARS = 32 * 1024 * 1024
EXPORT_NAME = re.compile(r"conversations(?:[-_]\d+)?\.json$", re.I)


def item(identifier, title, updated):
    try:
        key = str(UUID(str(identifier)))
    except ValueError:
        return None
    name = " ".join(str(title or "").split())
    name = "".join(c for c in name if c.isprintable())[:120]
    return {"provider": "ChatGPT", "sessionID": key, "title": name or "Chat " + key[:8],
            "updated": float(updated) if isinstance(updated, (int, float)) else 0}


def conversations(stream):
    # Decode one conversation at a time. A large account export need not fit in memory.
    decoder = json.JSONDecoder()
    buf = ""
    def refill():
        nonlocal buf
        part = stream.read(128 * 1024)
        buf += part
        return bool(part)

    def trim():
        nonlocal buf
        buf = buf.lstrip()
        while not buf and refill():
            buf = buf.lstrip()

    trim()
    if not buf.startswith("["):
        raise ValueError("Expected a conversation array")
    buf = buf[1:]
    trim()
    if buf.startswith("]"):
        return
    while True:
        try:
            row, end = decoder.raw_decode(buf)
        except json.JSONDecodeError:
            if len(buf) >= MAX_RECORD_CHARS or not refill():
                raise ValueError("Invalid or oversized conversation")
            continue
        if isinstance(row, dict):
            result = item(row.get("id") or row.get("conversation_id"), row.get("title"), row.get("update_time"))
            if result:
                yield result
        del row
        buf = buf[end:]
        trim()
        if buf.startswith("]"):
            return
        if not buf.startswith(","):
            raise ValueError("Invalid conversation array")
        buf = buf[1:]
        trim()


def from_export(path):
    if path.suffix.lower() != ".zip":
        if path.stat().st_size > MAX_EXPORT_BYTES:
            raise ValueError("Export too large")
        with path.open(encoding="utf-8-sig") as stream:
            yield from conversations(stream)
        return
    with zipfile.ZipFile(path) as archive:
        members = [m for m in archive.infolist() if EXPORT_NAME.fullmatch(Path(m.filename).name)
                   and "codex" not in [p.lower() for p in Path(m.filename).parts]]
        if not members or sum(m.file_size for m in members) > MAX_EXPORT_BYTES:
            raise ValueError("Missing or oversized conversation JSON")
        for member in members:
            with archive.open(member) as data, io.TextIOWrapper(data, encoding="utf-8-sig") as stream:
                yield from conversations(stream)


def desktop_items(directory):
    path = directory / "sqlite" / "codex.db"
    if not path.is_file():
        return
    # The current desktop catalog contains both Codex work and ChatGPT chats.
    # Read only the conversation index, never message bodies or account credentials.
    with closing(sqlite3.connect(path.resolve().as_uri() + "?mode=ro", uri=True, timeout=1)) as db:
        db.execute("PRAGMA trusted_schema=OFF")
        query = """SELECT thread_id, display_title, source_updated_at
                   FROM local_thread_catalog
                   WHERE source_kind = 'chatgpt' AND missing_candidate = 0"""
        for identifier, title, updated in db.execute(query):
            normalized = item(identifier, title, updated)
            if normalized:
                yield normalized


def windows_browser_items(local, roaming):
    queries = []
    for vendor in ("Google/Chrome", "Microsoft/Edge", "BraveSoftware/Brave-Browser", "Chromium"):
        for path in (local / vendor / "User Data").glob("*/History"):
            queries.append((path, "SELECT url, title, last_visit_time / 1000000 - 11644473600 FROM urls"))
    for path in (roaming / "Mozilla/Firefox/Profiles").glob("*/places.sqlite"):
        queries.append((path, "SELECT url, title, last_visit_date / 1000000 FROM moz_places"))
    yield from query_history(queries)


def query_history(queries):
    for path, query in queries:
        try:
            with closing(sqlite3.connect(path.as_uri() + "?mode=ro", uri=True, timeout=0.5)) as db:
                db.execute("PRAGMA trusted_schema=OFF")
                patterns = [f"https://{host}/{route}" for host in ("chatgpt.com", "chat.openai.com")
                                for route in ("c/%", "g/%/c/%")]
                where = " OR ".join("url LIKE ?" for _ in patterns)
                for url, name, date in db.execute(query + " WHERE " + where, patterns):
                    parts = urlsplit(url)
                    match = re.fullmatch(r"/(?:g/[^/]+/)?c/([a-fA-F0-9-]{36})/?", parts.path)
                    if parts.netloc.lower() in ("chatgpt.com", "chat.openai.com") and match:
                        result = item(match.group(1), name, date)
                        if result:
                            yield result
        except (OSError, sqlite3.Error):
            continue
