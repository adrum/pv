#!/bin/bash
set -euo pipefail

# Package the official PHP for Windows as a pv artifact.
#
#   ./build/package-php-windows.sh 8.4 [windows-x86_64]
#
# Output: dist/php-<full-version>-windows-x86_64.tar.gz plus a .sha256 sidecar.
#
# Nothing is compiled here. PHP for Windows is built by php.net with MSVC, in
# an environment that cannot be reproduced with a configure flag, and spc has
# no Windows path that covers this extension set. So this redistributes the
# build php.net publishes: the non-thread-safe x64 zip, fetched from the
# release feed, verified against the sha256 that feed carries, and laid out
# the way pv expects a version tree to look.
#
# It runs anywhere bash, curl, unzip and python do. On Windows it also runs
# the packaged php.exe, which is the only check that proves the tree works —
# so that is where CI runs it.

PHP_LINE="${1:-}"
PLATFORM="${2:-windows-x86_64}"

if [[ -z "${PHP_LINE}" ]]; then
    echo "usage: $0 <php-line> [platform]   e.g. $0 8.4 windows-x86_64" >&2
    exit 2
fi
# php.net publishes x86 and x64. There is no official arm64 build.
if [[ "${PLATFORM}" != "windows-x86_64" ]]; then
    echo "error: php.net publishes no build for ${PLATFORM} — only windows-x86_64" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
DIST_DIR="${ROOT_DIR}/dist"
STAGE_DIR="${ROOT_DIR}/.build/${PHP_LINE}-${PLATFORM}"

FEED="${PV_WINDOWS_FEED:-https://windows.php.net/downloads/releases/releases.json}"
DOWNLOADS="${PV_WINDOWS_DOWNLOADS:-https://windows.php.net/downloads/releases}"
# Every Windows Xdebug build ever published, each with its SHA256 beside it.
XDEBUG_INDEX="${PV_XDEBUG_INDEX:-https://xdebug.org/download/historical}"
XDEBUG_FILES="${PV_XDEBUG_FILES:-https://xdebug.org/files}"

# The same placeholder the other platforms ship; `pv install` substitutes the
# directory the tree actually landed in.
PV_PREFIX_PLACEHOLDER="@PV_PREFIX@"

fail() { echo "error: $*" >&2; exit 1; }

PYTHON="$(command -v python3 || command -v python || true)"
[[ -n "${PYTHON}" ]] || fail "python is required to read the release feed"

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

is_windows_host() {
    case "$(uname -s)" in
        MINGW*|MSYS*|CYGWIN*) return 0 ;;
        *) return 1 ;;
    esac
}

# --- Which build ----------------------------------------------------------
# The feed lists one patch per line: version, file and sha256, under a key
# naming the compiler (nts-vs17-x64, nts-vs16-x64, nts-vc15-x64).
rm -rf "${STAGE_DIR}"
mkdir -p "${STAGE_DIR}"
curl -fsSL --retry 3 -o "${STAGE_DIR}/releases.json" "${FEED}" ||
    fail "could not fetch ${FEED}"

read -r PHP_VERSION ZIP_NAME ZIP_SHA256 COMPILER < <("${PYTHON}" - "${STAGE_DIR}/releases.json" "${PHP_LINE}" <<'PY'
import json, re, sys

feed = json.load(open(sys.argv[1]))
line = feed.get(sys.argv[2])
if not isinstance(line, dict):
    raise SystemExit(f"error: the feed has no PHP {sys.argv[2]}")
builds = [
    (match.group(1), value) for key, value in line.items()
    if (match := re.fullmatch(r"nts-(v[cs]\d+)-x64", key)) and isinstance(value, dict)
]
if len(builds) != 1:
    raise SystemExit(f"error: expected one nts x64 build for {sys.argv[2]}, found {len(builds)}")
compiler, build = builds[0]
archive = build.get("zip") or {}
print(line.get("version", ""), archive.get("path", ""), archive.get("sha256", ""), compiler)
PY
) || fail "could not find a Windows build of PHP ${PHP_LINE} in the feed"

