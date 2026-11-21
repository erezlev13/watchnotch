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

    def test_catalog_reports_streaming_without_marking_unread_or_unknown_active(self):
        with TemporaryDirectory() as root:
            folder = Path(root) / "sqlite"
            folder.mkdir()
            with sqlite3.connect(folder / "codex.db") as db:
                db.execute("CREATE TABLE local_thread_catalog(thread_id,display_title,source_updated_at,source_kind,missing_candidate,chatgpt_async_status)")
                for value in [1, 2, 3, 4, 5, 6, 7, 99]:
                    db.execute("INSERT INTO local_thread_catalog VALUES(?,?,0,'chatgpt',0,?)",
                               (f"11111111-1111-4111-8111-{value:012d}", str(value), value))
            self.assertTrue(all("state" not in r and "activityText" not in r for r in desktop_items(Path(root))))
            self.assertEqual({r["title"] for r in desktop_items(Path(root), launched=0) if r.get("state") == "running"},
                             {"1", "3", "5", "6", "7"})

    def test_active_turn_appears_before_catalog_and_keeps_identity_when_indexed(self):
        profile = str(Path.home() / "Library/Application Support/Codex")
        active_id = "11111111-1111-4111-8111-111111111111"
        with TemporaryDirectory() as root:
            folder = Path(root) / "sqlite"
            folder.mkdir()
            with sqlite3.connect(folder / "codex.db") as db:
                db.execute("CREATE TABLE local_thread_catalog(thread_id,display_title,source_updated_at,source_kind,missing_candidate,chatgpt_async_status,conversation_origin,source_created_at,source_recency_at)")
                db.execute("CREATE TABLE local_thread_catalog_sync_state(host_id)")
                db.execute("INSERT INTO local_thread_catalog_sync_state VALUES('chatgpt:a:u')")
                db.execute("CREATE TABLE active_chat_turns(profile,account_id,user_id,thread_id,observed_at_ms)")
                db.executemany("INSERT INTO active_chat_turns VALUES(?,?,?,?,?)", [
                    (profile, "a", "u", active_id, 101000),
                    (profile, "a", "u", "22222222-2222-4222-8222-222222222222", 99000),
                    (profile, "other", "u", "33333333-3333-4333-8333-333333333333", 101000),
                    ("other-profile", "a", "u", "44444444-4444-4444-8444-444444444444", 101000),
                ])
                db.commit()
                self.assertEqual(list(desktop_items(Path(root))), [])
                provisional, = desktop_items(Path(root), launched=100)
                self.assertEqual((provisional["sessionID"], provisional["state"], provisional["updated"]),
                                 (active_id, "running", 101))
                db.execute("INSERT INTO local_thread_catalog VALUES(?, 'A Work chat', 90, 'chatgpt', 0, 3, 'tpp', 88, 110)", (active_id,))
                db.commit()
                streamed, = desktop_items(Path(root), launched=100)
                self.assertEqual((streamed["sessionID"], streamed["title"], streamed["updated"], streamed["work"]),
                                 (active_id, "A Work chat", 110, True))
                self.assertEqual(streamed["activityText"], "Writing a response")
                db.execute("DELETE FROM active_chat_turns")
                db.execute("UPDATE local_thread_catalog SET chatgpt_async_status=4")
                db.commit()
                unread, = desktop_items(Path(root), launched=100)
                self.assertEqual((unread["state"], unread["activityText"]), ("ready", "A new response is ready"))
                db.execute("UPDATE local_thread_catalog SET chatgpt_async_status=NULL")
                db.commit()
                cleared, = desktop_items(Path(root), launched=100)
                self.assertNotIn("state", cleared)

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
