import json
import os
from pathlib import Path
import tempfile
import unittest

from monitor import read_snapshot
from requests_bridge import LiveRequests, take_decision


KEY = "pin-a"


def prompt(key="color", secret=False):
    return {"id": key, "question": "Choose a color?", "isOther": False, "isSecret": secret,
            "options": [{"label": "Blue", "description": "Sky"}, {"label": "Amber", "description": "Warm"}]}


class Daemon:
    def __init__(self):
        self.interactions = LiveRequests(KEY)
        self.thread = KEY
        self.turn = "turn-1"
        self.runtime = "active"
        self.phase = "inProgress"
        self.items = []
        self.frames = []
        self.calls = []
        self.replayed = []
        self.older = []

    def call(self, method, params):
        self.calls.append((method, params))
        if method == "thread/read":
            return {"thread": {"id": self.thread, "status": {"type": self.runtime}}}
        if method == "thread/resume":
            for message in self.replayed:
                self.interactions.receive(message)
            return {"thread": {"id": self.thread}}
        if method == "thread/turns/list":
            return {"data": [{"id": self.turn, "status": self.phase}]}
        if method == "thread/items/list":
            page = self.older if params.get("cursor") else self.items
            return {"data": [{"item": item, "turnId": self.turn} for item in page],
                    "nextCursor": "older" if self.older and not params.get("cursor") else None}
        if method == "turn/steer":
            return {"turnId": self.turn}
        if method == "turn/start":
            return {"turn": {"id": "next-turn"}}
        raise AssertionError(method)

    def send_frame(self, opcode, data):
        self.frames.append(json.loads(data))

    def request(self, method, **fields):
        return {"id": 0, "method": method, "params": dict(threadId=KEY, turnId=self.turn, itemId="item-1", **fields)}

    def decide(self, request, answers, **changes):
        data = dict(provider="Codex", sessionID=KEY, requestID=request["id"], decision="answer", answers=answers)
        self.interactions.respond(self, dict(data, **changes))


