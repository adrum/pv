# pv

A fast PHP version manager. `pv` installs a prebuilt, relocatable PHP in
seconds — no compiler, no dependencies — and resolves which version a command
runs under from the directory you are standing in.

```sh
pv install 8.4          # or 8.4.3, or latest
pv pin 8.4              # writes .php-version here
php -v                  # PHP 8.4.x
```

## pv does not replace Composer

`pv` does not resolve dependencies. It is the *runtime* half: getting a correct
PHP onto the machine and pointing the right commands at it. Composer stays, and
`pv` has no opinion about your `vendor/` directory.

It does not ship Composer either — that would mean owning Composer's release
cycle and its `self-update`, for a tool whose version has nothing to do with
PHP's. What `pv` does own is which PHP a PHP tool runs under:

```sh
pv run composer install    # your composer, the resolved PHP
```

A `composer.phar` needs nothing special: its `#!/usr/bin/env php` shebang
already resolves through the shims. A Composer installed by a package manager
usually does need it — those are wrapper scripts with an absolute path to
*that* package manager's PHP baked in, so they ignore `pv` entirely and do it
silently. `pv doctor` looks for exactly this and says so.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/OWNER/pv/main/install.sh | sh
```

It downloads the build for your platform, verifies it against the published
sha256, and puts `pv` in `~/.local/bin` (override with `PV_BIN_DIR`). It does
not touch your shell profile — that line is yours to paste, below.

Or from source:

```sh
cargo build --release
install -m 0755 target/release/pv /usr/local/bin/pv
```

Then put the shims in front of everything else on `PATH`:

```sh
eval "$(pv init zsh)"   # or bash, sh, fish — add this to your shell profile
```

`pv doctor` confirms it worked, and says plainly what to fix when it did not.

## Commands

| | |
|---|---|
| `pv install <version>` | install `8.4`, `8.4.3` or `latest` |
| `pv uninstall <version>` | remove an installed version |
| `pv list` | installed versions, active one marked |
| `pv list --remote` | what can be installed (newest 3 patches per line; `--all` for every one) |
| `pv pin <version>` | write `.php-version` here |
| `pv default <version>` | version used when nothing pins one |
| `pv which [command]` | the binary that would run here, and nothing else |
| `pv run <command> …` | run a command under the resolved version, from the PHP tree or PATH |
| `pv resolve` | the version that would be used here (`--source` says why) |
| `pv init <shell>` | shell setup for `PATH` (`--hook` adds `cd`-time switching) |
| `pv rehash` | regenerate the shims |
| `pv cache status\|prune\|clear` | inspect or clear downloaded tarballs |
| `pv doctor` | check the installation |
| `pv self update` | replace this binary with the newest build |

## How a version is chosen

First match wins:

1. `PV_PHP_VERSION`
2. `.php-version` in the current directory
3. `.php-version` in an ancestor directory
4. `composer.json` (`config.platform.php`, then `require.php`) — a **hint**:
   it holds a constraint, so it selects among installed versions and never
   triggers an install
5. the version set with `pv default`
6. the newest installed version

`pv which` is read-only. It resolves and prints — it never installs, never
writes, never touches the working directory.

When nothing pins a version, `pv` falls back to the newest installed one rather
than failing. A version manager that refuses to run `php -v` in an unpinned
directory is broken, whatever its error message says.

Set `strategy = "local"` in `~/.pv/config.toml` to stop the ancestor walk at
the current directory; the default is `recursive`, which is what monorepos
want.

### Switching on `cd`

Optional, and only ever a convenience:

```sh
eval "$(pv init zsh --hook)"
```

The hook exports `PV_PHP_VERSION` when you enter a directory that pins one, and
clears it when you leave. Correctness does not depend on it — the shims resolve
every process, interactive or not — so if it misbehaves, drop the `--hook` and
nothing else changes.

An explicit `PV_PHP_VERSION` you set yourself is left alone: the hook only ever
manages the value it set.

## Which extensions do I get

These, baked in:

```
apcu bcmath bz2 calendar ctype curl dom exif ffi fileinfo filter ftp gd
gettext gmp iconv igbinary imagick intl ldap mbstring mbregex msgpack
mysqli mysqlnd opcache openssl password-argon2 pcntl pdo pdo_mysql
pdo_pgsql pgsql phar posix readline redis mongodb session shmop simplexml
soap sockets sodium sqlite3 pdo_sqlite ssh2 sysvmsg sysvsem sysvshm tidy
tokenizer uuid xml xmlreader xmlwriter xsl yaml zip zlib
```

Plus **Xdebug**, shipped as a shared `lib/xdebug.so` because it cannot be
linked statically. It is loaded with `xdebug.mode = off`; set `XDEBUG_MODE` for
a single invocation, which Xdebug honors over any ini value.

**`pecl install <anything>` does not work against these builds.** A statically
linked PHP cannot `dlopen` arbitrary extensions, so the list above is the
supported surface. If you need something outside it, open an issue — building
on demand is a real feature and a large one, and it is not in this release.

A few absences are deliberate: `sqlsrv` (Microsoft's ODBC driver is dylib-only
on macOS) and `pcov` (shared-only, like Xdebug — use `xdebug.mode=coverage`).

## Platforms

| Platform | Status |
|---|---|
| `darwin-arm64` | supported, 7.4 → 8.5 |
| `linux-x86_64` | supported, 7.4 → 8.4 |
| `linux-arm64` | built on a native runner; treat as newer |
| `darwin-x86_64` | built on a native runner; treat as newer |
| Windows | not yet — a different toolchain entirely |

Linux builds link glibc rather than static musl, because static musl has no
`dlopen` and therefore no Xdebug. The trade is a glibc floor: binaries need a
glibc at least as new as the build image's.

## What stays installable

Every patch that has ever been published stays published. `pv list --remote`
shows the newest three per line to keep the listing readable, and `--all` shows
the rest — but the trimming is cosmetic: any published version installs by
exact version, whether or not the listing mentions it.

That matters because `.php-version` holds an exact patch and gets committed.
Withdrawing old patches would break those pins on any machine that had not
already installed them — a fresh CI runner, a new laptop — which is precisely
the case pinning exists to protect.

## Integrity

Every artifact is published with its sha256 in `manifest.json`, and `pv`
verifies before extracting. Verification **fails closed** — an entry with a
missing, empty or malformed hash is an error, not a reason to skip the check.
The installed hash is recorded next to the extracted tree, so a rebuilt
artifact is detected and reinstalled, and `pv doctor` can report tampering.

Be clear-eyed about what that buys: the hash ships in the manifest it protects,
so anyone able to rewrite the manifest rewrites both. It defends the artifact
given a trustworthy manifest. Tamper evidence independent of the hosting
account needs a signed manifest, which is not in this release.

## Layout

Everything lives under `~/.pv` (override with `PV_HOME`), and every generated
file is plain text you can read and grep:

```
~/.pv/
  versions/8.4.3/bin/php     extracted runtimes
  shims/php                  real files on PATH
  cache/                     downloaded tarballs
  config.toml                default version, resolve strategy
```

Shims are real files rather than a shell hook because PHP has to resolve
correctly *outside* an interactive shell — editors, language servers, CI
runners, cron jobs and git hooks inherit `PATH` and nothing else. Each shim
carries a `# managed-by: pv` marker, and `pv` never removes a file it did not
write.

## Building the runtimes

```sh
./build/build-php.sh 8.4 darwin-arm64
```

Produces `dist/php-<version>-<platform>.tar.gz` with a `.sha256` sidecar, after
verifying that every requested extension is present, that nothing links a
build-host-only library, and that the tree still works from a directory it has
never seen. `BUILD-NOTES.md` documents the landmines.

## No telemetry

`pv` reports nothing anywhere. It talks to the network when you install,
update, or ask for `--remote`, and not otherwise.
