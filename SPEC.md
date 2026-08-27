# pv — a fast PHP version manager

## What this is

`pv` installs and switches PHP versions in seconds, on any machine, without a
compiler. It downloads a prebuilt, relocatable PHP for the host platform,
places it under a managed directory, and resolves which version a command runs
under from the directory the user is standing in.

The reference points are `uv` (Python) and `rv` (Ruby): a single static Rust
binary, no runtime dependencies, no shell integration required, sub-second
version switching.

## What this is NOT

**`pv` does not resolve dependencies. Composer stays.**

This is the single most important boundary in the project, and the one most
likely to be misread — `uv`'s reputation comes primarily from replacing pip's
resolver, so "the uv of PHP" invites the assumption that `pv` replaces
Composer. It does not, and should not try to. Composer's solver handles
platform requirements, `replace`/`provide`/`conflict` semantics, VCS
repositories and path repositories; reimplementing it correctly is a multi-year
effort with a large blast radius when it is subtly wrong.

`pv` is the *runtime* half: getting a correct PHP onto the machine and pointing
the right commands at it. If a dependency-resolution story ever happens, it is
a separate product decision made long after this one ships.

Other explicit non-goals for v1:

- No web server, process supervisor, or site management.
- No `php.ini` opinionation beyond shipping a sane default per version.
- No Windows in the first release (see Platform reality).

## CLI surface

Model the verbs on `rv` and `uv` — users arriving from either should guess right.

```
pv install <version>        # 8.4, 8.4.3, or "latest"
pv uninstall <version>
pv list                     # installed, marked with the active one
pv list --remote            # installable
pv pin <version>            # write .php-version here
pv which [command]          # the resolved binary path, no side effects
pv run <command> [args...]  # run under the resolved version
pv exec                     # alias of run, if it reads better
pv self update
```

Two design rules learned the hard way, both worth honoring from the start:

**`pv which` must be read-only.** It should resolve and print, never install,
never create state, never touch the working directory. A read-only resolution
command is what makes shims possible (below) and what lets scripts ask "what
would run here?" cheaply. Resist the temptation to have it auto-install a
missing version.

**Falling back beats failing.** When nothing pins a version, resolve to the
newest installed rather than erroring. A version manager that refuses to run
`php -v` in an unpinned directory is experienced as broken, and the error text
("can't find version in dotfiles") does not tell a newcomer what to do.

## Version resolution

Resolve in this order, first match wins:

1. `PV_PHP_VERSION` environment variable (explicit override, wins over all)
2. `.php-version` in the current directory
3. `.php-version` in any ancestor directory (walk up; make the strategy
   configurable — `local` vs `recursive` — since monorepos want the latter)
4. `composer.json` → `config.platform.php`, then `require.php`, as a *hint*
   only. Both are constraints (`^8.2`), not versions; resolve to the newest
   installed version satisfying the constraint, and never auto-install from it.
5. The user's default (`pv default <version>`)
6. Newest installed

Write `.php-version` as a bare version string, one line, no `php-` prefix. If a
prefix ever appears in your own output, strip it before display and before
using it in commands — a prefixed version leaking into the UI looks like a bug
and breaks copy-paste.

## PATH integration: shims

The hard requirement: **PHP must resolve correctly outside an interactive
shell.** Editors, language servers, CI runners, cron jobs, git hooks and GUI
apps inherit `PATH` and nothing else. A shell hook (`eval "$(pv init zsh)"`,
zsh `preexec`, `chpwd`) only ever fires in an interactive shell, so anything
launched outside one silently falls through to a system PHP — often an ancient
one — with no error.

So ship **shims**: real files on `PATH` that delegate resolution to `pv`.

```sh
#!/bin/sh
# generated — do not edit
exec /path/to/pv run php "$@"
```

Shim `php`, `php-config`, `phpize`, `php-fpm` (where present), and `composer`
if `pv` ever bundles it. Keep the shim body minimal and mark it with a comment
so a later sweep can distinguish your files from a user's — a version manager
that deletes something it did not create is unforgivable, and file identity is
the only reliable way to tell.

Three failure modes to design against, all of which bite in practice:

- **PATH order.** A shim directory placed after `/usr/bin` or a package
  manager's prefix is silently shadowed by the system PHP. Whatever `pv init`
  writes must *prepend*, must be idempotent, and must be verifiable — provide
  `pv doctor` that reports the resolved `php` and says plainly when something
  else owns the name.
