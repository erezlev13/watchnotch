import unittest
from contextlib import closing
from pathlib import Path
import sqlite3
import tempfile
from adapters.codex_client import activity, branch_items, read_snapshot


class Server:
    def __init__(self):
        self.flag = []
        self.items = []
        self.runtime = "active"
        self.turn = "inProgress"

    def call(self, method, params):
        if method == "thread/read":
            return {"thread": {"id": "sample", "name": "Layout fixes", "status": {"type": self.runtime, "activeFlags": self.flag}}}
        if method == "thread/turns/list":
            return {"data": [{"id": "turn", "status": self.turn}]}
        assert params["threadId"] == "sample" and params["turnId"] == "turn"
        return {"data": [{"item": x, "turnId": "turn"} for x in self.items]}


class ProgressTest(unittest.TestCase):
    def test_activity_changes_within_one_turn(self):
        s, cache = Server(), {}
        s.items = [{"type": "agentMessage", "text": "Checking the pin layout. Another sentence."}]
        self.assertEqual(read_snapshot(s, "sample", cache=cache)["sentence"], "Checking the pin layout.")
        s.items = [{"type": "fileChange", "changes": [{"path": "/tmp/Layout.swift"}], "status": "completed"}]
        self.assertEqual(read_snapshot(s, "sample", cache=cache)["sentence"], "The project changes have been saved.")
        s.items = [{"type": "reasoning", "content": ["private"]}]
        self.assertEqual(read_snapshot(s, "sample", cache=cache)["sentence"], "The project changes have been saved.")
        s.flag = ["waitingOnApproval"]
        self.assertIn("Your approval is needed", read_snapshot(s, "sample", cache=cache)["sentence"])

    def test_hidden_output(self):
        self.assertEqual(activity({"type": "agentMessage", "text": "hidden", "moderation": {"display": {"mode": "hide"}}}), "")
        self.assertEqual(activity({"type": "functionCallOutput", "output": "private"}), "")

    def test_finished_gist_skips_acknowledgement_and_headings(self):
        s = Server()
        s.runtime, s.turn = "idle", "completed"
        s.items = [{"type": "commandExecution", "command": "git diff", "status": "completed"},
                   {"type": "agentMessage", "phase": "final_answer",
                    "text": "Yes.\n\n## Result\nThe Windows build needs a different fix. More detail."}]
        result = read_snapshot(s, "sample")
        self.assertEqual(result["sentence"], "The Windows build needs a different fix.")
        s.items[1]["text"] = "Yes."
        self.assertEqual(read_snapshot(s, "sample")["sentence"], "I reviewed the latest changes.")
        s.items.pop(0)
        self.assertEqual(read_snapshot(s, "sample")["sentence"], "Work on this request has finished.")
        s.turn = "interrupted"
        self.assertIn("interrupted", read_snapshot(s, "sample")["sentence"])

    def test_best_visible_outcome_over_filler_and_implementation(self):
        s = Server()
        s.runtime, s.turn = "idle", "completed"
        s.items = [{"type": "agentMessage", "phase": "final_answer",
                    "text": "Here you go. I changed `tile_state.py`. I found the cause. You can now read the entire update on macOS without opening the chat."}]
        self.assertEqual(read_snapshot(s, "sample")["sentence"], "You can now read the entire update on macOS without opening the chat.")

    def test_progress_explains_purpose_instead_of_listing_tools(self):
        s = Server()
        s.items = [{"type":"commandExecution", "status":"inProgress",
                    "command":"cat /secret/path", "commandActions":[{"type":"read", "path":"/secret/path"}]},
                   {"type":"agentMessage", "text":"Checking why the reply field disappears when the notch closes."}]
        self.assertEqual(read_snapshot(s, "sample")["sentence"], "Checking why the reply field disappears when the notch closes.")
        s.items.insert(0, {"type":"commandExecution", "status":"completed", "exitCode":0, "command":"pytest"})
        self.assertEqual(read_snapshot(s, "sample")["sentence"], "The changes passed this check.")
        self.assertEqual(activity({"type":"commandExecution", "status":"completed", "exitCode":0, "command":"echo pytest"}), "")

    def test_blocker_and_interrupted_or_failed_turn_override_earlier_activity(self):
        s, cache = Server(), {}
        s.items = [{"type":"agentMessage", "text":"Which screen should show your sessions?"}]
        s.flag = ["waitingOnUserInput"]
        self.assertEqual(read_snapshot(s, "sample", cache=cache)["sentence"], "Which screen should show your sessions?")
        s.runtime, s.turn, s.items = "idle", "failed", []
        self.assertEqual(read_snapshot(s, "sample", cache=cache)["sentence"], "The work stopped before the request was finished.")
        s.turn = "completed"
        self.assertEqual(read_snapshot(s, "sample", cache=cache)["sentence"], "Work on this request has finished.")

    def test_live_gist(self):
        self.assertEqual(activity({"type": "agentMessage", "text": "Okay! I’m checking the Windows build."}), "I’m checking the Windows build.")

