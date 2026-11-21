from contextlib import contextmanager
import json
from pathlib import Path
import sqlite3
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import patch
import zipfile

from adapters.library import desktop_items, from_export, windows_browser_items
from companion import Library, Session, codex_library, from_link, poll

A = "11111111-1111-4111-8111-111111111111"
B = "22222222-2222-4222-8222-222222222222"


class CompanionTests(unittest.TestCase):
    def test_links_pins_and_restart(self):
        chat = from_link("https://chatgpt.com/c/" + A + "?secret=1", "Research")
        codex = from_link("codex://threads/" + A, "Research")
        self.assertEqual(chat.url, "https://chatgpt.com/c/" + A)
        self.assertEqual(codex.url, "codex://threads/" + A)
        for bad in ("file:///foo", "https://chatgpt.com@other.org/c/" + A,
                    "https://chatgpt.com/share/" + A, "codex://threads/garbage"):
            with self.assertRaises(ValueError):
                from_link(bad, "")
        with TemporaryDirectory() as tmp:
            path = Path(tmp) / "library.json"
            lib = Library.load(path)
            lib.pin(chat)
            lib.pin(codex)
            lib.pin(Session("ChatGPT", A, "New title"))
            lib.save(path)
            restored = Library.load(path)
            self.assertEqual([p.title for p in restored.pins], ["New title", "Research"])
            self.assertEqual([p.key for p in restored.pins], [chat.key, codex.key])
            with patch("companion.os.replace", side_effect=PermissionError):
                with self.assertRaises(PermissionError):
                    Library().save(path)
            self.assertEqual(Library.load(path), restored)
            self.assertEqual(list(path.parent.iterdir()), [path])

    def test_edge_and_export_merge_only_titles_ids_and_dates(self):
        with TemporaryDirectory() as tmp:
            local = Path(tmp)
            path = local / "Microsoft/Edge/User Data/Profile 1/History"
            path.parent.mkdir(parents=True)
            db = sqlite3.connect(path)
            with db:
                db.execute("create table urls(url, title, last_visit_time)")
                for host in ("chatgpt.com", "other.example"):
                    db.execute("insert into urls values(?, 'Visited', 0)", (f"https://{host}/c/{A}",))
            db.close()
            lib = Library()
            found = list(windows_browser_items(local, local))
            self.assertEqual(len(found), 1)
            lib.import_chats(found)
            archive = local / "export.zip"
            with zipfile.ZipFile(archive, "w") as z:
                z.writestr("chatgpt/conversations-001.json", json.dumps([
                    {"id": A, "title": "Latest", "update_time": 4, "mapping": {"secret": True}}]))
                z.writestr("codex/conversations.json", json.dumps([{"id": B}]))
            lib.import_chats(from_export(archive))
            self.assertEqual(list(lib.chats.values()), [Session("ChatGPT", A, "Latest", 4)])
            out = local / "library.json"
            lib.save(out)
            self.assertNotIn("secret", out.read_text())
            self.assertEqual(Library.load(out), lib)

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

    def test_thread_library_pages_and_repeated_cursor(self):
        class Pages:
            def call(self, method, params):
                self_test.assertEqual(method, "thread/list")
                self_test.assertIs(params["currentAccountOnly"], True)
                key = B if params.get("cursor") else A
                return {"data": [{"id": key, "name": "Same title"}], "nextCursor": "next"}
        self_test = self
        @contextmanager
        def connect():
            yield Pages()
        with patch("companion.connection", connect):
            self.assertEqual(list(codex_library()), [("Codex", A), ("Codex", B)])

    def test_poll_and_reconnect_only_the_selected_identity(self):
        pin = Session("Codex", A, "Session")
        class Fake:
            def call(self, method, params):
                case.assertEqual(params["threadId"], A)
                if method == "thread/read":
                    return {"thread": {"id": A, "name": "Session", "status": {"type": "active", "activeFlags": []}}}
                if method == "thread/turns/list":
                    return {"data": [{"id": "turn", "status": "inProgress"}]}
                return {"data": [{"turnId": "turn", "item": {"type": "agentMessage", "text": "Reading files."}}]}
        case = self
        @contextmanager
        def connected():
            yield Fake()
        def offline():
            raise ConnectionError()
        cache = {}
        live = poll([pin], {}, cache, connected)
        stale = poll([pin], live, cache, offline)
        self.assertEqual(stale[pin.key]["sentence"], "Reading files.")
        self.assertEqual(stale[pin.key]["state"], "unavailable")
        self.assertEqual(poll([pin], stale, cache, connected), live)
        self.assertEqual(poll([], live, cache, offline), {})


if __name__ == "__main__":
    unittest.main()
