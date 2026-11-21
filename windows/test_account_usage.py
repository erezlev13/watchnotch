import unittest
from unittest.mock import Mock

from companion import read_usage


class AccountUsageTests(unittest.TestCase):
    def test_named_windows_and_buckets_use_reported_percent(self):
        server = Mock()
        regular = {"limitId": "codex", "primary": {"usedPercent": 0, "windowDurationMins": 300},
                   "secondary": {"usedPercent": 100, "windowDurationMins": 10080}}
        server.call.return_value = {"rateLimits": regular, "rateLimitsByLimitId": {
            "codex": regular, "other": {"limitName": "Extra", "primary": {"usedPercent": 7, "windowDurationMins": 1440}}}}
        self.assertEqual(read_usage(server), [
            {"label": "codex · 5-hour", "usedPercent": 0},
            {"label": "codex · Weekly", "usedPercent": 100},
            {"label": "Extra · Daily", "usedPercent": 7}])
        server.call.assert_called_once_with("account/rateLimits/read", {"excludeResetCreditDetails": True})

    def test_legacy_unknown_duration_and_missing_usage(self):
        server = Mock()
        server.call.return_value = {"rateLimits": {"secondary": {"usedPercent": 12}}}
        self.assertEqual(read_usage(server), [{"label": "Secondary window", "usedPercent": 12}])
        for window in ({}, {"usedPercent": True}, {"usedPercent": -1}, {"usedPercent": 101}):
            server.call.return_value = {"rateLimits": {"primary": window}, "rateLimitsByLimitId": {}}
            self.assertEqual(read_usage(server), [])
