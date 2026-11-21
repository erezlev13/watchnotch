"""Always-on-top session strip and searchable session library."""
from copy import deepcopy
import ctypes
import os
import sqlite3
from pathlib import Path
from queue import Empty, Queue
from threading import Thread
import tkinter as tk
from tkinter import filedialog, messagebox, ttk

from adapters.library import from_export, windows_browser_items
from companion import Library, Session, account_usage, branches_for, codex_library, desktop_catalog, from_link, poll, reply

BG = "#13191e"
CARD = "#212b32"
INK = "#edf2f3"
MINT = "#9fe2c7"
MUTED = "#afbdc3"
LABELS = {"running": "Working", "ready": "Ready", "needsInput": "Needs input", "unavailable": "Unavailable"}


def animation_enabled():
    if os.name != "nt":
        return False
    enabled = ctypes.c_int()
    # SPI_GETCLIENTAREAANIMATION follows the Windows accessibility setting.
    return bool(ctypes.windll.user32.SystemParametersInfoW(0x1042, 0, ctypes.byref(enabled), 0) and enabled.value)


class Panel:
    def __init__(self, root, path):
        self.root, self.path = root, path
        self.library = Library.load(path)
        self.discovered = {}
        self.desktop_rows = {}
        self.active_codex = {}
        self.branches = []
        self.entries = {}
        self.shown_sentences = {}
        self.drafts = {}
        self.feedback = {}
        self.check_draft = {}
        self.active_only = tk.BooleanVar(root)
        self.snapshots = {}
        self.cache = {}
        self.revisions = {}
        self.revision = 0
        self.jobs = set()
        self.events = Queue()
        self.dialog = None
        self.usage_dialog = None
        self.usage_text = tk.StringVar(root)
        self.expanded = False
        self.page = 0
        self.status = tk.StringVar(root)
        self.query = tk.StringVar(root)
        self.query.trace_add("write", lambda *_: self.filter_rows())
        root.title("watchnotch")
        root.configure(bg=BG)
        root.attributes("-topmost", True)
        root.tk.call("wm", "overrideredirect", root, True)
        root.bind("<Escape>", lambda _: self.collapse())
        self.body = tk.Frame(root, bg=BG, padx=7, pady=4)
        self.body.pack()
        icon = tk.PhotoImage(file=str(Path(__file__).with_name("owl.png")))
        self.owl = icon.subsample(max(1, (icon.width() + 31) // 32))
        self.render()
        root.after(80, self.receive)
        root.after(100, self.refresh_pins)
        root.after(100, self.refresh_catalogs)

    def job(self, name, task, done):
        if name in self.jobs:
            return
        self.jobs.add(name)
        def run():
            try:
                value = task()
            except Exception as error:
                self.events.put((name, None, None, str(error)))
            else:
                self.events.put((name, done, value, None))
        Thread(target=run, daemon=True).start()

    def receive(self):
        while True:
            try:
                name, callback, value, error = self.events.get_nowait()
            except Empty:
                break
            self.jobs.discard(name)
            if error is not None:
                self.status.set(f"{name} failed. {error}")
            else:
                callback(value)
        self.root.after(80, self.receive)

    def refresh_pins(self):
        pins = [pin for pin in self.library.pins if pin.provider == "Codex"]
        previous = self.snapshots.copy()
        if pins and "Observe Codex" not in self.jobs:
            # Only the observation worker accesses this cache.
            keys = {p.key for p in pins}
            self.cache = {k: v for k, v in self.cache.items() if k in keys}
            self.job("Observe Codex", lambda: poll(pins, previous, self.cache), self.updated)
        self.root.after(2500, self.refresh_pins)

    def refresh_catalogs(self):
        pins = self.library.pins
        if self.dialog is not None or any(p.provider == "ChatGPT" for p in pins):
            self.desktop()
        if self.dialog is not None:
            def loaded():
                try:
                    return codex_library(loaded=True)
                except (OSError, RuntimeError, ValueError):
                    return {}
            def active(rows):
                self.active_codex = rows
                self.filter_rows()
            self.job("Active Codex", loaded, active)
        parents = {p.sessionID for p in pins if p.provider == "Codex"}
        if self.expanded and parents:
            def branches(rows):
                if self.branches != rows:
                    self.branches = rows
                    self.render()
            self.job("Read branches", lambda: branches_for(parents), branches)
        self.root.after(5000, self.refresh_catalogs)

    def updated(self, values, provider="Codex"):

        keys = {p.key for p in self.library.pins}
        latest = {k: v for k, v in self.snapshots.items() if k in keys and k[0] != provider}
        latest.update((k, v) for k, v in values.items() if k in keys)
        if latest != self.snapshots:
            for key, snapshot in latest.items():
                if self.snapshots.get(key) != snapshot:
                    self.revision += 1
                    self.revisions[key] = self.revision
            self.snapshots = latest
            self.render()

    def button(self, parent, title, command, **kw):
        return tk.Button(parent, text=title, command=command, bg=BG, fg=INK, activebackground=CARD,
                         activeforeground=MINT, relief="flat", padx=8, pady=2, **kw)

    def toggle(self):
        self.expanded = not self.expanded
        self.render()

    def collapse(self):
        self.expanded = False
        self.render()

    def render(self):
        focus = self.root.focus_get()
        editing = next(((key, entry.index("insert")) for key, entry in self.entries.items() if entry is focus), None)
        self.entries.clear()
        for child in self.body.winfo_children():
            child.destroy()
        bar = tk.Frame(self.body, bg=BG)
        bar.pack()
        active = [p for p in self.library.pins
                  if self.snapshots.get(p.key, {}).get("state") in ("running", "needsInput")]
        focus = max(active, key=lambda p: self.revisions.get(p.key, 0), default=None)
        label = self.snapshots[focus.key]["title"][:30] if focus else "watchnotch"
        self.button(bar, label, self.toggle, image=self.owl, compound="left").pack(side="left")
        self.button(bar, "Library", self.open_library).pack(side="left")
        if self.expanded:
            self.button(bar, "Quit", self.root.destroy).pack(side="left")
            pins = self.library.pins
            per_page = max(1, (self.root.winfo_screenwidth() - 40) // 270)
            self.page = min(self.page, max(0, (len(pins) - 1) // per_page))
            row = tk.Frame(self.body, bg=BG)
            row.pack()
            if not pins:
                tk.Label(row, text="Pin a session from the library to follow it here.", bg=BG, fg=MUTED,
                         padx=12, pady=10).pack()
            for pin in pins[self.page * per_page:(self.page + 1) * per_page]:
                self.card(row, pin)
            if len(pins) > per_page:
                nav = tk.Frame(self.body, bg=BG)
                nav.pack()
                pages = (len(pins) + per_page - 1) // per_page
                def step(delta):
                    self.page = (self.page + delta) % pages
                    self.render()
                self.button(nav, "Previous", lambda: step(-1)).pack(side="left")
                tk.Label(nav, text=f"{self.page + 1} / {pages}", bg=BG, fg=MUTED).pack(side="left")
                self.button(nav, "Next", lambda: step(1)).pack(side="left")
        if editing and editing[0] in self.entries:
            entry = self.entries[editing[0]]
            entry.focus_set()
            entry.icursor(editing[1])
        self.root.update_idletasks()
        x = max(0, (self.root.winfo_screenwidth() - self.root.winfo_reqwidth()) // 2)
        self.root.geometry(f"+{x}+2")

    def card(self, parent, pin):
        frame = tk.Frame(parent, bg=CARD, padx=10, pady=8)
        frame.pack(side="left", padx=3, fill="y")
        data = self.snapshots.get(pin.key, {})
        state = LABELS.get(data.get("state"), "Connecting" if pin.provider == "Codex" else "Saved link")
        provider = "ChatGPT Work" if self.desktop_rows.get(pin.key, {}).get("work") else pin.provider
        for text, color, font in [(f"{provider}  ·  {state}", MINT, ("Segoe UI", 9)),
                                   (data.get("title", pin.title), INK, ("Segoe UI", 11, "bold"))]:
            tk.Label(frame, text=text, bg=CARD, fg=color, font=font, wraplength=225, anchor="w",
                     justify="left").pack(fill="x")
        sentence = data.get("sentence") or ("Open the conversation for updates." if pin.provider == "ChatGPT"
                                            else "Checking the local Codex daemon…")
        self.summary(frame, pin.key, sentence)
        actions = tk.Frame(frame, bg=CARD)
        actions.pack(anchor="w", pady=(6, 0))
        self.button(actions, "Jump in", lambda: self.jump(pin)).pack(side="left")
        if pin.provider == "Codex":
            self.button(actions, "Account usage", lambda: self.show_usage(data.get("details"))).pack(side="left")

            for child in self.branches:
                if child["parentID"] == pin.sessionID:
                    branch = Session.from_row(child)
                    self.button(frame, child["branchKind"] + " · " + branch.title,
                                lambda p=branch: self.jump(p), wraplength=205).pack(anchor="w")
        self.reply_box(frame, pin)

    def summary(self, frame, key, sentence):
        area = tk.Frame(frame, bg=CARD)
        area.pack(fill="x")
        label = tk.Label(area, text=sentence, bg=CARD, fg=INK, wraplength=225,
                         anchor="nw", justify="left", font=("Segoe UI", 10))
        label.pack(fill="both", expand=True)
        previous = self.shown_sentences.get(key)
        self.shown_sentences[key] = sentence
        if previous == sentence or not animation_enabled():
            return
        # Reserve the full paragraph's space so the reply field stays still.
        label.update_idletasks()
        area.configure(width=label.winfo_reqwidth(), height=label.winfo_reqheight())
        area.pack_propagate(False)
        callback = None
        def reveal(_event):
            if callback is not None:
                self.root.after_cancel(callback)
            label.configure(text=sentence)
        def advance(i):
            nonlocal callback
            callback = None
            if not label.winfo_exists():
                return
            label.configure(text=sentence[:i])
            if i < len(sentence):
                char = sentence[i-1]
                delay = 340 if char in ".!?" else 190 if char in ",:—;" else 64 if char.isspace() else 43
                callback = self.root.after(delay, advance, i+1)
        label.bind("<Button-1>", reveal)
        advance(1)

    def reply_box(self, frame, pin):
        key = pin.key
        if key not in self.drafts:
            self.drafts[key] = tk.StringVar(self.root)
        var = self.drafts[key]
        ttk.Label(frame, text="Reply to this session").pack(anchor="w", pady=(5, 0))
        entry = ttk.Entry(frame, textvariable=var)
        entry.pack(fill="x")
        self.entries[key] = entry
        action = "Copy & open" if self.handoff(pin, var.get()) else "Send"
        button = self.button(frame, action, lambda: self.submit(pin))
        button.pack(anchor="w")
        entry.bind("<Return>", lambda _: self.submit(pin))
        entry.bind("<KeyRelease>", lambda _: button.configure(
            text="Copy & open" if self.handoff(pin, var.get()) else "Send"))
        if ("reply", key) in self.jobs:
            entry.configure(state="disabled")
            button.configure(state="disabled")
        if key in self.feedback:
            tk.Label(frame, text=self.feedback[key], bg=CARD, fg=MUTED, wraplength=220).pack(anchor="w")

    def handoff(self, pin, draft):
        return (pin.provider != "Codex" or self.check_draft.get(pin.key) == draft or
                self.snapshots.get(pin.key, {}).get("state") not in ("ready", "running"))

    def submit(self, pin):
        key = pin.key
        text = self.drafts[key].get()
        if not text.strip() or ("reply", key) in self.jobs:
            return
        if self.handoff(pin, text):
            try:
                self.root.clipboard_clear()
                self.root.clipboard_append(text)
            except tk.TclError:
                self.feedback[key] = "Couldn’t copy draft"
            else:
                self.feedback[key] = "Draft copied · paste in the conversation"
                self.jump(pin)
            self.render()
            return
        def done(outcome):
            if key not in self.drafts:
                return
            if outcome == "sent" and self.drafts[key].get() == text:
                self.drafts[key].set("")
            if outcome in ("uncertain", "openSession"):
                self.check_draft[key] = text
            self.feedback[key] = {"sent": "Sent", "uncertain": "Delivery unconfirmed · check the session",
                                  "openSession": "Open the session to continue",
                                  "invalid": "Reply must fit within 64 KB"}.get(outcome, "Couldn’t send · draft kept")
            self.render()
        self.job(("reply", key), lambda: reply(pin, text), done)
        self.render()

    def show_usage(self, details=None):
        if self.usage_dialog is not None and self.usage_dialog.winfo_exists():
            self.usage_dialog.destroy()
        dialog = self.usage_dialog = tk.Toplevel(self.root)
        dialog.title("Codex account usage")
        dialog.attributes("-topmost", True)
        self.usage_text.set("Reading account limits…")
        if details:
            model = details.get("model") or "Not reported"
            effort = details.get("effort") or "Not reported"
            ttk.Label(dialog, text=f"Model  {model}\nEffort  {effort}", padding=(16, 10)).pack(anchor="w")
        ttk.Label(dialog, textvariable=self.usage_text, padding=16, justify="left").pack()
        ttk.Button(dialog, text="Close", command=dialog.destroy).pack(pady=(0, 10))
        def show(rows):
            lines = [f"{row['label']}  {row['usedPercent']}% used" for row in rows]
            self.usage_text.set("\n".join(lines) or "Account usage unavailable.")
        self.job("Read account usage", account_usage, show)

    def jump(self, pin):
        try:
            os.startfile(pin.url)
        except OSError:
            messagebox.showerror("Open session", "Windows could not open this session. Check its default app.",
                                 parent=self.root)
        else:
            self.collapse()

    def commit(self, change):
        updated = deepcopy(self.library)
        change(updated)
        try:
            updated.save(self.path)
        except (OSError, ValueError) as error:
            messagebox.showerror("Save library", str(error), parent=self.dialog)
            return False
        removed = {p.key for p in self.library.pins} - {p.key for p in updated.pins}
        for key in removed:
            for mapping in (self.drafts, self.feedback, self.check_draft, self.snapshots, self.shown_sentences):
                mapping.pop(key, None)
        self.library = updated
        self.filter_rows()
        self.render()
        return True

    def open_library(self):
        if self.dialog is not None:
            self.dialog.lift()
            self.dialog.focus_force()
            return
        dialog = self.dialog = tk.Toplevel(self.root)
        dialog.title("watchnotch · Session library")
        dialog.attributes("-topmost", True)
        dialog.protocol("WM_DELETE_WINDOW", self.close_library)
        box = ttk.Frame(dialog, padding=12)
        box.pack(fill="both", expand=True)
        ttk.Label(box, text="Search sessions").pack(anchor="w")
        search = ttk.Entry(box, textvariable=self.query)
        search.pack(fill="x", pady=(3, 8))
        search.focus_set()
        ttk.Checkbutton(box, text="Active", variable=self.active_only, command=self.filter_rows).pack(anchor="w")
        list_frame = ttk.Frame(box)
        list_frame.pack(fill="both", expand=True)
        self.listbox = tk.Listbox(list_frame, width=66, height=12, exportselection=False)
        scroll = ttk.Scrollbar(list_frame, command=self.listbox.yview)
        self.listbox.configure(yscrollcommand=scroll.set)
        self.listbox.pack(side="left", fill="both", expand=True)
        scroll.pack(side="right", fill="y")
        self.listbox.bind("<Double-1>", lambda _: self.toggle_pin())
        actions = ttk.Frame(box)
        actions.pack(fill="x", pady=6)
        for title, action in [("Pin / unpin", self.toggle_pin), ("Refresh Codex", self.discover),
                              ("Desktop chats", self.desktop), ("Visited chats", self.history), ("Import export…", self.choose_file)]:
            ttk.Button(actions, text=title, command=action).pack(side="left", padx=(0, 4))
        ttk.Label(box, text="Private ChatGPT link or Codex thread UUID").pack(anchor="w")
        self.link = ttk.Entry(box)
        self.link.pack(fill="x", pady=(2, 6))
        ttk.Label(box, text="Title (optional)").pack(anchor="w")
        self.title = ttk.Entry(box)
        self.title.pack(fill="x", pady=(2, 6))
        ttk.Button(box, text="Pin link", command=self.add_link).pack(anchor="w")
        ttk.Label(box, textvariable=self.status, wraplength=460).pack(anchor="w", pady=(6, 0))
        ttk.Button(box, text="Quit watchnotch", command=self.root.destroy).pack(anchor="e")
        self.filter_rows()
        self.discover()
        self.desktop()

    def close_library(self):
        self.dialog.destroy()
        self.dialog = None

    def filter_rows(self):
        if self.dialog is None:
            return
        term = self.query.get().casefold().strip()
        pasted = None
        if term.startswith("https://"):
            try:
                pasted = from_link(term, "")
                term = pasted.sessionID
            except ValueError:
                pass
        all_rows = dict(self.discovered)
        all_rows.update(self.active_codex)
        all_rows.update(self.library.chats)
        all_rows.update((p.key, p) for p in self.library.pins)
        all_rows.update((key, Session.from_row(row)) for key, row in self.desktop_rows.items())
        if self.active_only.get():
            active = set(self.active_codex)
            active.update(k for k, row in self.desktop_rows.items() if row.get("state") == "running")
            all_rows = {k: v for k, v in all_rows.items() if k in active}
        pins = {p.key for p in self.library.pins}
        selected = self.listbox.curselection()
        old_key = self.rows[selected[0]].key if selected else None
        if pasted and not self.active_only.get():
            all_rows = {pasted.key: all_rows.get(pasted.key, pasted)}
        self.rows = [p for p in all_rows.values()
                     if term in " ".join((p.provider, p.title, p.sessionID)).casefold()]
        self.rows.sort(key=lambda p: (p.key not in pins, -p.updated, p.title.casefold()))
        self.listbox.delete(0, "end")
        for i, p in enumerate(self.rows):
            self.listbox.insert("end", ("Pinned   " if p.key in pins else "") + f"{p.provider}   {p.title}")
            if p.key == old_key:
                self.listbox.selection_set(i)

    def toggle_pin(self):
        selected = self.listbox.curselection()
        if selected:
            row = self.rows[selected[0]]
            def toggle(library):
                if any(p.key == row.key for p in library.pins):
                    library.pins = [p for p in library.pins if p.key != row.key]
                else:
                    library.pin(row)
            self.commit(toggle)

    def add_link(self):
        try:
            row = from_link(self.link.get(), self.title.get())
        except ValueError as error:
            self.status.set(str(error))
            return
        if self.commit(lambda lib: lib.pin(row)):
            self.link.delete(0, "end")
            self.title.delete(0, "end")
            self.status.set("Pinned " + row.title)

    def discover(self):
        self.status.set("Reading local Codex session titles…")
        def done(rows):
            self.discovered = rows
            self.filter_rows()
            self.status.set(f"Found {len(rows)} Codex sessions.")
        self.job("Read Codex sessions", codex_library, done)

    def import_rows(self, name, read):
        self.status.set(name + "…")
        def done(rows):
            if self.commit(lambda lib: lib.import_chats(rows)):
                self.status.set(f"Found {len(rows)} conversation records.")
        self.job(name, lambda: list(read()), done)

    def desktop(self):
        def read():
            try:
                return desktop_catalog()
            except (OSError, ValueError, sqlite3.Error):
                return {}
        def done(rows):
            self.desktop_rows = rows
            self.filter_rows()
            values = {key: {"title": row["title"], "sentence": row["activityText"],
                            "state": row["state"]}
                      for key, row in rows.items() if row.get("activityText")}
            self.updated(values, "ChatGPT")
        self.job("Read desktop catalog", read, done)

    def history(self):
        self.import_rows("Read browser history", lambda: windows_browser_items(
            Path(os.environ["LOCALAPPDATA"]), Path(os.environ["APPDATA"])))

    def choose_file(self):
        filename = filedialog.askopenfilename(parent=self.dialog, filetypes=[
            ("ChatGPT exports", "*.zip *.json"), ("JSON", "*.json"), ("ZIP", "*.zip")])
        if filename:
            self.import_rows("Import conversations", lambda: from_export(Path(filename)))
