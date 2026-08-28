#!/bin/bash
set -euo pipefail

# Build one relocatable PHP for one platform and package it as a pv artifact.
#
#   ./build/build-php.sh 8.4 [darwin-arm64]
#
# Output: dist/php-<full-version>-<platform>.tar.gz plus a .sha256 sidecar.
# The artifact is named by the *full* version (8.4.3) because that is what pv
# installs and pins by; the argument is a line (8.4) because that is what
# upstream publishes and what CI matrices are written against.

PHP_LINE="${1:-}"
PLATFORM="${2:-}"

if [[ -z "${PHP_LINE}" ]]; then
    echo "usage: $0 <php-line> [platform]   e.g. $0 8.4 darwin-arm64" >&2
    exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [[ -z "${PLATFORM}" ]]; then
    case "$(uname -s)-$(uname -m)" in
        Darwin-arm64)  PLATFORM="darwin-arm64" ;;
        Darwin-x86_64) PLATFORM="darwin-x86_64" ;;
        Linux-aarch64) PLATFORM="linux-arm64" ;;
        Linux-x86_64)  PLATFORM="linux-x86_64" ;;
        *) echo "error: cannot infer a platform from $(uname -s)-$(uname -m)" >&2; exit 1 ;;
    esac
fi

# Cross-compiling PHP to another architecture is not practical — configure and
# build assumptions break in ways that surface as unrelated compile errors.
# Every architecture gets a native runner.
HOST_ARCH="$(uname -m)"
case "${PLATFORM}" in
    *-arm64)  WANT_ARCH="arm64|aarch64" ;;
    *-x86_64) WANT_ARCH="x86_64|amd64" ;;
esac
if ! echo "${HOST_ARCH}" | grep -qE "^(${WANT_ARCH})$"; then
    echo "error: ${PLATFORM} needs a native ${WANT_ARCH} runner; this host is ${HOST_ARCH}" >&2
    exit 1
fi

SPC_DIR="${SPC_DIR:-${ROOT_DIR}/.spc-cache/${PHP_LINE}-${PLATFORM}}"
DIST_DIR="${ROOT_DIR}/dist"
STAGE_DIR="${ROOT_DIR}/.build/${PHP_LINE}-${PLATFORM}"

# --- The libc decision (Linux) -------------------------------------------
# spc defaults to a statically linked musl on Linux, and static musl has no
# dlopen: `--build-shared=xdebug` is refused outright ("Static musl libc does
# not implement dlopen"), and Xdebug cannot be linked statically either
# ("Extension [xdebug] does not support static build!"). There is therefore no
# static path to a PHP with a debugger, and a debugger is table stakes — so
# Linux builds link glibc.
#
# The trade: the resulting php needs a host glibc at least as new as the build
# image's. Debian bookworm produces binaries requiring 2.36, which will not run
# on Ubuntu 22.04 (2.35) or older. Move the build image back a release to lower
# the floor.
if [[ "${PLATFORM}" == linux-* ]]; then
    export SPC_LIBC="${SPC_LIBC:-glibc}"
    echo ">>> Linux libc: ${SPC_LIBC}"
fi

# --- Extension set --------------------------------------------------------
# This is the supported surface. A statically linked PHP cannot dlopen
# arbitrary extensions, so `pecl install <anything>` does not work against
# these builds and what is baked in here is what users get. See the README.
#
# Notes that cost real time:
#   - mbregex is its OWN spc extension, not a flag on mbstring. Adding the
#     oniguruma library alone leaves mbstring at --disable-mbregex, so
#     mb_split()/mb_ereg() are undefined at runtime — the build succeeds and
#     applications fail later on a common string helper.
#   - sqlsrv is absent because Microsoft's ODBC driver is dylib-only on macOS.
#   - pcov is absent for the same reason as xdebug: spc only builds it shared,
#     so listing it as a static extension hard-fails the build. Coverage comes
#     from xdebug.mode=coverage.
DEFAULT_EXTENSIONS="apcu,bcmath,bz2,calendar,ctype,curl,dom,exif,ffi,fileinfo,filter,ftp,gd,imagick,gettext,gmp,iconv,igbinary,intl,ldap,mbstring,mbregex,msgpack,mysqli,mysqlnd,opcache,openssl,password-argon2,pcntl,pdo,pdo_mysql,pdo_pgsql,pgsql,phar,posix,readline,redis,mongodb,session,shmop,simplexml,soap,sockets,sodium,sqlite3,pdo_sqlite,ssh2,sysvmsg,sysvsem,sysvshm,tidy,tokenizer,uuid,xml,xmlreader,xmlwriter,xsl,yaml,zip,zlib"
EXTENSIONS="${PHP_EXTENSIONS:-${DEFAULT_EXTENSIONS}}"