[[ "${PHP_VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
    fail "the feed gives no usable version for PHP ${PHP_LINE} (got '${PHP_VERSION}')"
[[ "${ZIP_NAME}" =~ ^php-[0-9A-Za-z._-]+\.zip$ ]] ||
    fail "the feed gives no usable file name for PHP ${PHP_VERSION} (got '${ZIP_NAME}')"
# Fail closed: a feed entry without a real sha256 is an error, not a reason to
# skip verification.
[[ "${ZIP_SHA256}" =~ ^[0-9a-f]{64}$ ]] ||
    fail "the feed publishes no sha256 for ${ZIP_NAME} — refusing to package it unverified"

# The same minimum age the other platforms build under: a release younger
# than a day is skipped. The Windows feed carries no dates, so the answer
# comes from the resolver that has them. When the Windows build is the newer
# of the two it is the one inside the window, and this wave leaves it alone.
OLD_ENOUGH="$("${PYTHON}" "${SCRIPT_DIR}/resolve-php-version.py" "${PHP_LINE}")"
if [[ "${OLD_ENOUGH}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "${OLD_ENOUGH}" != "${PHP_VERSION}" ]]; then
    newest="$(printf '%s\n%s\n' "${OLD_ENOUGH}" "${PHP_VERSION}" | sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1)"
    if [[ "${newest}" == "${PHP_VERSION}" ]]; then
        fail "PHP ${PHP_VERSION} for Windows is younger than the minimum release age" \
             "(newest old enough: ${OLD_ENOUGH}) — the next wave will pick it up"
    fi
    echo ">>> note: php.net's Windows build is ${PHP_VERSION}; upstream is at ${OLD_ENOUGH}"
fi

# --- Fetch and verify -----------------------------------------------------
echo ">>> fetching ${ZIP_NAME}"
curl -fsSL --retry 3 -o "${STAGE_DIR}/${ZIP_NAME}" "${DOWNLOADS}/${ZIP_NAME}" ||
    fail "could not download ${DOWNLOADS}/${ZIP_NAME}"
actual="$(sha256_of "${STAGE_DIR}/${ZIP_NAME}")"
[[ "${actual}" == "${ZIP_SHA256}" ]] ||
    fail "checksum mismatch for ${ZIP_NAME} (expected ${ZIP_SHA256}, got ${actual})"
echo ">>> verified ${ZIP_NAME}"

# --- Package --------------------------------------------------------------
# The zip is flat: php.exe sits beside the DLLs it loads, with extensions in
# ext/. Windows finds a DLL by looking next to the executable first, so the
# whole tree goes into bin/ exactly as published — no relocation step exists
# or is needed.
ARCHIVE_ROOT="php-${PHP_VERSION}-${PLATFORM}"
TARBALL="${ARCHIVE_ROOT}.tar.gz"
TREE="${STAGE_DIR}/${ARCHIVE_ROOT}"
mkdir -p "${TREE}/bin" "${TREE}/etc/conf.d" "${TREE}/licenses"
unzip -q "${STAGE_DIR}/${ZIP_NAME}" -d "${TREE}/bin"
[[ -f "${TREE}/bin/php.exe" ]] || fail "${ZIP_NAME} does not contain php.exe"

# The official build ships its extensions as DLLs and loads none of them
# until an ini asks. Enable the ones that are also in pv's set on the other
# platforms, so `php -m` means roughly the same thing everywhere. What php.net
# does not build for Windows is simply absent — there is nothing to enable.
#
# Order matters in one place: exif needs mbstring loaded first.
WANTED="bz2 curl ffi fileinfo ftp gd gettext gmp intl ldap mbstring exif mysqli openssl pdo_mysql pdo_pgsql pdo_sqlite pgsql shmop soap sockets sodium sqlite3 sysvshm tidy xsl zip"
ENABLED=()
for ext in ${WANTED}; do
    [[ -f "${TREE}/bin/ext/php_${ext}.dll" ]] && ENABLED+=("${ext}")
done
# opcache is a zend_extension where it is a DLL, and compiled in where it is
# not.
OPCACHE_DLL=0
[[ -f "${TREE}/bin/ext/php_opcache.dll" ]] && OPCACHE_DLL=1

# --- Xdebug ---------------------------------------------------------------
# php.net does not ship a debugger, and a debugger is table stakes — the other
# platforms build Xdebug for exactly that reason. xdebug.org publishes Windows
# builds per PHP line and compiler, each with a SHA256, so the newest stable
# one for this line is fetched and verified the same way PHP itself was.
#
# It has to match the compiler PHP was built with (vs17, vs16, vc15): an
# extension from another toolchain refuses to load.
curl -fsSL --retry 3 -o "${STAGE_DIR}/xdebug.html" "${XDEBUG_INDEX}" ||
    fail "could not fetch ${XDEBUG_INDEX}"
# Written to a file rather than read through <( ): the regex below has
# unbalanced quotes, and older bash mis-scans a heredoc inside a substitution.
"${PYTHON}" - "${STAGE_DIR}/xdebug.html" "${PHP_LINE}" "${COMPILER}" \
    > "${STAGE_DIR}/xdebug.txt" <<'PY' ||
import re, sys

page = open(sys.argv[1], encoding="utf-8").read()
line, compiler = re.escape(sys.argv[2]), re.escape(sys.argv[3])
# Two naming schemes over the years: -8.4-nts-vs17-x86_64 and -7.4-vc15-nts-x86_64.
# Stable releases only — the index also carries alphas and release candidates.
link = re.compile(
    r'title="SHA256:&nbsp;([0-9a-f]{64})"\s+href=\'/files/'
    rf"(php_xdebug-(\d+\.\d+\.\d+)-{line}-(?:nts-{compiler}|{compiler}-nts)-x86_64\.dll)'"
)
found = list(link.finditer(page))
if not found:
    raise SystemExit(1)
best = max(found, key=lambda m: tuple(int(part) for part in m.group(3).split(".")))
print(best.group(3), best.group(2), best.group(1))
PY
    fail "xdebug.org publishes no stable ${COMPILER} x64 Xdebug for PHP ${PHP_LINE}"
read -r XDEBUG_VERSION XDEBUG_FILE XDEBUG_SHA256 < "${STAGE_DIR}/xdebug.txt"

echo ">>> fetching ${XDEBUG_FILE}"
curl -fsSL --retry 3 -o "${STAGE_DIR}/${XDEBUG_FILE}" "${XDEBUG_FILES}/${XDEBUG_FILE}" ||
    fail "could not download ${XDEBUG_FILES}/${XDEBUG_FILE}"
actual="$(sha256_of "${STAGE_DIR}/${XDEBUG_FILE}")"
[[ "${actual}" == "${XDEBUG_SHA256}" ]] ||
    fail "checksum mismatch for ${XDEBUG_FILE} (expected ${XDEBUG_SHA256}, got ${actual})"
echo ">>> verified ${XDEBUG_FILE}"
# The name `zend_extension=xdebug` resolves to, inside extension_dir.
cp "${STAGE_DIR}/${XDEBUG_FILE}" "${TREE}/bin/ext/php_xdebug.dll"

cat > "${TREE}/etc/conf.d/.keep" <<'EOF'
; Drop .ini files here to enable extensions.
; pv points PHP_INI_SCAN_DIR at this directory.
EOF
{
    cat <<EOF
; pv default php.ini for PHP ${PHP_VERSION}
;
; PHP only finds this file because pv points PHPRC at it when it runs php.
; The extensions below ship with php.net's Windows build as DLLs in bin\\ext;
; comment a line out to stop loading one.
extension_dir = "${PV_PREFIX_PLACEHOLDER}\\bin\\ext"
memory_limit = 512M
max_execution_time = 300
upload_max_filesize = 100M
post_max_size = 100M
date.timezone = UTC

EOF
    for ext in "${ENABLED[@]}"; do
        echo "extension=${ext}"
    done
    [[ "${OPCACHE_DLL}" -eq 1 ]] && echo "zend_extension=opcache"
    # Off rather than debug, as on every platform: with mode=debug each run
    # reaches for a debug client and warns when none is listening.
    # XDEBUG_MODE=<mode> turns it on for one invocation.
    echo "zend_extension=xdebug"
    echo "xdebug.mode = off"
    echo "xdebug.start_with_request = trigger"
} > "${TREE}/etc/php.ini"

# php.net's own license and the notices for what it bundles.
for notice in license.txt readme-redist-bins.txt; do
    [[ -f "${TREE}/bin/${notice}" ]] && cp "${TREE}/bin/${notice}" "${TREE}/licenses/${notice}"
done
[[ -f "${TREE}/licenses/license.txt" ]] ||
    fail "${ZIP_NAME} carries no license.txt — refusing to ship a binary distribution without it"
curl -fsSL --retry 3 -o "${TREE}/licenses/xdebug-LICENSE.txt" \
    "https://raw.githubusercontent.com/xdebug/xdebug/${XDEBUG_VERSION}/LICENSE" ||
    fail "could not fetch Xdebug ${XDEBUG_VERSION}'s license — refusing to ship it without one"
cat > "${TREE}/licenses/README.txt" <<EOF
PHP ${PHP_VERSION} for ${PLATFORM}.

This is the official build published by php.net, unmodified:
${DOWNLOADS}/${ZIP_NAME}
sha256 ${ZIP_SHA256}

Added to it: etc/, this directory, and bin/ext/php_xdebug.dll — Xdebug
${XDEBUG_VERSION}, the official build from xdebug.org, unmodified:
${XDEBUG_FILES}/${XDEBUG_FILE}
sha256 ${XDEBUG_SHA256}
Xdebug is distributed under the Xdebug License (xdebug-LICENSE.txt).

The build needs the Microsoft Visual C++ Redistributable, as every official
PHP for Windows does.
EOF

# --- Verify ---------------------------------------------------------------
# Running the packaged php.exe is the only real proof, and only Windows can.
# Elsewhere the tree is checked for shape and the gap is said out loud.
if is_windows_host; then
    RELOCATED="$(mktemp -d)/relocated"
    trap 'rm -rf "$(dirname "${RELOCATED}")"' EXIT
    mkdir -p "${RELOCATED}"
    cp -R "${TREE}/." "${RELOCATED}/"
    RELOCATED_WIN="$(cygpath -w "${RELOCATED}")"
    # What `pv install` does to the placeholder, done here by hand.
    "${PYTHON}" - "${RELOCATED}/etc/php.ini" "${PV_PREFIX_PLACEHOLDER}" "${RELOCATED_WIN}" <<'PY'
import sys
path, placeholder, prefix = sys.argv[1:4]
body = open(path, encoding="utf-8").read()
open(path, "w", encoding="utf-8", newline="").write(body.replace(placeholder, prefix))
PY
    php() {
        PHPRC="${RELOCATED_WIN}\\etc\\php.ini" PHP_INI_SCAN_DIR="${RELOCATED_WIN}\\etc\\conf.d" \
            "${RELOCATED}/bin/php.exe" "$@"
    }

    reported="$(php -r 'echo PHP_VERSION;')" || fail "the packaged php.exe does not run"
    [[ "${reported}" == "${PHP_VERSION}" ]] ||
        fail "the packaged php.exe reports ${reported}, not ${PHP_VERSION}"
    limit="$(php -r 'echo ini_get("memory_limit");')"
    [[ "${limit}" == "512M" ]] ||
        fail "etc/php.ini is not applied when PHPRC points at it (memory_limit=${limit})"

    # An extension that fails to load is a warning and exit 0, so read both
    # what php says and what it lists.
    listing="$(php -m 2>&1 | tr -d '\r')"
    if grep -qiE 'warning|unable to load' <<<"${listing}"; then
        echo "${listing}" >&2
        fail "php.exe starts with warnings under the shipped php.ini"
    fi
    modules="$(tr '[:upper:]' '[:lower:]' <<<"${listing}")"
    missing=()
    for ext in "${ENABLED[@]}"; do
        grep -qx "${ext}" <<<"${modules}" || missing+=("${ext}")
    done
    if [[ "${OPCACHE_DLL}" -eq 1 ]]; then
        grep -qx "zend opcache" <<<"${modules}" || missing+=("opcache")
    fi
    grep -qx "xdebug" <<<"${modules}" || missing+=("xdebug")
    [[ ${#missing[@]} -eq 0 ]] || fail "php -m is missing enabled extensions: ${missing[*]}"
    echo ">>> verified: php ${reported} runs relocated with ${#ENABLED[@]} extensions loaded"
else
    for required in bin/php.exe bin/ext/php_xdebug.dll etc/php.ini licenses/license.txt \
                    licenses/xdebug-LICENSE.txt; do
        [[ -e "${TREE}/${required}" ]] || fail "the packaged tree has no ${required}"
    done
    echo ">>> note: not a Windows host, so the packaged php.exe was NOT run." >&2
    echo "    The tree is checked for shape only; build on Windows to verify it." >&2
fi

mkdir -p "${DIST_DIR}"
# Relative paths, so it does not matter which tar a Windows host puts first.
(cd "${STAGE_DIR}" && tar -czf "${TARBALL}" "${ARCHIVE_ROOT}")
mv "${STAGE_DIR}/${TARBALL}" "${DIST_DIR}/${TARBALL}"
(cd "${DIST_DIR}" && echo "$(sha256_of "${TARBALL}")  ${TARBALL}" > "${TARBALL}.sha256")

echo "built dist/${TARBALL} ($(du -h "${DIST_DIR}/${TARBALL}" | awk '{print $1}'))"
