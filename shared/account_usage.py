"""Display the signed-in Codex account's reported usage windows on either platform."""


def window_label(minutes, slot):
    if type(minutes) is not int or minutes <= 0:
        return slot.capitalize() + " window"
    if minutes == 1440:
        return "Daily"
    if minutes == 10080:
        return "Weekly"
    for size, unit in ((1440, "day"), (60, "hour"), (1, "minute")):
        if minutes % size == 0:
            return f"{minutes // size}-{unit}"


def usage_windows(reply):
    """Prefer named buckets, with the historical default as a fallback."""
    by_id = reply.get("rateLimitsByLimitId")
    buckets = dict(by_id) if isinstance(by_id, dict) else {}
    legacy = reply.get("rateLimits") or {}
    if legacy and legacy not in buckets.values():
        buckets.setdefault(legacy.get("limitId") or "codex", legacy)
    rows = []
    for key, bucket in sorted(buckets.items()):
        if not isinstance(bucket, dict):
            continue
        for slot in ("primary", "secondary"):
            window = bucket.get(slot)
            if not isinstance(window, dict):
                continue
            used = window.get("usedPercent")
            if type(used) is not int or not 0 <= used <= 100:
                continue
            label = window_label(window.get("windowDurationMins"), slot)
            name = bucket.get("limitName") or key
            if len(buckets) > 1 or key != "codex":
                label = f"{name} · {label}"
            rows.append({"label": label, "usedPercent": used})
    return rows


def read_usage(server):
    reply = server.call("account/rateLimits/read", {"excludeResetCreditDetails": True})
    return usage_windows(reply)
