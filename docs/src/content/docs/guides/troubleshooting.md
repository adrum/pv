---
title: Troubleshooting
description: The failures that are silent, and what to do about them.
---

Start with `pv doctor`. Every check it runs exists because the corresponding
failure is silent — none of them announce themselves, and all of them look
like "pv doesn't work".

## `php` still points somewhere else

Two causes, in order of likelihood.

**A stale shell hash.** Shells cache command locations, so `php` may resolve to
a path recorded before the shims existed — or to a deleted one, in which case
`which php` prints nothing at all.

```sh
hash -r     # or open a new shell
```

**PATH order.** Something earlier on `PATH` owns the name `php`. Doctor names
the file:

```
problem another php comes before pv's shims: /opt/homebrew/bin/php
        move ~/.pv/shims earlier in PATH, or remove the other php
```

`pv init` prepends, so the usual cause is a later line in your profile putting
another prefix in front.

## Composer ignores pv

A `composer.phar` resolves `php` through `PATH` and therefore through pv. A
Composer installed by a package manager is usually a wrapper script with an
absolute path to *that* package manager's PHP baked in — it keeps using that
PHP whatever pv resolves, silently.

```
warn  composer at /opt/homebrew/bin/composer is bound to
      /opt/homebrew/Cellar/php/8.3.0/bin/php and ignores pv
```

Either run it as `pv run composer …`, or install `composer.phar`.

## A version is pinned but not installed

```
pv: PHP 8.3.1 is required by /path/.php-version but is not installed —
    run `pv install 8.3.1`
```

That one is deliberate: an explicit pin that cannot be honored is an error
rather than a silent fallback to a different version.

## `pecl install` fails

It cannot work. These builds are statically linked, so PHP cannot `dlopen` an
extension that was not compiled in. The [extension list](/pv/reference/extensions/)
is the supported surface.

## An install seems stuck behind another

```
pv: another pv process is already installing PHP 8.4.3 — wait for it to
    finish, then try again
```

Two pv processes cannot install the same version at once — an editor's language
server and a terminal can easily both try. The lock is released when the other
process exits, however it exits.

## Reclaiming disk

```sh
pv cache status     # what the downloads take up
pv cache prune      # drop tarballs nothing is installed from
pv cache clear      # drop all of them
```

Cached tarballs are only ever a download shortcut; clearing them never affects
an installed PHP.
