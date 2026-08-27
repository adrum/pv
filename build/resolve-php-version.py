#!/usr/bin/env python3
"""Print the newest patch of a PHP line that is old enough to build.

    ./build/resolve-php-version.py 8.4      ->  8.4.12

Releases younger than the minimum age are skipped. That window is when a
compromised or immediately-yanked release is most likely to be picked up, and
waiting it out costs nothing when upstream released last week. php.net's
release feed is used rather than GitHub tags because it carries a publication
date and is not rate-limited — a `releases/latest` redirect gives you a tag
with no timestamp at all, which is exactly the field this needs.

Falls back to printing the line unchanged, so a feed outage degrades to
"let the build engine pick" rather than failing the wave.
"""

from __future__ import annotations

import json
import sys
import urllib.request
from datetime import datetime, timedelta, timezone

FEED = "https://www.php.net/releases/index.php?json&max=20&version={line}"
MINIMUM_AGE = timedelta(hours=24)


def released_at(entry: dict) -> datetime | None:
    """php.net dates look like `03 Apr 2025` — day granularity, UTC."""
    raw = entry.get("date")
    if not isinstance(raw, str):
        return None
    try:
        return datetime.strptime(raw, "%d %b %Y").replace(tzinfo=timezone.utc)
    except ValueError:
        return None


def resolve(line: str) -> str:
    with urllib.request.urlopen(FEED.format(line=line), timeout=30) as response:
        feed = json.load(response)

    # The feed is keyed by version, except when a single release comes back
    # keyed by the line itself.
    candidates: list[tuple[tuple[int, ...], str]] = []
    cutoff = datetime.now(timezone.utc) - MINIMUM_AGE
    for key, entry in feed.items():
        if not isinstance(entry, dict):
            continue
        version = entry.get("version") if key == line else key
        if not isinstance(version, str) or version.count(".") != 2:
            continue
        date = released_at(entry)
        if date is None or date > cutoff:
            continue
        candidates.append((tuple(int(part) for part in version.split(".")), version))

    if not candidates:
        raise LookupError(f"no PHP {line} release older than {MINIMUM_AGE}")
    return max(candidates)[1]


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print("usage: resolve-php-version.py <line>", file=sys.stderr)
        return 2
    line = argv[1]
    try:
        print(resolve(line))
    except Exception as error:  # noqa: BLE001 — degrade, never block the wave
        print(f"note: falling back to {line} ({error})", file=sys.stderr)
        print(line)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
