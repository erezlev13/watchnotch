import unittest
from adapters.codex_client import activity, read_snapshot


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
        self.assertEqual(read_snapshot(s, "sample", cache=cache)["sentence"], "Updated Layout.swift.")
        s.items = [{"type": "reasoning", "content": ["private"]}]
        self.assertEqual(read_snapshot(s, "sample", cache=cache)["sentence"], "Updated Layout.swift.")
        s.flag = ["waitingOnApproval"]
        self.assertIn("Approval needed", read_snapshot(s, "sample", cache=cache)["sentence"])

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
        self.assertEqual(read_snapshot(s, "sample")["sentence"], "Checked repository changes.")
        s.items.pop(0)
        self.assertEqual(read_snapshot(s, "sample")["sentence"], "Finished · Layout fixes.")
        s.turn = "interrupted"
        self.assertIn("interrupted", read_snapshot(s, "sample")["sentence"])

    def test_live_gist(self):
        self.assertEqual(activity({"type": "agentMessage", "text": "Okay! I’m checking the Windows build."}), "Checking the Windows build.")

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
    def test_direct_subagents_and_forks_across_pages(self):
        from adapters.codex_client import branch_items
        parent = "11111111-1111-4111-8111-111111111111"
        agent = "22222222-2222-4222-8222-222222222222"
        fork = "33333333-3333-4333-8333-333333333333"
        class Local:
            def call(self, method, params):
                assert method == "thread/list" and params["currentAccountOnly"] and not params.get("useStateDbOnly")
                if "cursor" not in params:
                    return {"data":[{"id":agent,"parentThreadId":parent,"agentNickname":"Reviewer","status":{"type":"active"}}],"nextCursor":"second"}
                return {"data":[{"id":fork,"forkedFromId":parent,"name":"Another approach"},
                                {"id":agent, "parentThreadId":parent}, {"id":parent,"parentThreadId":fork}]}
        branches = branch_items(Local(), {parent})
        self.assertEqual([(b["sessionID"], b["branchKind"]) for b in branches], [(agent,"Subagent"),(fork,"Fork")])

    def test_complete_sentence_survives_past_old_character_limit(self):
        from adapters.codex_client import message_gist
        sentence = "The Windows build now applies the display fix after the monitor reconnects and keeps every pinned session on the correct screen."
        self.assertEqual(message_gist("Yes. " + sentence + " More information follows."), sentence)
