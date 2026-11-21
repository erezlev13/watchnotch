"""Queue status sentences so each one has time to appear and be read."""
from collections import deque


class StatusScript:
    def __init__(self):
        self.current = ""
        self.pending = deque()
        self.phase = "shown"
        self.started = 0
        self.deadline = None

    def receive(self, sentence, now, animate):
        if not sentence or sentence == (self.pending[-1] if self.pending else self.current):
            return
        if self.phase == "shown":
            self.present(sentence, now, animate)
        else:
            self.pending.append(sentence)

    def present(self, sentence, now, animate):
        self.current = sentence
        self.started = now
        self.phase = "revealing"
        self.deadline = now + min(6, max(1.35, len(sentence) * 0.045))
        if not animate:
            self.reveal(now)

    def reveal(self, now):
        if self.phase == "revealing":
            self.phase = "reading"
            self.deadline = now + max(1.6, len(self.current.split()) * 0.26)

    def advance(self, now, animate):
        if self.deadline is None or now < self.deadline:
            return
        if self.phase == "revealing":
            self.reveal(now)
        elif self.pending:
            self.present(self.pending.popleft(), now, animate)
        else:
            self.phase = "shown"
            self.deadline = None

    def progress(self, now):
        if self.phase != "revealing":
            return 1
        return min(1, max(0, (now - self.started) / (self.deadline - self.started)))
