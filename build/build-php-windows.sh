#!/bin/bash
set -euo pipefail

# Build PHP for Windows from source, with security backports, and package it.
#
#   ./build/build-php-windows.sh 8.1 [windows-x86_64]
#
# Output: dist/php-<full-version>-windows-x86_64.tar.gz plus a .sha256 sidecar,
# from package-php-windows.sh, exactly as for php.net's own builds.
#
# For lines php.net no longer builds for Windows. Its last zip for such a line
# never gets another fix, so this compiles one: the php.net source release,
# patched with the reviewed backports in build/backports/ the same way the
# other platforms are, then built by php.net's own php-windows-builder, which
# brings the compiler and the dependency set php.net used for the line.
#
# Those dependencies are frozen at what php.net last shipped for the toolset
# (vs16 carries OpenSSL 1.1.1, for one), so this fixes PHP, not its libraries.
#
# Windows only: it runs MSVC through PowerShell.

PHP_LINE="${1:-}"
PLATFORM="${2:-windows-x86_64}"
if [[ -z "${PHP_LINE}" ]]; then
    echo "usage: $0 <php-line> [platform]   e.g. $0 8.1 windows-x86_64" >&2
    exit 2
fi
[[ "${PLATFORM}" == "windows-x86_64" ]] || { echo "error: only windows-x86_64 is built" >&2; exit 1; }
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) ;;
    *) echo "error: building PHP for Windows needs a Windows host" >&2; exit 1 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
WORK="${ROOT_DIR}/.build/${PHP_LINE}-${PLATFORM}-source"

# php.net's builder, pinned: it downloads and runs a compiler toolchain, so it
# changes only when someone moves this.
BUILDER_REPO="https://github.com/php/php-windows-builder.git"
BUILDER_COMMIT="5f63433eb2bda2ca8d0d970fe487be84f7ab195c"

fail() { echo "error: $*" >&2; exit 1; }

PYTHON=""
for candidate in python3 python py; do
    if "${candidate}" -c 'import sys' >/dev/null 2>&1; then
        PYTHON="${candidate}"
        break
    fi
done
[[ -n "${PYTHON}" ]] || fail "python is required"

[[ -f "${SCRIPT_DIR}/backports/php-${PHP_LINE}.list" ]] ||
    fail "PHP ${PHP_LINE} has no backports list; php.net's own Windows build is the one to package"

rm -rf "${WORK}"
mkdir -p "${WORK}/source"

# --- Source ---------------------------------------------------------------
# The tarball the backports are written against, verified against the sha256
# php.net publishes for it.
PHP_VERSION="$("${PYTHON}" "${SCRIPT_DIR}/resolve-php-version.py" "${PHP_LINE}" | tr -d '\r')"
[[ "${PHP_VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "could not resolve PHP ${PHP_LINE} to a release"
TARBALL="php-${PHP_VERSION}.tar.xz"
EXPECTED="$(curl -fsSL --retry 3 "https://www.php.net/releases/index.php?json&version=${PHP_VERSION}" |
    "${PYTHON}" -c '
import json, sys
name = sys.argv[1]
for source in json.load(sys.stdin).get("source", []):
    if source.get("filename") == name:
        print(source.get("sha256", ""))
' "${TARBALL}" | tr -d '\r')"
[[ "${EXPECTED}" =~ ^[0-9a-f]{64}$ ]] || fail "php.net publishes no sha256 for ${TARBALL}"
curl -fsSL --retry 3 -o "${WORK}/${TARBALL}" "https://www.php.net/distributions/${TARBALL}" ||
    fail "could not download ${TARBALL}"
actual="$(sha256sum "${WORK}/${TARBALL}" | awk '{print $1}')"
[[ "${actual}" == "${EXPECTED}" ]] || fail "checksum mismatch for ${TARBALL} (expected ${EXPECTED}, got ${actual})"
# Python's tarfile rather than tar: Git for Windows' tar cannot be relied on
# to have xz behind it.
"${PYTHON}" -I -c 'import sys, tarfile; tarfile.open(sys.argv[1]).extractall(sys.argv[2], filter="data")' \
    "$(cygpath -w "${WORK}/${TARBALL}")" "$(cygpath -w "${WORK}/source")"
mv "${WORK}/source/php-${PHP_VERSION}" "${WORK}/source/php-src"
echo ">>> verified and extracted ${TARBALL}"

# --- Backports ------------------------------------------------------------
# The same fetch, review check and hook the other platforms use, with WORK
# standing in for spc's working directory.
"${SCRIPT_DIR}/fetch-backports.sh" "${PHP_LINE}" "${PHP_VERSION}" "${WORK}/backports"
export PV_BACKPORTS="${WORK}/backports/apply.txt"
SPC_DIR="${WORK}" bash "${SCRIPT_DIR}/spc-patches.sh" --security-backports
diff -q <(xargs -n1 basename < "${PV_BACKPORTS}") "${WORK}/source/php-src/.pv-backports" >/dev/null ||
    fail "not every reviewed backport was applied"
newest="$(tail -1 "${PV_BACKPORTS}")"
(cd "${WORK}/source/php-src" && patch -p1 -R -f -s --dry-run < "${newest}" >/dev/null 2>&1) ||
    fail "$(basename "${newest}") is not in the patched tree"
rm -f "${WORK}/source/php-src/.pv-backports"
REVISION="$(cut -d' ' -f3 "${WORK}/backports/revision.txt")"

# --- Build ----------------------------------------------------------------
git clone --quiet "${BUILDER_REPO}" "${WORK}/php-windows-builder"
git -C "${WORK}/php-windows-builder" checkout --quiet "${BUILDER_COMMIT}"
cp "${SCRIPT_DIR}/windows/Get-PhpSrc.ps1" "${WORK}/php-windows-builder/php/BuildPhp/private/Get-PhpSrc.ps1"

echo ">>> building PHP ${PHP_VERSION} with php-windows-builder ${BUILDER_COMMIT:0:7}"
(
    cd "${WORK}"
    PV_PHP_SRC="$(cygpath -w "${WORK}/source/php-src")" pwsh -NoProfile -NonInteractive -Command "
        \$ErrorActionPreference = 'Stop'
        Import-Module '$(cygpath -w "${WORK}/php-windows-builder/php/BuildPhp")' -Force
        Invoke-PhpBuild -PhpVersion '${PHP_VERSION}' -Arch x64 -Ts nts
    "
)

shopt -s nullglob
zips=("${WORK}"/artifacts/php-"${PHP_VERSION}"-nts-Win32-v*-x64.zip)
[[ ${#zips[@]} -eq 1 ]] || fail "expected one nts x64 zip in ${WORK}/artifacts, found ${#zips[@]}"

# --- Package --------------------------------------------------------------
PV_WINDOWS_ZIP="${zips[0]}" PV_WINDOWS_BACKPORTS="${REVISION}" \
    exec "${SCRIPT_DIR}/package-php-windows.sh" "${PHP_LINE}" "${PLATFORM}"
