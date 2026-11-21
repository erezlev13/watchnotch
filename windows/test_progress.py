import unittest
from adapters.codex_client import activity, read_snapshot


class Server:
    def __init__(self):
        self.flag = []
        self.items = []

    def call(self, method, params):
        if method == "thread/read":
            return {"thread": {"id": "sample", "name": "Layout fixes", "status": {"type": "active", "activeFlags": self.flag}}}
        if method == "thread/turns/list":
            return {"data": [{"id": "turn", "status": "inProgress"}]}
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
