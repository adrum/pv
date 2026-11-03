#!/usr/bin/env python3
"""Plan a build wave: which (PHP line × platform) builds need doing.

    LINES=8.3,8.4 PLATFORMS=darwin-arm64,linux-x86_64 ./build/plan.py

Prints `matrix=<json>` and `count=<n>` for $GITHUB_OUTPUT.

A build is redone only when something that goes into it has changed. Each one
gets a fingerprint of its inputs: the PHP release it builds, the files that
build it, the backports revision and the Xdebug or php.net Windows build it
takes in, and a four-week period, so that libraries fetched at their latest
version are still picked up monthly. The published manifest records the
fingerprint of every artifact, and a build whose fingerprint matches is left
as published. FORCE=true rebuilds regardless.

Skipping is what keeps a weekly wave from rebuilding thirty-odd artifacts
that come out the same, and from telling every user their PHP has a new build
when nothing in it changed.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def _load_resolver():
    # resolve-php-version.py is a script with a hyphenated name, not a module.
    # Loading it must not leave a __pycache__ in build/.
    import importlib.util

    sys.dont_write_bytecode = True

    spec = importlib.util.spec_from_file_location("resolve_php_version", ROOT / "build/resolve-php-version.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.resolve


_resolve = _load_resolver()

RUNNERS = {
    "darwin-arm64": "macos-14",
    "darwin-x86_64": "macos-15-intel",
    "linux-x86_64": "ubuntu-22.04",
    "linux-arm64": "ubuntu-22.04-arm",
    # Repackages php.net's build rather than compiling, and runs the result,
    # which only a Windows runner can do. Lines with backports are the
    # exception; see runner() below.
    "windows-x86_64": "windows-latest",
    # Compiled natively: php.net publishes no arm64 build.
    "windows-arm64": "windows-11-arm",
}

# php-src's Windows build system knows arm64 from 8.2. An earlier line builds
# for windows-arm64 once pv carries a port of that support for it, in
# build/windows/arm64/; until then Windows on Arm runs its x64 build under
# emulation.
WINDOWS_ARM64_NATIVE = (8, 2)


def arm64_port(line: str) -> str | None:
    path = f"build/windows/arm64/php-{line}.patch"
    return path if (ROOT / path).exists() else None


def buildable(line: str, platform: str) -> bool:
    if platform != "windows-arm64":
        return True
    return tuple(map(int, line.split("."))) >= WINDOWS_ARM64_NATIVE or arm64_port(line) is not None

# The files each kind of build reads. A change to one rebuilds only the
# builds that read it.
UNIX_FILES = [
    "build/build-php.sh",
    "build/spc-patches.sh",
    "build/verify-php.sh",
    "build/install-musl.sh",
    "build/fetch-backports.sh",
    "build/resolve-php-version.py",
]
WINDOWS_PACKAGE_FILES = [
    "build/build-php.sh",
    "build/package-php-windows.sh",
    "build/cached-download.sh",
    "build/windows/pecl.lock",
    "build/resolve-php-version.py",
]
WINDOWS_SOURCE_FILES = WINDOWS_PACKAGE_FILES + [
    "build/build-php-windows.sh",
    "build/cached-download.sh",
    "build/windows/Get-PhpSrc.ps1",
    "build/windows/pecl-source.lock",
    "build/fetch-backports.sh",
    "build/spc-patches.sh",
]

# Rebuild everything this often anyway: static-php-cli and php.net fetch
# some libraries at their latest version, which no fingerprint can see.
REFRESH_DAYS = 28

WINDOWS_FEED = "https://windows.php.net/downloads/releases/releases.json"
XDEBUG_INDEX = "https://xdebug.org/download/historical"
SALSA = "https://salsa.debian.org/php-team/php.git"


def fetch(url: str) -> str:
    with urllib.request.urlopen(url, timeout=60) as response:
        return response.read().decode("utf-8", "replace")


def has_backports(line: str) -> bool:
    return (ROOT / f"build/backports/php-{line}.list").exists()


def compiled_on_windows(line: str, platform: str) -> bool:
    return platform == "windows-arm64" or (platform == "windows-x86_64" and has_backports(line))


def runner(line: str, platform: str) -> str:
    # Lines with backports are compiled for Windows x64 with php.net's
    # php-windows-builder, which supports their vc15/vs16 toolsets on
    # windows-2022.
    if platform == "windows-x86_64" and has_backports(line):
        return "windows-2022"
    return RUNNERS[platform]


def files_digest(paths: list[str]) -> str:
    digest = hashlib.sha256()
    for path in sorted(set(paths)):
        digest.update(path.encode() + b"\0" + (ROOT / path).read_bytes() + b"\0")
    return digest.hexdigest()


class Upstream:
    """Lookups shared by every build in the wave, each made once."""

    def __init__(self) -> None:
        self._versions: dict[str, str] = {}
        self._backports: dict[str, str] = {}
        self._feed: dict | None = None
        self._xdebug: str | None = None

    def version(self, line: str) -> str:
        if line not in self._versions:
            try:
                self._versions[line] = _resolve(line)
            except Exception as error:  # noqa: BLE001 — as resolve-php-version.py degrades
                print(f"note: could not resolve PHP {line} ({error})", file=sys.stderr)
                self._versions[line] = line
        return self._versions[line]

    def backports(self, line: str) -> str:
        if line not in self._backports:
            out = subprocess.run(
                ["git", "ls-remote", SALSA, f"refs/heads/debian/main/{line}"],
                capture_output=True, text=True, check=True, timeout=120,
            ).stdout.split()
            if not out:
                raise SystemExit(f"error: salsa has no debian/main/{line} branch")
            self._backports[line] = out[0]
        return self._backports[line]

    def windows_build(self, line: str) -> str:
        """php.net's Windows zip for the line: its name and sha256."""
        if self._feed is None:
            self._feed = json.loads(fetch(WINDOWS_FEED))
        entry = self._feed.get(line) or {}
        builds = [v for k, v in entry.items() if re.fullmatch(r"nts-v[cs]\d+-x64", k) and isinstance(v, dict)]
        if len(builds) != 1:
            raise SystemExit(f"error: the Windows feed has no single nts x64 build of PHP {line}")
        zip_ = builds[0].get("zip") or {}
        return f"{zip_.get('path')} {zip_.get('sha256')}"

    def xdebug(self, line: str) -> str:
        """Every stable Xdebug published for the line, so a new one rebuilds."""
        if self._xdebug is None:
            self._xdebug = fetch(XDEBUG_INDEX)
        found = re.findall(rf"php_xdebug-(\d+\.\d+\.\d+)-{re.escape(line)}-[^']*\.dll", self._xdebug)
        return max(found, key=lambda v: tuple(map(int, v.split("."))), default="")


