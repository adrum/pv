---
title: How a version is chosen
description: The resolution order, and the two rules that hold it together.
---

First match wins:

1. `PV_PHP_VERSION`
2. `.php-version` in the current directory
3. `.php-version` in an ancestor directory
4. Composer, as a **hint** — `composer.json` (`config.platform.php`, then
   `require.php`), then `composer.lock` (`platform-overrides.php`, then
   `platform.php`)
5. the version set with `pv default`
6. the newest installed version

`pv resolve --source` answers "why this one?":

```sh
$ pv resolve --source
7.4.33 (/Users/you/code/legacy/.php-version)
```

## Two rules

**Resolution is read-only.** `pv which` and `pv resolve` resolve and print —
they never install, never write, never touch the working directory. That is
what makes the shims cheap and lets scripts ask "what would run here?" without
side effects.

**Falling back beats failing.** When nothing pins a version, pv uses the newest
installed one rather than erroring. A version manager that refuses to run
`php -v` in an unpinned directory is experienced as broken, whatever its error
message says.

## The Composer hint

`composer.json` and `composer.lock` hold *constraints*, not versions. So they
select among versions you already have, and never trigger an install:

- A constraint nothing satisfies is skipped, and resolution moves on.
- A malformed file is skipped too — it is only ever a hint.
- Inside each file, the platform override beats the requirement, because an
  override is what Composer itself resolves against.
- A bare `"8.2.20"` means *exactly* 8.2.20, following Composer's semantics
  rather than semver's, where it would mean `^8.2.20`.

The lock is a real fallback rather than a duplicate: a deployed tree often
ships the lock without the manifest, and a `composer.json` that fails to parse
should not hide a lock that parses fine.

`pv doctor` reports when a project's constraint matches nothing installed —
resolution stays silent about it, because that path has to work for `run` and
`which`.

## Ancestor search

The default strategy is `recursive`: pv walks up to the filesystem root looking
for `.php-version`, which is what monorepos want. Set `strategy = "local"` in
`~/.pv/config.toml` to stop at the current directory.

Note that **every** `.php-version` in scope is checked before any
`composer.json` — a root pin beats a package's constraint.

## Switching on `cd`

Optional, and only ever a convenience:

```sh
eval "$(pv init zsh --hook)"
```

The hook exports `PV_PHP_VERSION` when you enter a directory that pins one and
clears it when you leave. Correctness never depends on it — the shims resolve
every process, interactive or not — so if it misbehaves, drop `--hook` and
nothing else changes. A `PV_PHP_VERSION` you set yourself is left alone; the
hook only manages the value it set.
