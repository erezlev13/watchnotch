import os
from pathlib import Path
import sys
from tempfile import TemporaryDirectory
import tkinter as tk
import unittest
from unittest.mock import patch

from companion import Library, Session
from panel import Panel


@unittest.skipUnless(sys.platform == "win32" or os.environ.get("WATCHNOTCH_TEST_UI") == "1",
                     "Requires a desktop session")
class PanelTests(unittest.TestCase):
    def test_account_usage_window(self):
        with TemporaryDirectory() as tmp:
            root = tk.Tk()
            try:
                panel = Panel(root, Path(tmp) / "library.json")
                def complete(_name, read, display):
                    display(read())
                with patch.object(panel, "job", side_effect=complete), patch("panel.account_usage") as usage:
                    usage.return_value = [{"label": "Weekly", "usedPercent": 14}]
                    panel.show_usage()
                    self.assertEqual(panel.usage_text.get(), "Weekly  14% used")
                    panel.usage_dialog.destroy()
                    usage.return_value = []
                    panel.show_usage()
                    self.assertEqual(panel.usage_text.get(), "Account usage unavailable.")
            finally:
                root.destroy()

    def test_pinned_drafts_uncertain_send_and_chat_handoff(self):
        codex = Session("Codex", "11111111-1111-4111-8111-111111111111", "Code")
        chat = Session("ChatGPT", "22222222-2222-4222-8222-222222222222", "Chat")
        with TemporaryDirectory() as tmp:
            root = tk.Tk()
            try:
                panel = Panel(root, Path(tmp) / "library.json")
                panel.library.pins = [codex, chat]
                panel.snapshots[codex.key] = {"state": "ready"}
                panel.toggle()
                panel.drafts[codex.key].set("Codex draft")
                panel.drafts[chat.key].set("Chat draft")
                panel.collapse()
                panel.toggle()
                def complete(_name, read, display):
                    display(read())
                with patch.object(panel, "job", side_effect=complete), patch("panel.reply", return_value="uncertain") as send:
                    panel.submit(codex)
                    send.assert_called_once_with(codex, "Codex draft")
                    with patch.object(root, "clipboard_clear"), patch.object(root, "clipboard_append") as copy, patch.object(panel, "jump") as jump:
                        panel.submit(codex)
                        jump.assert_called_once_with(codex)
                        panel.submit(chat)
                        self.assertEqual(copy.call_args.args, ("Chat draft",))
                        self.assertEqual(jump.call_args.args, (chat,))
                    self.assertEqual(send.call_count, 1)
                self.assertEqual(panel.drafts[codex.key].get(), "Codex draft")
            finally:
                root.destroy()

    def test_chat_monitor_goes_quiet_disconnects_and_recovers(self):
        chat = Session("ChatGPT", "22222222-2222-4222-8222-222222222222", "Work")
        row = dict(provider=chat.provider, sessionID=chat.sessionID, title=chat.title, updated=10, work=True)
        with TemporaryDirectory() as tmp:
            root = tk.Tk()
            try:
                panel = Panel(root, Path(tmp) / "library.json")
                panel.library.pins = [chat]
                def complete(_name, read, display):
                    display(read())
                with patch.object(panel, "job", side_effect=complete), patch("panel.desktop_catalog") as catalog:
                    for changes, state in [
                        ({"connected": True, "state": "running", "activityText": "Writing a response"}, "running"),
                        ({"connected": True}, "monitoring"), ({"connected": False}, "offline"),
                        ({"connected": True, "state": "ready", "activityText": "A new response is ready"}, "ready"),
                    ]:
                        catalog.return_value = {chat.key: dict(row, **changes)}
                        panel.desktop()
                        self.assertEqual(panel.snapshots[chat.key]["state"], state)
                    catalog.side_effect = OSError("catalog unavailable")
                    panel.desktop()
                    self.assertEqual(panel.snapshots[chat.key]["state"], "offline")
            finally:
                root.destroy()

    def test_open_library_pin_collapse_reopen_and_remove(self):
        with TemporaryDirectory() as tmp, patch.object(Panel, "discover"):
            root = tk.Tk()
            try:
                path = Path(tmp) / "library.json"
                panel = Panel(root, path)
                panel.open_library()
                panel.link.insert(0, "https://chatgpt.com/c/11111111-1111-4111-8111-111111111111")
                panel.title.insert(0, "Test conversation")
                panel.add_link()
                self.assertEqual(Library.load(path).pins[0].title, "Test conversation")
                panel.close_library()
                panel.toggle()
                root.update_idletasks()
                self.assertTrue(panel.expanded)
                with patch("panel.os.startfile", create=True) as launch:
                    panel.jump(panel.library.pins[0])
                    launch.assert_called_once_with(panel.library.pins[0].url)
                self.assertFalse(panel.expanded)
                panel.open_library()
                panel.query.set("conversation")
                panel.listbox.selection_set(0)
                panel.toggle_pin()
                self.assertEqual(Library.load(path).pins, [])
            finally:
                root.destroy()
