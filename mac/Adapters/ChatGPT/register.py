#!/usr/bin/env python3
"""Register a user-chosen, direct ChatGPT conversation link in the companion."""
import argparse
import json
import os
from pathlib import Path
import re
import stat
import tempfile
from datetime import datetime, timezone
from urllib.parse import urlsplit
from uuid import UUID

DEFAULT_DIRECTORY = Path.home() / "Library/Application Support/Mac Notch Session Companion/Sessions"


def conversation_id(url):
    parts = urlsplit(url.strip())
    if parts.scheme != "https" or parts.netloc.lower() != "chatgpt.com":
        raise ValueError("Use a direct HTTPS conversation URL on chatgpt.com.")
    match = re.fullmatch(r"/c/([0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12})/?", parts.path)
    if not match:
        raise ValueError("Copy the private conversation URL with the path /c/<UUID>.")
    return str(UUID(match.group(1)))


def register(url, title, directory):
    identifier = conversation_id(url)
    title = title.strip()
    if not title or len(title) > 120 or not title.isprintable():
        raise ValueError("Enter a single-line title between 1 and 120 printable characters.")
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    target = directory / f"chatgpt-{identifier}.json"
    snapshot = {
        "provider": "ChatGPT",
        "sessionID": identifier,
        "title": title,
        "sentence": "Open the saved conversation to check its progress.",
        "state": "unavailable",
        "sessionURL": f"https://chatgpt.com/c/{identifier}",
    }
    try:
        fd = os.open(target, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(fd, "rb") as handle:
            info = os.fstat(handle.fileno())
            previous = None
            if stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid() and info.st_size <= 262144:
                raw = handle.read(262145)
                if len(raw) <= 262144:
                    previous = json.loads(raw)
        if isinstance(previous, dict) and "updatedAt" in previous:
            del previous["updatedAt"]
            if previous == snapshot:
                return target
    except (FileNotFoundError, UnicodeError, json.JSONDecodeError):
        pass
    snapshot["updatedAt"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=directory,
                                     prefix=".chatgpt-", delete=False) as output:
        try:
            json.dump(snapshot, output, ensure_ascii=False)
            output.write("\n")
            output.flush()
            os.replace(output.name, target)
        finally:
            Path(output.name).unlink(missing_ok=True)
    return target


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("url", help="Private https://chatgpt.com/c/<UUID> URL")
    parser.add_argument("--title", required=True, help="Local name for this session")
    args = parser.parse_args()
    try:
        print(register(args.url, args.title, Path(os.environ.get("NOTCH_SESSION_DIR") or DEFAULT_DIRECTORY)))
    except (ValueError, OSError) as error:
        parser.exit(1, f"{error}\n")