- **Stale shell hashes.** Shells cache command locations. After the first
  install, `php` may resolve to a path recorded before the shim existed, or to
  a deleted one, and `which php` can print nothing at all. Tell the user to run
  `hash -r` (or open a new shell) in the post-install message.
- **Quoting.** Shim paths can contain spaces. Single-quote the interpreter path
  in generated scripts and test with a directory that has a space in it.

Offer the shell hook too, for users who want `cd`-time switching, but never
make correctness depend on it.

## Distribution

GitHub Releases, built by GitHub Actions.

- One release per PHP build wave; assets named
  `php-<version>-<os>-<arch>.tar.gz`.
- A `manifest.json` listing every artifact with its **sha256**, published
  alongside. The client verifies before extracting and refuses on mismatch.
- Verification must **fail closed**. A manifest entry with an empty or missing
  hash is an error, not a reason to skip verification. Guarding the check with
  "if a hash is present" is a one-line change that quietly disables integrity
  for any malformed entry.
- Record the installed artifact's hash next to the extracted tree. That lets
  you detect a rebuilt-but-same-version artifact and re-install it, and it
  makes `pv doctor` able to report tampering.
- Be clear-eyed about what hashing buys: it protects the *artifact* given a
  trustworthy manifest. Since the hash ships in the manifest it protects,
  anyone able to rewrite the manifest rewrites both. If you want tamper
  evidence independent of the hosting account, sign the manifest (minisign or
  Sigstore) and ship the public key in the client binary.

**Upstream tag selection.** When resolving "latest" from upstream tags, apply a
minimum age — take the newest tag that is at least 24 hours old rather than the
newest tag outright. This narrows the window in which a compromised or
immediately-yanked release gets picked up, and it costs nothing when upstream
released last week. Note that a `releases/latest` redirect gives you a tag with
no timestamp, so this requires the API's `published_at` (rate-limited
unauthenticated; use the Actions token).

## Platform reality

Static PHP does not build everywhere equally, and the matrix is where schedule
risk lives. Known-good today:

| Platform | Status |
|---|---|
| `darwin-arm64` | Builds cleanly, 7.4 → 8.5 |
| `linux-x86_64` | Builds cleanly, 7.4 → 8.4 |
| `linux-arm64` | Needs a **native** runner — cross-compiling PHP to arm64 from an amd64 host is not practical (configure/build assumptions break) |
| `darwin-x86_64` | Untried; expect it to work on a native runner |
| `windows` | Untried, different toolchain entirely; treat as a separate project phase |

Budget CI accordingly: seven PHP lines × N platforms is a large matrix, the
builds are long, and macOS runner minutes are the expensive ones. Cache the
build tree aggressively, keyed on PHP line + platform.

## Extensions — read this before promising anything

This is the biggest product risk, and it deserves a decision made deliberately
rather than discovered late.

A statically linked PHP cannot `dlopen` arbitrary extensions. That means
**`pecl install <anything>` cannot work** against a fully static build. Users
will expect it to. It will be the first issue filed.

The workable answers, in order of increasing ambition:

1. **Bake in a broad extension set** and document it as the supported surface.
   This covers the overwhelming majority of real applications and is what
   shipping products in this space do. See `BUILD-NOTES.md` for a set that is
   known to build.
2. **Link against glibc rather than static musl on Linux**, which restores
   `dlopen` and lets you ship *some* extensions as loadable `.so` files —
   Xdebug being the one that matters most, since it cannot be linked statically
   at all. The trade is a glibc floor on the resulting binary (see build notes).
3. **Build-on-demand for extensions outside the set** — a real feature, and a
   large one. Do not promise it in v1.

Whatever you choose, say it plainly in the README. "Which extensions do I get"
is the first question a serious user asks.

## Suggested milestones

1. **Client skeleton** — `install`/`list`/`pin`/`which`/`run` against
   hand-uploaded tarballs for one platform. Proves the resolution model.
2. **Shims + doctor** — the correctness story above, including a space in the
   path and a stale-hash message.
3. **Build pipeline** — Actions matrix producing verified artifacts and a
   signed manifest for `darwin-arm64` and `linux-x86_64`.
4. **Widen the matrix** — native arm64 Linux, then macOS x86_64.
5. **Extension story** — whichever answer you picked, documented and tested.

## Style constraints

- Rust, single static binary, no runtime dependencies.
- No telemetry.
- Every generated file (shims, `.php-version`, manifests) is plain text a human
  can read and a script can grep.
- Error messages name the next action. "No version found" is a bad error;
  "no PHP pinned here and none installed — run `pv install 8.4`" is a good one.
