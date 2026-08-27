# Building relocatable PHP

Field notes for the build pipeline. Everything here was learned by hitting the
failure, not by reading documentation — the failures are mostly silent, mostly
toolchain-version-dependent, and mostly cost hours each. Treat this as a list
of landmines with their locations marked.

## Toolchain

Use [static-php-cli](https://github.com/crazywhalecc/static-php-cli) (`spc`) as
the build engine. It handles source fetching, dependency libraries, and the
configure/make dance. You are not writing a PHP build system; you are driving
`spc` and patching around the places where PHP's older source trees meet newer
system libraries.

Broad shape of a build:

```
spc download --for-extensions="<ext list>" --with-php=<line>
spc doctor --auto-fix
spc build "<ext list>" --build-cli --build-fpm --build-shared=xdebug
```

Then repackage the result (see Packaging).

## The libc decision (Linux) — decide this first

`spc` defaults to statically linked **musl** on Linux. Static musl has **no
`dlopen`**. Consequences:

- `--build-shared=xdebug` is refused outright: *"Static musl libc does not
  implement dlopen"*. Every Linux job dies at this point once it gets past
  doctor.
- Xdebug **cannot be linked statically** either — `spc` reports *"Extension
  [xdebug] does not support static build!"*. So there is no static path to a
  PHP with Xdebug.

If you want Xdebug (you do — it is the single most requested PHP extension and
a debugger is table stakes), you need a libc with `dlopen`, which means
**glibc**:

```sh
export SPC_LIBC=glibc
```

**The trade:** the resulting `php` is dynamically linked against glibc and
requires a host glibc at least as new as the build image's. Building on Debian
bookworm produces binaries needing **2.36**, which will not run on Ubuntu 22.04
(2.35) or older. Pick the build image deliberately — moving back a release
lowers the floor and widens compatibility, at the cost of older system
libraries during the build.

macOS has no equivalent problem; Xdebug ships as a shared `lib/xdebug.so`
loaded via `zend_extension`.

### If you do use musl anyway

`spc doctor` installs a musl wrapper by downloading from `musl.libc.org` — a
single unmirrored host that is regularly unreachable from CI. The symptom is a
135-second connect timeout followed by `Fix failed: Download failed ... code:
28`, before anything compiles. Pre-install musl yourself into `/usr/local/musl`
(doctor probes for `/usr/local/musl/lib/libc.a` plus
`/lib/ld-musl-<arch>.so.1`) so its fixer never runs. Fetch the tarball from a
mirror that stays up — Debian's pool works — pinned by sha256, and apply the
distribution CVE patches for the version you pin. A mirror you do not control
is only acceptable with a pinned hash.

## Source patches

Older PHP lines do not compile against newer system libraries. These are the
patches that matter, with the failure each one fixes. Apply them after
`spc download`, before `spc build`.

### libxml2 2.13+ vs PHP 7.4 / 8.0

**`ATTRIBUTE_UNUSED` removed.** libxml2 ≤2.12 defined it as a compatibility
macro; 2.13 removed it. PHP 7.4/8.0's `ext/libxml/libxml.c` uses it
unconditionally, and clang treats the unknown identifier as part of the
function declarator — the parse fails with `expected ')'`. Fix: define the
macro at the top of `libxml.c` rather than depending on libxml2 exporting it.

**`const` on error signatures.** libxml2 2.13 added `const` to
`xmlStructuredErrorFunc` and made `xmlGetLastError()` return
`const xmlError *`. PHP 7.4/8.0 still use the non-const `xmlErrorPtr`, which
clang 16+ treats as a hard error
(`-Werror=incompatible-function-pointer-types`). Fix: rewrite the affected
signatures in `ext/libxml/libxml.c` to take `const xmlError *`.

### Deprecation attributes

Newer libxml2 and OpenSSL 3.x headers carry deprecation attributes in positions
older PHP source does not expect; clang fails with `expected ')'` while parsing
struct definitions (`ext/libxml`) or when `ext/openssl` uses deprecated 3.0
APIs. The APIs still work — only the attribute breaks the parse. Fix: neuter
the attribute in the headers.

Patch **both** the source trees *and* the buildroot copies. Patching only the
source tree works until `spc` skips the library rebuild on a later run and uses
the already-installed buildroot header, at which point the failure returns and
looks unrelated to your change.

### ICU 77+ and C++17

`ext/intl` needs a C++17 standard flag against newer ICU. Without it you get a
wall of template errors that read like an ICU bug and are not one.

### Stale `.la` paths

If you repackage a dependency library through a temporary prefix, the libtool
`.la` archives installed into the buildroot embed that **absolute temp path**
in `dependency_libs`. The temp directory does not survive cleanup, and libtool
hard-fails chasing the dead reference when linking `libphp` (the embed SAPI) on
a later `--rebuild`. Fix: rewrite dead references to point at `buildroot/lib`,
where the same archives actually live. Leave references to directories that
still exist alone.

### PHP 7.4 specifics

- `ext/gd`'s configure test needs patching on modern toolchains.
- On arm64, PHP 7.4's `buildconf` needs a hook to regenerate correctly.

## Extension set

A set known to build across 7.4 → 8.5:

```
apcu bcmath bz2 calendar ctype curl dom exif ffi fileinfo filter ftp gd
gettext gmp iconv igbinary imagick intl ldap mbstring mbregex msgpack
mysqli mysqlnd opcache openssl password-argon2 pcntl pdo pdo_mysql
pdo_pgsql pgsql phar posix readline redis mongodb session shmop simplexml
soap sockets sodium sqlite3 pdo_sqlite ssh2 sysvmsg sysvsem sysvshm tidy
tokenizer uuid xml xmlreader xmlwriter xsl yaml zip zlib
```

Notes that cost real time:

- **`mbregex` is its own `spc` extension**, not a flag on `mbstring`. Adding
  the `oniguruma` library alone leaves `mbstring` configured with
  `--disable-mbregex`, so `mb_split()` / `mb_ereg()` are undefined at runtime.
  The build succeeds; applications fail later with a fatal error on a common
  string helper. Include `mbregex` explicitly.
- **`imagick`** is the heaviest item — `spc` bundles ImageMagick and its format
  dependencies, many of which `gd` already pulls in. It is the most likely to
  need stripping for a *newly released* PHP line, because the pinned imagick
  release often does not support it yet.
- **`sqlsrv`** cannot be included on macOS: Microsoft's ODBC driver is
  dylib-only.
- **Xdebug** is shared-only. Ship it as `lib/xdebug.so` and default
  `xdebug.mode` to something harmless. Note that `xdebug.mode=debug` makes
  every request try to reach a debug client and log a warning when none is
  listening — pick your default with that in mind, and **validate any
  user-supplied mode against Xdebug's allowed values before writing it to a
  config file**, or a typo silently disables the extension with a startup
  error.

## Packaging

Ship a tarball whose contents are wrapped in a single top-level directory —
`spc` extracts with `--strip-components 1`, so a flat archive lands its files
in the wrong place. Strip symlinks before packaging; they do not survive some
extraction paths and produce confusing partial installs.

Layout inside the archive:

```
<root>/
  bin/php
  bin/php-config
  bin/php-fpm        (where built)
  lib/xdebug.so      (where built)
  etc/php.ini        (a sane default)
```

Keep the tree **relocatable**: nothing may depend on an absolute path chosen at
build time. Verify it — extract to a randomly named directory and run
`php -v`, `php -m`, and a script that touches `intl`, `openssl` and `pdo_mysql`.

## Verification, per build

Automate all of these; each has shipped broken at least once when skipped.

- `php -v` runs and reports the expected version.
- `php -m` lists every extension you asked for. Diff against the requested
  list — a missing extension is a silent build regression, and the build exits
  0.
- **No links to system package manager prefixes.** Run `otool -L` (macOS) or
  `ldd` (Linux) and fail the build on any reference to `/opt/homebrew`,
  `/usr/local/opt` or similar. This is the single most valuable check in the
  pipeline: a binary that links a build-host-only library works perfectly in CI
  and fails on every user's machine.
- Extract to a fresh path and re-run the above, to catch relocation problems.

## Failure modes worth detecting explicitly

- **Corrupt downloaded tarballs.** Validate archives before use and delete
  rather than retry-in-place; a partially downloaded `.txz` produces a
  bewildering compile error hundreds of lines later.
- **Stale buildroot.** A buildroot left over from a different PHP line or a
  failed run causes mismatched headers and link errors that look like source
  bugs. Guard on it and wipe when the fingerprint does not match.
- **`spc doctor --auto-fix` reaching the network.** It will, at the worst
  moment. Pre-install what it probes for wherever you can.

## CI shape

- Matrix on (PHP line × platform). Cache the `spc` build tree keyed on both,
  plus the ref — cold builds are long.
- Let a single failing line fail *soft* if you publish incrementally, so one
  broken PHP version does not block the whole wave. Make the failure loud in
  the summary; a soft failure that nobody notices is how a version silently
  stops being published.
- Native runners per architecture. Do not attempt arm64 PHP from an amd64 host.
