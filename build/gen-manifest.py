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


def load_previous(source: str) -> dict:
    """The published manifest, or an error.

    Failing to *fetch* it is fatal. A transient API error would otherwise be
    indistinguishable from "there is nothing to merge", and the wave would
    publish a manifest holding only what it just built — silently unpublishing
    every version it did not touch. Starting from nothing has to be an explicit
    decision (`--allow-empty`), taken once when the release is bootstrapped.
    """
    try:
        if source.startswith(("http://", "https://")):
            with urllib.request.urlopen(source, timeout=30) as response:
                payload = response.read()
        else:
            payload = Path(source).read_bytes()
    except Exception as error:  # noqa: BLE001 — network, filesystem, anything
        raise SystemExit(
            f"error: could not read the published manifest at {source} ({error}).\n"
            "Refusing to publish: this would unpublish every version this wave "
            "did not rebuild. Retry, or pass --allow-empty if this really is the "
            "first wave."
        ) from error

    try:
        manifest = json.loads(payload)
    except json.JSONDecodeError as error:
        raise SystemExit(
            f"error: the published manifest at {source} is not valid JSON ({error}). "
            "Fix it by hand rather than overwriting it — the entries it holds are "
            "the only record of what is currently published."
        ) from error

    if not isinstance(manifest, dict):
        raise SystemExit(f"error: the published manifest at {source} is not an object")
    return manifest


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--dist", required=True, type=Path)
    parser.add_argument("--base-url", required=True)
    parser.add_argument("--merge", help="URL or path of the manifest to merge into")
    parser.add_argument(
        "--allow-empty",
        action="store_true",
        help="start from nothing — only correct when no manifest is published yet",
    )
    parser.add_argument("--out", required=True, type=Path)
    args = parser.parse_args()

    if bool(args.merge) == args.allow_empty:
        raise SystemExit("error: pass exactly one of --merge and --allow-empty")

    manifest = load_previous(args.merge) if args.merge else {}
    carried = sum(len(platforms) for platforms in manifest.get("php", {}).values())
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

    if args.merge and added == 0:
        print("note: this wave produced no artifacts; republishing the manifest unchanged",
              file=sys.stderr)

    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    total = sum(len(platforms) for platforms in manifest["php"].values())
    print(
        f"wrote {args.out}: {added} artifacts this wave, {carried} php entries carried "
        f"forward, {total} php entries published"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