class InteractiveTests(unittest.TestCase):
    def test_question_replayed_on_attach_grouped_and_answered_once(self):
        daemon = Daemon()
        daemon.replayed = [daemon.request("item/tool/requestUserInput", questions=[prompt(), prompt("trim")])]
        req = read_snapshot(daemon, KEY)["request"]
        self.assertEqual(req["questions"][0]["options"][0], {"id":"Blue","label":"Blue","description":"Sky"})
        self.assertEqual([q["id"] for q in req["questions"]], ["color", "trim"])
        answers = {"color": "Blue", "trim": "Amber"}
        daemon.decide(req, answers, sessionID="pin-b")
        daemon.decide(req, answers, requestID="yesterday")
        daemon.decide(req, {"color":"Blue"})
        daemon.decide(req, dict(answers, trim="unoffered"))
        self.assertFalse(daemon.frames)
        daemon.decide(req, answers)
        daemon.decide(req, answers)
        self.assertEqual(daemon.frames, [{"id":0, "result":{"answers":{"color":{"answers":["Blue"]},"trim":{"answers":["Amber"]}}}}])
        daemon.interactions.receive({"method":"serverRequest/resolved","params":{"threadId":KEY,"requestId":0}})
        self.assertNotIn("request", read_snapshot(daemon, KEY))
        self.assertEqual(sum(m=="thread/resume" for m,_ in daemon.calls), 1)

    def test_approval_decisions_match_available_scope_and_rpc_connection(self):
        methods = ["accept", {"acceptWithExecpolicyAmendment": {}}, "cancel"]
        for outcome, expected in [("allowOnce","accept"), ("cancel","cancel")]:
            daemon = Daemon()
            daemon.replayed = [daemon.request("item/commandExecution/requestApproval", command="pwd", cwd="/tmp",
                                               reason="Check the directory?", availableDecisions=methods)]
            req = read_snapshot(daemon, KEY)["request"]
            self.assertIn("pwd", req["reason"])
            self.assertIn("/tmp", req["reason"])
            self.assertEqual([o["id"] for o in req["questions"][0]["options"]], ["allowOnce","cancel"])
            daemon.decide(req, {"decision":"deny"})
            self.assertFalse(daemon.frames)
            daemon.decide(req, {"decision":outcome})
            self.assertEqual(daemon.frames[-1], {"id":0,"result":{"decision":expected}})
            daemon.interactions = LiveRequests(KEY)
            self.assertNotEqual(read_snapshot(daemon, KEY)["request"]["id"], req["id"])
            daemon.decide(req, {"decision":outcome})
            self.assertEqual(len(daemon.frames), 1)

    def test_hidden_secret_wrong_thread_and_resolved_requests(self):
        daemon = Daemon()
        req = daemon.request("item/tool/requestUserInput", questions=[prompt(secret=True)])
        other = daemon.request("item/tool/requestUserInput", questions=[prompt()])
        other["params"]["threadId"]="pin-b"
        daemon.replayed=[req,other]
        self.assertNotIn("request", read_snapshot(daemon, KEY))
        daemon.interactions.receive(daemon.request("item/tool/requestUserInput", questions=[prompt()]))
        daemon.interactions.receive({"method":"serverRequest/resolved","params":{"threadId":KEY,"requestId":0}})
        self.assertNotIn("request", read_snapshot(daemon, KEY))
        daemon.items=[{"type":"agentMessage","id":"hidden","questions":[{"title":"Hidden?","options":["A"]}],
                       "moderation":{"display":{"mode":"hide"}}}]
        self.assertNotIn("request", read_snapshot(daemon, KEY))

    def test_async_questions_survive_progress_and_source_responses_clear_them(self):
        daemon=Daemon()
        daemon.items=[{"type":"commandExecution","id":"tool"}]
        daemon.older=[{"type":"agentMessage","id":"async","questions":[{"title":"Which color?","options":["Blue","Mint"]}]}]
        req=read_snapshot(daemon,KEY)["request"]
        self.assertEqual(req["action"],"Which color?")
        daemon.decide(req,{"0":"Mint"})
        method,params=daemon.calls[-1]
        self.assertEqual((method,params["threadId"],params["expectedTurnId"]),("turn/steer",KEY,"turn-1"))
        self.assertIn("Mint",params["input"][0]["text"])
        self.assertNotIn("request",read_snapshot(daemon,KEY))
        daemon.interactions=LiveRequests(KEY)
        daemon.items.insert(0,{"id":"original-answer","type":"userMessage"})
        self.assertNotIn("request",read_snapshot(daemon,KEY))

    def test_latest_completed_question_can_take_free_text(self):
        daemon=Daemon()
        daemon.runtime,daemon.phase="idle","completed"
        daemon.items=[{"type":"agentMessage","id":"last","phase":"final_answer",
                       "text":"The colors are ready. Which color would you prefer?"}]
        req=read_snapshot(daemon,KEY)["request"]
        self.assertEqual(req["questions"],[{"id":"0","prompt":"Which color would you prefer?","options":[],"allowsOther":True}])
        daemon.decide(req,{"0":"Forest green"})
        self.assertEqual(daemon.calls[-1][0],"turn/start")
        daemon.turn="turn-2"
        daemon.items=[{"type":"userMessage","id":"next"}]
        self.assertNotIn("request",read_snapshot(daemon,KEY))
        self.assertFalse(any(method=="thread/resume" for method,_ in daemon.calls))

    def test_decision_file_is_private_size_limited_and_consumed_once(self):
        with tempfile.TemporaryDirectory() as folder:
            snapshot=Path(folder)/"codex.json"
            inbox=Path(str(snapshot)+".decision")
            inbox.write_text('{"decision":"answer"}')
            self.assertEqual(take_decision(snapshot),{"decision":"answer"})
            self.assertIsNone(take_decision(snapshot))
            inbox.write_bytes(b" " * 65537)
            self.assertIsNone(take_decision(snapshot))
            inbox.write_text("{}")
            os.chmod(inbox,0o666)
            self.assertIsNone(take_decision(snapshot))
            snapshot.write_text("untouched")
            inbox.symlink_to(snapshot)
            self.assertIsNone(take_decision(snapshot))
            self.assertEqual(snapshot.read_text(),"untouched")
