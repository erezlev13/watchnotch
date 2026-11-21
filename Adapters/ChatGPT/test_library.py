import json
from pathlib import Path
import sqlite3
from tempfile import TemporaryDirectory
import unittest
import zipfile
from library import browser_items, desktop_items, from_export


class LibraryTests(unittest.TestCase):
    def test_sharded_export_only_indexes_metadata(self):
        chat = {"id": "11111111-1111-4111-8111-111111111111", "title": "Status", "mapping": {"unused": "private text"}}
        with TemporaryDirectory() as root:
            path = Path(root) / "export.zip"
            with zipfile.ZipFile(path, "w") as z:
                z.writestr("chatgpt/conversations-000.json", json.dumps([chat]))
                z.writestr("codex/conversations.json", json.dumps([chat]))
            rows = list(from_export(path))
            self.assertEqual(len(rows), 1)
            self.assertEqual(set(rows[0]), {"sessionID", "title", "updated", "provider"})

    def test_desktop_catalog_excludes_other_sources_and_missing_rows(self):
        with TemporaryDirectory() as root:
            folder = Path(root) / "sqlite"
            folder.mkdir()
            db = sqlite3.connect(folder / "codex.db")
            db.execute("CREATE TABLE local_thread_catalog(thread_id,display_title,source_updated_at,source_kind,missing_candidate)")
            for source, missing in [("chatgpt", 0), ("cli", 0), ("chatgpt", 1)]:
                db.execute("INSERT INTO local_thread_catalog VALUES(?, ?, ?, ?, ?)",
                           ("11111111-1111-4111-8111-111111111111", "A title", 42, source, missing))
            db.commit()
            db.close()
            rows = list(desktop_items(Path(root)))
            self.assertEqual(len(rows), 1)
            self.assertEqual(rows[0]["title"], "A title")
            self.assertEqual(set(rows[0]), {"sessionID", "title", "updated", "provider"})

    def test_browser_profiles_and_private_links(self):
        with TemporaryDirectory() as root:
            path = Path(root) / "Library/Application Support/Google/Chrome/Profile 3/History"
            path.parent.mkdir(parents=True)
            db = sqlite3.connect(path)
            db.execute("CREATE TABLE urls (url TEXT, title TEXT, last_visit_time INTEGER)")
            for host in ("chatgpt.com", "other.example"):
                db.execute("INSERT INTO urls VALUES (?, 'A chat', 0)", ("https://" + host + "/c/11111111-1111-4111-8111-111111111111",))
            db.commit()
            db.close()
            self.assertEqual([r["title"] for r in browser_items(Path(root))], ["A chat"])