class ReplyTest(unittest.TestCase):
    def test_replies_bound_to_each_selected_session(self):
        from adapters.codex_client import send_reply
        calls = []
        class Local:
            def call(self, method, params):
                if method == "thread/read":
                    return {"thread": {"id": params["threadId"], "status": {"type":"idle"}}}
                calls.append((params["threadId"], params["input"][0]["text"]))
                return {"turn":{"id":"accepted"}}
        local = Local()
        self.assertEqual(send_reply(local, "first", "A"), "sent")
        self.assertEqual(send_reply(local, "second", "B"), "sent")
        self.assertEqual(calls, [("first","A"),("second","B")])

    def test_waiting_and_ambiguous_delivery(self):
        from adapters.codex_client import send_reply
        class Local:
            calls = 0
            flags = ["waitingOnApproval"]
            def call(self, method, params):
                if method == "thread/read":
                    return {"thread":{"id":"selected","status":{"type":"active","activeFlags":self.flags}}}
                self.calls += 1
                raise ConnectionError("lost acknowledgement")
        local = Local()
        self.assertEqual(send_reply(local, "selected", "Hi"), "openSession")
        self.assertEqual(send_reply(local, "other", "Hi"), "openSession")
        local.flags = []
        self.assertEqual(send_reply(local, "selected", "Hi"), "uncertain")
        self.assertEqual(local.calls, 1)

class BranchTest(unittest.TestCase):
    def test_active_spawned_workers_and_persistent_forks(self):
        from uuid import UUID
        parent, foreign, worker, waiting, idle, unloaded, guardian, fork, unrelated = [
            str(UUID(int=n)) for n in range(1, 10)
        ]

        def spawned(key, owner, runtime, path, flags=()):
            return {"id": key, "parentThreadId": owner, "agentNickname": "Random nickname",
                    "source": {"subAgent": {"thread_spawn": {"parent_thread_id": owner, "agent_path": "/root/" + path}}},
                    "status": {"type": runtime, "activeFlags": list(flags)}}

        threads = {
            worker: spawned(worker, parent, "active", "verify_routing"),
            waiting: spawned(waiting, parent, "active", "check-tests", ["waitingOnApproval"]),
            idle: spawned(idle, parent, "idle", "completed"),
            unloaded: spawned(unloaded, parent, "notLoaded", "older_task"),
            guardian: {"id": guardian, "parentThreadId": parent, "forkedFromId": parent, "name": "Guardian review",
                       "status": {"type": "active"}, "source": {"subAgent": {"other": "guardian"}}},
            unrelated: spawned(unrelated, foreign, "active", "other_agent"),
            fork: {"id": fork, "forkedFromId": parent, "name": "Alternate approach", "status": {"type":"notLoaded"}},
        }
        loaded = [worker, guardian, idle, waiting, unrelated]
        calls = []
        class Local:
            def call(self, method, params):
                calls.append((method, params.copy()))
                if method == "thread/loaded/list":
                    if params.get("cursor") == "later":
                        return {"data": loaded[2:]}
                    return {"data": loaded[:2], "nextCursor": "later"}
                if method == "thread/read":
                    assert params["includeTurns"] is False
                    return {"thread": threads[params["threadId"]]}
                assert method == "thread/list" and params["currentAccountOnly"]
                if "includedThreadIds" in params:
                    # The worker is omitted from the index even while active.
                    ids = params["includedThreadIds"]
                    rows = [threads[k] for k in ids if k in threads and k != worker]
                    return {"data": rows + ([{"id": parent}] if parent in ids else [])}
                if params.get("cursor") == "forks":
                    return {"data": [threads[fork], threads[guardian]]}
                return {"data": [threads[unloaded]], "nextCursor": "forks"}

        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            with closing(sqlite3.connect(root / "state_5.sqlite")) as db, db:
                db.execute("CREATE TABLE thread_spawn_edges(parent_thread_id, child_thread_id)")
                # A stale edge to an unrelated worker must be rejected by its authoritative thread/read.
                db.executemany("INSERT INTO thread_spawn_edges VALUES(?, ?)",
                               [(parent, worker), (parent, unrelated), (foreign, unloaded)])
            server = Local()
            rows = {row["sessionID"]: row for row in branch_items(server, {parent, foreign}, directory=root)}
            self.assertEqual(set(rows), {worker, waiting, fork})
            self.assertEqual((rows[worker]["branchKind"], rows[worker]["state"]), ("Subagent", "running"))
            self.assertEqual(rows[worker]["title"].lower(), "verify routing")
            self.assertEqual(rows[waiting]["state"], "needsInput")
            self.assertEqual(rows[fork]["branchKind"], "Fork")
            self.assertTrue(all(row["parentID"] == parent for row in rows.values()))

            threads[worker]["status"] = {"type":"idle"}
            loaded.remove(waiting)
            calls.clear()
            self.assertEqual(branch_items(server, {parent}, include_forks=False, directory=root), [])
            self.assertFalse(any(method == "thread/list" and "includedThreadIds" not in params for method, params in calls))
            self.assertFalse(any(method == "thread/read" and params["threadId"] == waiting for method, params in calls))

            calls.clear()
            self.assertEqual(branch_items(server, {foreign}, directory=root), [])
            self.assertEqual([method for method, _ in calls], ["thread/list"])

    def test_complete_sentence_survives_past_old_character_limit(self):
        from adapters.codex_client import message_gist
        sentence = "The Windows build now applies the display fix after the monitor reconnects and keeps every pinned session on the correct screen."
        self.assertEqual(message_gist("Yes. " + sentence + " More information follows."), sentence)
