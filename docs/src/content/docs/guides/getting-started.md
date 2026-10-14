---
title: Getting started
description: Install pv, get a PHP, and put the shims on PATH.
banner:
  content: 'pv is pre-release: until 1.0, commands and file formats may still change between versions.'
---

## Install pv

```sh
curl -fsSL https://raw.githubusercontent.com/adrum/pv/main/install.sh | sh
```

On Windows, in PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -c "irm https://raw.githubusercontent.com/adrum/pv/main/install.ps1 | iex"
```

Either script downloads the build for your platform, verifies it against the
published sha256, and puts `pv` in `~/.local/bin` (override with `PV_BIN_DIR`).
Neither touches your shell profile or `PATH` — that line is yours to paste,
below.

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

On Windows, add this to your PowerShell `$PROFILE` instead:

```powershell
pv init powershell | Out-String | Invoke-Expression
```

`cmd`, editors and anything started outside PowerShell read the user `PATH`,
so put `%USERPROFILE%\.pv\shims` at the front of that as well (`pv doctor`
prints the exact directory), then open a new terminal.

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