# Xdebug is shared-only, and shipped at lib/xdebug.so.
SHARED_EXTENSIONS="${PHP_SHARED_EXTENSIONS:-xdebug}"

# onig is what flips mbstring's configure to --enable-mbregex; libavif gives
# GD its AVIF codec (PHP 8.1+ only — stripped for older lines below).
EXTRA_LIBS="${PHP_EXTRA_LIBS:-onig,libavif}"

# Xdebug source override, for PHP lines the newest Xdebug dropped.
XDEBUG_URL=""

strip_ext() {
    EXTENSIONS="$(echo "${EXTENSIONS}" | tr ',' '\n' | grep -v "^$1$" | paste -sd, -)"
}

# Per-line adjustments. Extensions enforce minimum PHP versions; stripping the
# offenders keeps an older line building instead of failing the whole wave.
case "${PHP_LINE}" in
    7.4)
        strip_ext opcache          # shared-only before 8.0; spc refuses to bundle it
        strip_ext mongodb          # spc pins mongodb 2.x, which needs PHP 8.1+
        strip_ext password-argon2  # argon2 detection cannot find spc's libargon2 before 8.1
        EXTRA_LIBS="${EXTRA_LIBS//,libavif/}"  # GD's --with-avif is 8.1+
        # Xdebug 3.2 dropped PHP 7.x and spc always resolves the newest
        # release, which is how 7.4 ends up with no debugger at all. A legacy
        # site is precisely where stepping through code still matters, so pin
        # the last 3.1 rather than ship without one.
        XDEBUG_URL="https://xdebug.org/files/xdebug-3.1.6.tgz"
        # Xdebug 3.1.6 declares `void xdebug_develop_minit();` and calls it
        # with two arguments. Legal under C17, where an empty parameter list
        # means "unspecified"; a hard error under C23, which redefines it as
        # (void). spc builds shared extensions through phpize, which runs the
        # system autoconf — and autoconf 2.72's AC_PROG_CC probes editions
        # newest-first, landing -std=gnu23 in the Makefile. Seeding the C23
        # probe as "no" makes it fall through to C11; pinning an explicit C11
        # flag stops a future compiler default from silently taking over.
        export SPC_EXTRA_PHP_VARS="${SPC_EXTRA_PHP_VARS:+${SPC_EXTRA_PHP_VARS} }ac_cv_prog_cc_c23=no ac_cv_prog_cc_c11=-std=gnu11"
        ;;
    8.0)
        strip_ext mongodb
        strip_ext password-argon2
        EXTRA_LIBS="${EXTRA_LIBS//,libavif/}"
        # Xdebug 3.5 dropped 8.0, not 3.4 — pin the last 3.4.
        XDEBUG_URL="https://xdebug.org/files/xdebug-3.4.7.tgz"
        ;;
esac

# --- spc ------------------------------------------------------------------
# Pinned to v2: the v3 alphas ship broken source-URL resolvers for libiconv and
# php-src, which fail late and look like network problems.
case "${PLATFORM}" in
    darwin-arm64)  SPC_ASSET="spc-macos-aarch64" ;;
    darwin-x86_64) SPC_ASSET="spc-macos-x86_64" ;;
    linux-arm64)   SPC_ASSET="spc-linux-aarch64" ;;
    linux-x86_64)  SPC_ASSET="spc-linux-x86_64" ;;
    *) echo "error: unsupported platform ${PLATFORM}" >&2; exit 1 ;;
esac
SPC_URL="https://dl.static-php.dev/static-php-cli/spc-bin/nightly/${SPC_ASSET}"

_maybe_sudo() { if [[ "$(id -u)" -eq 0 ]]; then "$@"; else sudo "$@"; fi; }
install_spc() {
    _maybe_sudo mkdir -p /usr/local/bin
    curl -fsSL -o /tmp/spc "${SPC_URL}"
    _maybe_sudo install -m 0755 /tmp/spc /usr/local/bin/spc
    rm -f /tmp/spc
}
if ! command -v spc >/dev/null 2>&1; then
    echo ">>> installing spc"
    install_spc
