---
title: Scripting pv
description: Exit codes and JSON output, for callers that are programs rather than people.
---

pv is meant to be driven by other software — a site manager asking which PHP a
project wants, a CI script, an editor plugin. Two things make that reliable:
exit codes that distinguish *why* something failed, and output that does not
change meaning when a sentence gets reworded.

## Exit codes

```sh
pv resolve >/dev/null 2>&1
case $? in
  0)  ;;                        # fine
  10) pv install "$(cat .php-version)" ;;   # pinned, not installed
  13) echo "network down, retry later" ;;
  15) sleep 5 ;;                # another pv is installing, retry
  *)  echo "pv failed" ;;
esac
```

| Code | Meaning | What a caller should do |
|---|---|---|
| `0` | Success | — |
| `1` | Any failure without a more specific code | Report it |
| `2` | Bad arguments | Fix the invocation |
| `10` | Resolved a version, but it is not installed | Install it |
| `11` | Nothing installed, and nothing to fall back to | Install anything |
| `12` | No such version is published for this platform | Pick another; `pv list --remote` |
| `13` | Network — connection, DNS, TLS, or a bad response | Retry later |
| `14` | Verification — a checksum mismatched or was missing | **Stop.** Do not retry blindly |
| `15` | Another pv process holds the lock | Retry shortly; nothing is wrong |

These numbers are interface. They are asserted as literals in pv's tests, so
changing one fails the build rather than quietly breaking you.

Codes are added where the kind of failure is actually known. Anything else
exits `1`, so a future release may give a currently-`1` failure a specific
code — treat `1` as "unknown", not as a stable category.

## JSON output

`--format json` works on the commands a script would call: `resolve`, `which`,
`list` and `doctor`.

```sh
$ pv resolve --format json
{
  "binary": "/Users/you/.pv/versions/8.4.21/bin/php",
  "pinned": true,
  "source": "composer",
  "source_path": "/Users/you/code/app/composer.json",
  "version": "8.4.21"
}
```

`source` is the field worth knowing about: it answers "why am I getting this
version?" without a second command. Its values are stable identifiers rather
than the prose a terminal shows — `environment`, `version-file`, `composer`,
`default`, `newest-installed`.

### The rule that makes it usable

**Data on stdout, diagnostics on stderr, always.** Progress, warnings and
errors never land in stdout, so `pv ... --format json 2>/dev/null` is always
either valid JSON or nothing. Under `--format json`, pv also suppresses the
human-facing chatter entirely — it is a machine's view, not a decorated one.

### Two behaviors to rely on

`pv resolve --pinned-only --format json` prints `null` rather than nothing when
no file or environment variable pins a version, so a caller can parse
unconditionally.

`pv list --remote --format json` returns the **whole** catalogue, not the
newest-three-per-line view a terminal gets. The trimming exists to keep a
listing readable; handing a program a subset would make it miss versions it can
install perfectly well.
