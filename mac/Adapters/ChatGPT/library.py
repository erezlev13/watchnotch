"""Return only local ChatGPT conversation titles, IDs and dates to the session picker."""
import argparse
from contextlib import closing
import io
import json
import os
from pathlib import Path
import re
import sqlite3
import sys
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


def desktop_items(directory, launched=None):
    path = directory / "sqlite" / "codex.db"
    if not path.is_file():
        return
    # The current desktop catalog contains both Codex work and ChatGPT chats.
    # Read only the conversation index, never message bodies or account credentials.
    with closing(sqlite3.connect(path.resolve().as_uri() + "?mode=ro", uri=True, timeout=1)) as db:
        db.execute("PRAGMA trusted_schema=OFF")
        columns = {row[1] for row in db.execute("PRAGMA table_info(local_thread_catalog)")}
        activity_column = "chatgpt_async_status" if "chatgpt_async_status" in columns else "NULL"
        origin = "conversation_origin" if "conversation_origin" in columns else "NULL"
        recency = "source_recency_at" if "source_recency_at" in columns else "NULL"
        created = "source_created_at" if "source_created_at" in columns else "NULL"
        query = f"""SELECT thread_id, display_title, source_updated_at, {activity_column}, {origin}, {recency}, {created}
                    FROM local_thread_catalog WHERE source_kind = 'chatgpt' AND missing_candidate = 0"""
        chats = {}
        for identifier, title, updated, async_status, surface, recent, started in db.execute(query):
            date = max((v for v in (updated, recent, started) if isinstance(v, (int, float))), default=0)
            normalized = item(identifier, title, date)
            if normalized:
                if surface == "tpp":
                    normalized["work"] = True
                descriptions = {1: "Working on the request", 3: "Writing a response",
                                4: "A new response is ready", 5: "Working in ChatGPT",
                                6: "Processing the current turn", 7: "Working in the background"}
                if async_status in descriptions:
                    normalized["state"] = "ready" if async_status == 4 else "running"
                    normalized["activityText"] = descriptions[async_status]
                chats[normalized["sessionID"]] = normalized

        # Work can register an active turn before its titled conversation is indexed.
        # Limit this temporary signal to the desktop profile and accounts in its ChatGPT catalog.
        tables = {r[0] for r in db.execute("SELECT name FROM sqlite_master WHERE type='table'")}
        if launched is not None and {"active_chat_turns", "local_thread_catalog_sync_state"} <= tables:
            profile = str(Path.home() / "Library/Application Support/Codex")
            for identifier, observed in db.execute("""
                SELECT a.thread_id, MAX(a.observed_at_ms) FROM active_chat_turns a
                JOIN local_thread_catalog_sync_state s ON s.host_id = 'chatgpt:' || a.account_id || ':' || a.user_id
                WHERE a.profile = ? AND a.observed_at_ms >= ? GROUP BY a.thread_id""",
                (profile, int(launched * 1000))):
                pending = item(identifier, None, observed / 1000)
                if pending:
                    key = pending["sessionID"]
                    pending["title"] = "New ChatGPT conversation · " + key[:8]
                    row = chats.setdefault(key, pending)
                    row["updated"] = max(row["updated"], pending["updated"])
                    row["state"] = "running"
                    if row.get("activityText") not in ("Writing a response", "Working in the background"):
                        row["activityText"] = "Working on the current turn"
        yield from chats.values()

def browser_items(home):
    support = home / "Library/Application Support"
    queries = []
    chrome = "SELECT url, title, last_visit_time / 1000000 - 11644473600 FROM urls"
    for vendor in ("Google/Chrome", "Microsoft Edge", "BraveSoftware/Brave-Browser", "Arc/User Data", "Dia/User Data", "Chromium"):
        for path in (support / vendor).glob("*/History"):
            queries.append((path, chrome))
    # The desktop app can also open private conversations in its embedded browser.
    for pattern in ("Default/History", "Default/Partitions/*/History", "codex-browser-app/History"):
        queries.extend((path, chrome) for path in (support / "Codex").glob(pattern))
    for path in (support / "Firefox/Profiles").glob("*/places.sqlite"):
        queries.append((path, "SELECT url, title, last_visit_date / 1000000 FROM moz_places"))
    safari = home / "Library/Safari/History.db"
    queries.append((safari, "SELECT url, title, visit_time + 978307200 FROM history_visits JOIN history_items ON history_items.id = history_visits.history_item"))
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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--desktop", action="store_true")
    mode.add_argument("--browser", action="store_true")
    mode.add_argument("--import-file", type=Path)
    parser.add_argument("--launched", type=float, help="Start time of the running desktop app")
    args = parser.parse_args()
    if args.desktop:
        rows = desktop_items(Path(os.environ.get("CODEX_HOME") or Path.home() / ".codex"), args.launched)
    elif args.browser:
        rows = browser_items(Path.home())
    else:
        rows = from_export(args.import_file)
    unique = {}
    for row in rows:
        key = row["sessionID"]
        if key not in unique or row["updated"] >= unique[key]["updated"]:
            unique[key] = row
    print(json.dumps({"items": sorted(unique.values(), key=lambda r: r["updated"], reverse=True)}, allow_nan=False))


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, RuntimeError, sqlite3.Error, zipfile.BadZipFile):
        sys.exit("Unable to read the conversation library.")