elif spc --version 2>/dev/null | grep -qE '(^|[^0-9])3\.[0-9]'; then
    echo ">>> spc v3 detected; rolling back to v2"
    install_spc
fi

mkdir -p "${SPC_DIR}/downloads"
cd "${SPC_DIR}"

# spc resolves several sources through the GitHub API, which rate-limits
# unauthenticated requests to 60/hr per IP. Parallel matrix jobs blow past that
# and get a 403 that reads like a missing file.
if [[ -z "${GITHUB_TOKEN:-}" ]]; then
    echo ">>> warning: GITHUB_TOKEN unset — spc's GitHub API calls may hit the" >&2
    echo "    60/hr unauthenticated rate limit and fail as a confusing 403." >&2
fi

# Ask for a specific patch rather than "newest in the line", skipping releases
# younger than a day: that window is when a yanked or compromised release gets
# picked up, and waiting it out costs nothing.
PHP_TARGET="$(python3 "${SCRIPT_DIR}/resolve-php-version.py" "${PHP_LINE}")"
echo ">>> resolving sources for PHP ${PHP_TARGET}"
attempts=0
until spc download \
    --with-php="${PHP_TARGET}" \
    --for-extensions="${EXTENSIONS}${SHARED_EXTENSIONS:+,${SHARED_EXTENSIONS}}" \
    ${EXTRA_LIBS:+--for-libs="${EXTRA_LIBS}"} \
    ${XDEBUG_URL:+--custom-url="xdebug:${XDEBUG_URL}"} \
    ${XDEBUG_URL:+--ignore-cache-sources=xdebug}
do
    attempts=$((attempts + 1))
    if [[ "${attempts}" -ge 4 ]]; then
        echo "error: spc download failed after ${attempts} attempts" >&2
        exit 1
    fi
    echo ">>> spc download failed (attempt ${attempts}); retrying in 10s"
    sleep 10
done

# musl, only when actually linking it. Installed here, from a mirror and by
# pinned hash, so spc doctor's own fixer — which knows only musl.libc.org, a
# single unmirrored host that is regularly unreachable from CI — never runs.
if [[ "${PLATFORM}" == linux-* && "${SPC_LIBC:-}" != "glibc" ]]; then
    "${SCRIPT_DIR}/install-musl.sh"
fi

if [[ "${PLATFORM}" == linux-* && "$(id -u)" -ne 0 ]]; then
    sudo -E spc doctor --auto-fix
    sudo chown -R "$(id -u):$(id -g)" "${SPC_DIR}"
else
    spc doctor --auto-fix
fi

# The patch layer is macOS-specific: it repackages pre-built libraries whose
# darwin .txz archives arrive corrupt, and applies the clang / libxml2 2.13 /
# ICU 77 source fixes with arm64 flags. Linux uses spc's native prebuilts,
# where the darwin-keyed names and flags would misfire.
case "${PLATFORM}" in
    darwin-*)
        # shellcheck disable=SC1091
        source "${SCRIPT_DIR}/spc-patches.sh"
        apply_all_spc_patches
        ;;
esac

echo ">>> building PHP ${PHP_TARGET} with: ${EXTENSIONS}"
spc build "${EXTENSIONS}" --build-cli --build-fpm --rebuild \
    ${EXTRA_LIBS:+--with-libs="${EXTRA_LIBS}"} \
    ${SHARED_EXTENSIONS:+--build-shared="${SHARED_EXTENSIONS}"}

PHP_BIN="${SPC_DIR}/buildroot/bin/php"
FPM_BIN="${SPC_DIR}/buildroot/bin/php-fpm"
[[ -x "${PHP_BIN}" ]] || { echo "error: spc build produced no php binary" >&2; exit 1; }

PHP_VERSION="$("${PHP_BIN}" -r 'echo PHP_VERSION;')"
echo ">>> built PHP ${PHP_VERSION}"

