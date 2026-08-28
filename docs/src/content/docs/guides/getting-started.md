---
title: Getting started
description: Install pv, get a PHP, and put the shims on PATH.
---

## Install pv

```sh
curl -fsSL https://raw.githubusercontent.com/adrum/pv/main/install.sh | sh
```

The script downloads the build for your platform, verifies it against the
published sha256, and puts `pv` in `~/.local/bin` (override with `PV_BIN_DIR`).
It does not touch your shell profile — that line is yours to paste, below.

From source instead:

```sh
cargo build --release
install -m 0755 target/release/pv /usr/local/bin/pv
```

## Get a PHP

```sh
pv install 8.4          # newest 8.4.x
pv install 8.4.3        # exactly this one
pv install latest       # newest published
```

## Put the shims on PATH

```sh
eval "$(pv init zsh)"   # or bash, sh, fish
```

Add that to your shell profile. It **prepends** pv's shim directory, which
matters: a shim directory placed after `/usr/bin` or a package manager's prefix
is silently shadowed by whatever PHP is already there.

Then open a new shell — or run `hash -r`, because shells cache command
locations and yours may still remember a `php` from before pv existed.

```sh
pv doctor
```

Doctor confirms it worked and says plainly what to fix when it did not.

## Pin a version for a project

```sh
cd ~/code/legacy-app
pv pin 7.4
php -v                  # PHP 7.4.x, here and below
```

`pv pin` writes a `.php-version` file — a bare version string, one line.
Commit it, and everyone on the project gets the same runtime.

## Run a tool under the resolved PHP

```sh
pv run composer install
```

Your Composer, the PHP this directory resolves to. pv does not ship Composer;
a `composer.phar` already works through the shims, and this is for the
package-manager wrappers that hardcode their own PHP.
