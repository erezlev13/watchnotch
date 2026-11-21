"""Map live App Server interactions to the selected tile and route its one-time response."""
import errno
import hashlib
import json
import os
import re
import stat
import uuid
from dataclasses import dataclass
from pathlib import Path


def visible_item(item):
    moderation = item.get("moderation") or {}
    return not (moderation.get("moderated") or (moderation.get("display") or {}).get("mode") in ("block", "hide"))


def questions(raw, asynchronous):
    result, seen = [], set()
    if not isinstance(raw, list):
        return []
    for index, question in enumerate(raw):
        if not isinstance(question, dict) or question.get("isSecret"):
            return []
        key = str(index) if asynchronous else question.get("id")
        prompt = question.get("title" if asynchronous else "question")
        if not isinstance(prompt, str) or not prompt.strip() or not isinstance(key, str) or not key or key in seen:
            return []
        seen.add(key)
        options = []
        for opt in question.get("options") or []:
            label = opt if asynchronous else opt.get("label") if isinstance(opt, dict) else None
            if not isinstance(label, str) or not label.strip() or any(o["id"] == label for o in options):
                return []
            choice = {"id": label, "label": label}
            if isinstance(opt, dict) and opt.get("description"):
                choice["description"] = opt["description"]
            options.append(choice)
        result.append({"id": key, "prompt": prompt, "options": options,
                       "allowsOther": asynchronous or bool(question.get("isOther")) or not options})
    return result


@dataclass
class Interaction:
    turn: str
    card: dict
    rpc_id: object = None


def request_card(token, kind, action, reason="", prompts=None):
    # Codex owns expiration. A server resolution, newer user input, turn change,
    # or loss of the owning socket invalidates the local response route.
    return {"id": token, "kind": kind, "route": "codexServer", "action": action, "reason": reason,
            "expiresAt": "9999-12-31T23:59:59Z", "questions": prompts or []}


def approval_card(method, params, token):
    reason = params.get("reason") or ""
    decisions = ["accept", "decline"]
    if method == "item/commandExecution/requestApproval":
        if params.get("availableDecisions") is not None:
            decisions = params["availableDecisions"]
        # Extended grants and stdin operations require the full provider review UI.
        if params.get("additionalPermissions") or params.get("kind", "command") not in ("command", "humanCommand"):
            return None
        command = params.get("command")
        if not isinstance(command, str) or not command.strip():
            return None
        parts = [reason, command]
        if params.get("cwd"):
            parts.append("Working directory: " + params["cwd"])
        if params.get("networkApprovalContext"):
            network = params["networkApprovalContext"]
            parts.append("Network access: " + network["protocol"] + "://" + network["host"])
        action, reason = "Allow Codex to run this command once?", "\n".join(filter(None, parts))
    elif method == "item/fileChange/requestApproval" and reason and not params.get("grantRoot"):
        action = "Allow this file change once?"
    else:
        return None
    supported = [("accept", "allowOnce", "Approve once"), ("decline", "deny", "Deny"),
                 ("cancel", "cancel", "Deny and stop the turn")]
    options = [{"id": key, "label": label} for source, key, label in supported if source in decisions]
    if not options:
        return None
    prompt = {"id": "decision", "prompt": action, "options": options, "allowsOther": False}
    return request_card(token, "approval", action, reason, [prompt])