# --- Package --------------------------------------------------------------
# The tarball wraps everything in one top-level directory: pv extracts with the
# first component stripped, so a flat archive lands its files in the wrong
# place.
ARCHIVE_ROOT="php-${PHP_VERSION}-${PLATFORM}"
TARBALL="${ARCHIVE_ROOT}.tar.gz"
rm -rf "${STAGE_DIR}"
mkdir -p "${STAGE_DIR}/${ARCHIVE_ROOT}/bin" "${STAGE_DIR}/${ARCHIVE_ROOT}/etc"

cp "${PHP_BIN}" "${STAGE_DIR}/${ARCHIVE_ROOT}/bin/php"
[[ -x "${FPM_BIN}" ]] && cp "${FPM_BIN}" "${STAGE_DIR}/${ARCHIVE_ROOT}/bin/php-fpm"
for helper in php-config phpize; do
    [[ -f "${SPC_DIR}/buildroot/bin/${helper}" ]] &&
        cp "${SPC_DIR}/buildroot/bin/${helper}" "${STAGE_DIR}/${ARCHIVE_ROOT}/bin/${helper}"
done

if [[ -n "${SHARED_EXTENSIONS}" ]]; then
    mkdir -p "${STAGE_DIR}/${ARCHIVE_ROOT}/lib"
    for ext in ${SHARED_EXTENSIONS//,/ }; do
        so="$(find "${SPC_DIR}/buildroot" -name "${ext}.so" -print -quit)"
        [[ -n "${so}" ]] || { echo "error: shared extension ${ext}.so not built" >&2; exit 1; }
        cp "${so}" "${STAGE_DIR}/${ARCHIVE_ROOT}/lib/${ext}.so"
    done
fi

# A sane default ini, and nothing more opinionated than that.
#
# xdebug.mode is deliberately off rather than debug: with mode=debug every
# request tries to reach a debug client and logs a warning when none is
# listening. XDEBUG_MODE=<mode> in the environment enables it for a single
# invocation, and Xdebug honors that over any ini value.
cat > "${STAGE_DIR}/${ARCHIVE_ROOT}/etc/php.ini" <<EOF
; pv default php.ini for PHP ${PHP_VERSION}
memory_limit = 512M
max_execution_time = 300
upload_max_filesize = 100M
post_max_size = 100M
date.timezone = UTC

xdebug.mode = off
xdebug.start_with_request = trigger
EOF

# --- Third-party licenses -------------------------------------------------
# This tarball is a binary distribution of PHP and roughly fifty statically
# linked libraries, several of which require their license text to accompany
# the binary. spc collects them during the build; shipping bin/ without them
# would be a licensing failure, not a packaging detail.
LICENSE_SRC="${SPC_DIR}/buildroot/license"
if [[ -d "${LICENSE_SRC}" ]]; then
    mkdir -p "${STAGE_DIR}/${ARCHIVE_ROOT}/licenses"
    cp "${LICENSE_SRC}"/*.txt "${STAGE_DIR}/${ARCHIVE_ROOT}/licenses/" 2>/dev/null || true
    cat > "${STAGE_DIR}/${ARCHIVE_ROOT}/licenses/README.txt" <<EOF
PHP ${PHP_VERSION} for ${PLATFORM}, built with static-php-cli.

This build statically links the libraries whose licenses are in this
directory, and includes PHP itself (see src_php-src_0.txt). Several are
LGPL — notably gmp, gettext, libiconv, libheif and libde265 — which places
conditions on distributing them inside a statically linked binary.

The build is reproducible from the scripts at
https://github.com/adrum/pv/tree/main/build, which pin every source.
EOF
else
    echo "error: ${LICENSE_SRC} does not exist — refusing to ship a binary" \
         "distribution without its third-party licenses" >&2
    exit 1
fi

# Symlinks do not survive every extraction path and produce confusing partial
# installs, so the tree is plain files only.
find "${STAGE_DIR}/${ARCHIVE_ROOT}" -type l -delete

"${SCRIPT_DIR}/verify-php.sh" "${STAGE_DIR}/${ARCHIVE_ROOT}" "${EXTENSIONS}"

mkdir -p "${DIST_DIR}"
tar -czf "${DIST_DIR}/${TARBALL}" -C "${STAGE_DIR}" "${ARCHIVE_ROOT}"
(cd "${DIST_DIR}" && shasum -a 256 "${TARBALL}" > "${TARBALL}.sha256")

echo "built dist/${TARBALL} ($(du -h "${DIST_DIR}/${TARBALL}" | awk '{print $1}'))"
