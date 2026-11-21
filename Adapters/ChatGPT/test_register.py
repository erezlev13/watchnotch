import json
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory
from register import conversation_id, register

FIRST = "https://chatgpt.com/c/11111111-1111-4111-8111-111111111111"
SECOND = "https://chatgpt.com/c/22222222-2222-4222-8222-222222222222"


class RegistrationTests(unittest.TestCase):
    def test_independent_sessions_and_idempotent_reimport(self):
        with TemporaryDirectory() as folder:
            directory = Path(folder)
            first = register(FIRST + "?tracking=ignored#selection", "Mock research", directory)
            second = register(SECOND, "Mock research", directory)
            initial = first.read_bytes()
            self.assertEqual(register(FIRST + "/", "Mock research", directory), first)
            self.assertEqual(initial, first.read_bytes())
            self.assertEqual(len(list(directory.glob("*.json"))), 2)
            self.assertNotEqual(first, second)
            record = json.loads(initial)
            self.assertEqual(record["sessionURL"], FIRST)
            self.assertEqual(record["state"], "unavailable")
            self.assertNotIn("request", record)
            self.assertEqual(first.stat().st_mode & 0o777, 0o600)
            register(FIRST, "Revised name", directory)
            self.assertEqual(json.loads(first.read_bytes())["title"], "Revised name")

    def test_only_direct_links(self):
        for link in (FIRST.replace("/c/", "/share/"), FIRST + "/more", FIRST.replace("https:", "http:"),
                     FIRST.replace("chatgpt.com", "chatgpt.com.example.org"), FIRST.replace("/c/", "/c/%2f")):
            with self.subTest(link=link), self.assertRaises(ValueError):
                conversation_id(link)


if __name__ == "__main__":
    unittest.main()
