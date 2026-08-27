#!/usr/bin/env python3
"""Assemble manifest.json from built artifacts.

    ./build/gen-manifest.py --dist dist \
        --base-url https://github.com/<owner>/pv/releases/download/<tag> \
        --merge https://github.com/<owner>/pv/releases/latest/download/manifest.json \
        --out dist/manifest.json

Artifacts are named `<kind>-<version>-<platform>.tar.gz` and must sit next to
a `.sha256` sidecar. Merging the previously published manifest is what keeps
older PHP versions installable after a wave that only rebuilt some of them —
without it, a partial wave silently unpublishes everything it did not rebuild.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import urllib.request
from pathlib import Path

ARTIFACT = re.compile(
    r"^(?P<kind>php|pv)-(?P<version>\d+\.\d+\.\d+)-(?P<platform>[a-z0-9_]+-[a-z0-9_]+)\.tar\.gz$"
)
SCHEMA = 1


def read_sha256(sidecar: Path) -> str:
    """First field of a shasum(1) line."""
    text = sidecar.read_text().strip()
    if not text:
        raise SystemExit(f"{sidecar} is empty")
    digest = text.split()[0]
    if len(digest) != 64 or not all(c in "0123456789abcdef" for c in digest.lower()):
        raise SystemExit(f"{sidecar} does not contain a sha256: {digest!r}")
    return digest.lower()


def load_previous(source: str | None) -> dict:
    if not source:
        return {}
    try:
        if source.startswith(("http://", "https://")):
            with urllib.request.urlopen(source, timeout=30) as response:
                return json.load(response)
        return json.loads(Path(source).read_text())
    except Exception as error:  # noqa: BLE001 — any failure means "nothing to merge"
        print(f"note: no previous manifest merged ({error})", file=sys.stderr)
        return {}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--dist", required=True, type=Path)
    parser.add_argument("--base-url", required=True)
    parser.add_argument("--merge", help="URL or path of the manifest to merge into")
    parser.add_argument("--out", required=True, type=Path)
    args = parser.parse_args()

    manifest = load_previous(args.merge)
    manifest["schema"] = SCHEMA
    manifest.setdefault("php", {})
    manifest.setdefault("pv", {})

    added = 0
    for tarball in sorted(args.dist.glob("*.tar.gz")):
        match = ARTIFACT.match(tarball.name)
        if not match:
            print(f"note: skipping {tarball.name}", file=sys.stderr)
            continue
        sidecar = tarball.with_suffix(tarball.suffix + ".sha256")
        if not sidecar.exists():
            raise SystemExit(f"{tarball.name} has no .sha256 sidecar — refusing to publish it")

        kind, version, platform = match["kind"], match["version"], match["platform"]
        entry = {
            "file": tarball.name,
            "url": f"{args.base_url.rstrip('/')}/{tarball.name}",
            "sha256": read_sha256(sidecar),
            "size": tarball.stat().st_size,
        }
        # A rebuilt artifact replaces the published one for that platform,
        # which is how a fixed build reaches machines that already installed
        # the broken one: the recorded hash no longer matches and pv reinstalls.
        manifest[kind].setdefault(version, {})[platform] = entry
        added += 1

    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    print(f"wrote {args.out} ({added} artifacts this wave, "
          f"{sum(len(p) for p in manifest['php'].values())} php entries total)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
