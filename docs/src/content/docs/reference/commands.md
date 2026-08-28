---
title: Commands
description: Every pv command.
---

## Versions

| | |
|---|---|
| `pv install <version>` | install `8.4`, `8.4.3` or `latest` (`--force` reinstalls) |
| `pv uninstall <version>` | remove an installed version |
| `pv list` | installed versions, the active one marked with its source |
| `pv list --remote` | what can be installed — newest 3 patches per line, `--all` for every one |

Older patches stay installable by exact version whether or not the listing
shows them. The trimming is cosmetic, because `.php-version` holds an exact
patch and gets committed.

## Choosing

| | |
|---|---|
| `pv pin <version>` | write `.php-version` in the current directory |
| `pv default [<version>]` | show or set the version used when nothing pins one |
| `pv resolve` | print the version that would be used here |
| `pv resolve --source` | …and what chose it |
| `pv resolve --pinned-only` | print nothing unless a file or the environment pins one |

## Running

| | |
|---|---|
| `pv which [command]` | the binary that would run here, and nothing else |
| `pv run <command> …` | run a command under the resolved version |
| `pv exec <command> …` | alias of `run` |

`run` looks inside the resolved PHP first, then falls back to `PATH` — which is
what makes `pv run composer install` work without pv shipping Composer. When it
falls back, the resolved PHP's `bin` goes first on `PATH` and `PV_PHP_VERSION`
is set, so the tool and anything it spawns agree on one PHP.

## Setup

| | |
|---|---|
| `pv init <shell>` | shell setup for `PATH` — zsh, bash, sh, fish |
| `pv init <shell> --hook` | …plus the optional `cd`-time switch |
| `pv rehash` | regenerate the shims |
| `pv doctor` | check the installation, exit non-zero on a real problem |

## Maintenance

| | |
|---|---|
| `pv cache status` | what the download cache holds |
| `pv cache prune` | remove tarballs no installed version came from |
| `pv cache clear` | remove every cached tarball |
| `pv self update` | replace this binary with the newest published build |

## Environment

| | |
|---|---|
| `PV_PHP_VERSION` | override resolution entirely |
| `PV_HOME` | where pv keeps state (default `~/.pv`) |
| `PV_MANIFEST_URL` | where to look for artifacts |

## Layout

Everything lives under `~/.pv`, and every generated file is plain text you can
read and grep:

```
~/.pv/
  versions/8.4.3/bin/php     extracted runtimes
  versions/8.4.3/licenses/   third-party license texts
  shims/php                  real files on PATH
  cache/                     downloaded tarballs
  config.toml                default version, resolve strategy
```