def fingerprint(line: str, platform: str, upstream: Upstream) -> tuple[str, str]:
    inputs: dict[str, str] = {
        "line": line,
        "platform": platform,
        "period": str(int(time.time() // 86400) // REFRESH_DAYS),
    }
    if platform.startswith("windows-"):
        compiled = compiled_on_windows(line, platform)
        files = WINDOWS_SOURCE_FILES if compiled else WINDOWS_PACKAGE_FILES
        if platform == "windows-arm64" and arm64_port(line):
            files = files + [arm64_port(line)]
        inputs["xdebug"] = upstream.xdebug(line)
        if compiled:
            version = upstream.version(line)
            inputs["php"] = version
        else:
            # php.net's own build: its zip is the input, rebuilds included.
            inputs["php.net"] = upstream.windows_build(line)
            version = ""
    else:
        files = UNIX_FILES
        version = upstream.version(line)
        inputs["php"] = version
    if has_backports(line) and (not platform.startswith("windows-") or compiled_on_windows(line, platform)):
        files = files + [f"build/backports/php-{line}.list"]
        inputs["backports"] = upstream.backports(line)
    inputs["files"] = files_digest(files)
    blob = json.dumps(inputs, sort_keys=True).encode()
    return hashlib.sha256(blob).hexdigest(), version


def published(manifest_url: str) -> dict[tuple[str, str], str]:
    """(line, platform) → the fingerprint of the newest published build."""
    try:
        manifest = json.loads(fetch(manifest_url))
    except Exception as error:  # noqa: BLE001 — no manifest means build everything
        print(f"note: could not read the published manifest ({error}); building everything",
              file=sys.stderr)
        return {}
    newest: dict[tuple[str, str], tuple[tuple[int, ...], str]] = {}
    for version, builds in (manifest.get("php") or {}).items():
        try:
            key = tuple(int(part) for part in version.split("."))
        except ValueError:
            continue
        line = ".".join(version.split(".")[:2])
        for platform, entry in builds.items():
            if (line, platform) not in newest or key > newest[(line, platform)][0]:
                newest[(line, platform)] = (key, (entry or {}).get("inputs", ""))
    return {k: v[1] for k, v in newest.items()}


def main() -> int:
    lines = [l.strip() for l in os.environ["LINES"].split(",") if l.strip()]
    platforms = [p.strip() for p in os.environ["PLATFORMS"].split(",") if p.strip()]
    force = os.environ.get("FORCE", "").lower() in ("1", "true", "yes")
    unknown = [p for p in platforms if p not in RUNNERS]
    if unknown:
        raise SystemExit(f"no runner mapped for: {unknown}")

    current = {} if force else published(os.environ["MANIFEST_URL"])
    upstream = Upstream()
    include = []
    for platform in platforms:
        for line in lines:
            if not buildable(line, platform):
                print(f"skip  {line} {platform}: not buildable yet", file=sys.stderr)
                continue
            inputs, version = fingerprint(line, platform, upstream)
            if not force and current.get((line, platform)) == inputs:
                print(f"skip  {line} {platform}: unchanged", file=sys.stderr)
                continue
            print(f"build {line} {platform}", file=sys.stderr)
            include.append({
                "line": line,
                "platform": platform,
                "runner": runner(line, platform),
                "version": version,
                "inputs": inputs,
            })
    print("matrix=" + json.dumps({"include": include}))
    print(f"count={len(include)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
