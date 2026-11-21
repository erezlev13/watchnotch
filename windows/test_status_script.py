import unittest
from status_script import StatusScript


class StatusScriptTest(unittest.TestCase):
    def test_queued_updates_wait_for_reveal_and_read(self):
        script = StatusScript()
        script.receive("First", 0, True)
        script.receive("Second", 0.2, True)
        script.receive("Second", 0.3, True)
        script.receive("Third", 0.4, True)
        self.assertAlmostEqual(script.progress(0.675), 0.5)
        script.reveal(1)
        script.advance(2.5, True)
        self.assertEqual(script.current, "First")
        script.advance(2.6, True)
        self.assertEqual(script.current, "Second")
        script.advance(script.deadline, False)
        script.advance(script.deadline, False)
        self.assertEqual((script.current, script.phase), ("Third", "reading"))
        script.advance(script.deadline, False)
        self.assertIsNone(script.deadline)