class LiveRequests:
    def __init__(self, key):
        self.key = key
        self.subscribed = False
        self.pending = {}
        self.sent = set()
        self.async_item = None
        self.async_turn = None
        self.turn_status = None
        self.connection_id = str(uuid.uuid4())
        self.head = None
        self.current = None
        self.feedback = ""

    def receive(self, message):
        method = message.get("method")
        params = message.get("params") or {}
        if not isinstance(params, dict) or params.get("threadId") != self.key:
            return
        if method == "serverRequest/resolved":
            closed = self.pending.pop(params.get("requestId"), None)
            if closed and closed.card["id"] in self.sent:
                self.feedback = "Codex closed this request."
            return
        rpc_id, turn = message.get("id"), params.get("turnId")
        if type(rpc_id) not in (int, str) or not turn or not params.get("itemId") or rpc_id in self.pending:
            return
        token = str(uuid.uuid4())  # Never route a decision from a previous socket, even if RPC IDs repeat.
        if method == "item/tool/requestUserInput":
            prompts = questions(params.get("questions"), False)
            card = request_card(token, "question", prompts[0]["prompt"], prompts=prompts) if prompts else None
        else:
            card = approval_card(method, params, token)
        if card:
            self.pending[rpc_id] = Interaction(turn, card, rpc_id)

    def reset_history(self):
        self.async_turn, self.turn_status, self.head, self.async_item = None, None, None, None

    def observe_items(self, turn, turn_status, items, older_pages):
        # Search backwards only through new activity; an answer in the original
        # session supersedes all earlier questions just as an answer in the tile does.
        if self.async_turn != turn or self.turn_status != turn_status:
            self.async_turn, self.turn_status, self.head, self.async_item = turn, turn_status, None, None
        if not items:
            self.head, self.async_item = None, None
            return
        head = items[0].get("id")
        if head and head == self.head:
            return
        def scan(page):
            for item in page:
                item_id = item.get("id")
                if item_id and item_id == self.head:
                    return True
                if item.get("type") == "userMessage":
                    self.async_item = None
                    return True
                if item.get("type") != "agentMessage" or not item_id or not visible_item(item):
                    continue
                prompts = questions(item.get("questions"), True)
                if not prompts:
                    if turn_status != "completed" or item.get("phase") != "final_answer":
                        continue
                    # A direct question at the end of the completed response can be answered as a
                    # normal follow-up. Never infer a choice or an approval from sentence text.
                    self.async_item = None
                    text = item.get("text") or ""
                    tail = re.split(r"(?<=[.!?])\s+|\n+", text.strip())[-1].strip()
                    if (text.count("```") % 2 == 0 and tail.endswith("?") and len(tail) <= 600 and
                            re.match(r"(?i)^(which|what|where|when|who|how|why|would|could|can|do|does|should|is|are|will)\b", tail)):
                        prompts = questions([{"title": tail}], True)
                    else:
                        return True
                token = hashlib.sha256(json.dumps([self.connection_id, self.key, turn, item_id, prompts],
                                       ensure_ascii=False).encode()).hexdigest()
                self.async_item = Interaction(turn, request_card(token, "question", prompts[0]["prompt"], prompts=prompts))
                return True
            return False
        if not scan(items):
            for page in older_pages():
                if scan(page):
                    break
        self.head = head

    def decorate(self, snapshot, runtime, turn_status):
        self.current = None
        if runtime != "active":
            self.pending.clear()
        for entry in self.pending.values():
            if entry.card["id"] not in self.sent and (self.async_turn is None or self.async_turn == entry.turn):
                self.current = entry
                break
        steerable = runtime == "active" and turn_status == "inProgress" and snapshot["state"] == "running"
        follow_up = runtime == "idle" and turn_status == "completed"
        if (not self.current and (steerable or follow_up) and self.async_item
                and self.async_item.card["id"] not in self.sent):
            self.current = self.async_item
        if self.current:
            snapshot.update(state="needsInput", request=self.current.card, sentence=self.current.card["action"])
        elif self.feedback:
            snapshot["sentence"] = self.feedback
            self.feedback = ""

    def respond(self, server, decision):
        entry = self.current
        if (not entry or decision.get("provider") != "Codex" or decision.get("sessionID") != self.key
                or decision.get("requestID") != entry.card["id"] or entry.card["id"] in self.sent):
            return
        kind = decision.get("decision")
        if entry.card["kind"] == "approval":
            answers = decision.get("answers")
            if kind != "answer" or not isinstance(answers, dict) or set(answers) != {"decision"}:
                return
            selected = answers["decision"]
            if not any(o["id"] == selected for o in entry.card["questions"][0]["options"]):
                return
            result = {"decision": {"allowOnce": "accept", "deny": "decline", "cancel": "cancel"}[selected]}
        else:
            answers = decision.get("answers")
            prompts = entry.card["questions"]
            if kind != "answer" or not isinstance(answers, dict) or set(answers) != {q["id"] for q in prompts}:
                return
            for q in prompts:
                value = answers[q["id"]]
                if (not isinstance(value, str) or not value.strip() or
                        (not q["allowsOther"] and not any(o["id"] == value for o in q["options"]))):
                    return
            result = {"answers": {key: {"answers": [value]} for key, value in answers.items()}}
        # Mark before writing: if the connection fails afterwards the server may already have accepted it.
        self.sent.add(entry.card["id"])
        self.current = None
        if entry.rpc_id is not None:
            server.send_frame(1, json.dumps({"id": entry.rpc_id, "result": result}).encode())
            self.feedback = "Your selection was sent. Waiting for Codex to close the request."
        else:
            content = "\n".join(q["prompt"] + " " + answers[q["id"]] for q in prompts)
            params = {"threadId": self.key, "clientUserMessageId": str(uuid.uuid4()),
                      "input": [{"type": "text", "text": content}]}
            if self.turn_status == "completed":
                ack = server.call("turn/start", params)
                accepted = bool((ack.get("turn") or {}).get("id"))
            else:
                ack = server.call("turn/steer", dict(params, expectedTurnId=entry.turn))
                accepted = ack.get("turnId") == entry.turn
            self.feedback = ("Codex received your answer." if accepted else
                             "Open the session to check whether Codex received your answer.")


def take_decision(snapshot_path):
    path = Path(str(snapshot_path) + ".decision")
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except OSError as error:
        if error.errno == errno.ELOOP:
            path.unlink(missing_ok=True)
        elif error.errno != errno.ENOENT:
            raise
        return None
    try:
        with os.fdopen(fd, "rb") as handle:
            info = os.fstat(handle.fileno())
            if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o022
                    or info.st_size > 65536):
                return None
            payload = handle.read(65537)
            if len(payload) > 65536:
                return None
            data = json.loads(payload)
            return data if isinstance(data, dict) else None
    except (ValueError, UnicodeError):
        return None
    finally:
        path.unlink(missing_ok=True)
