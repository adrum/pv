#!/bin/bash
set -euo pipefail

# Build PHP for Windows from source, and package it.
#
#   ./build/build-php-windows.sh 8.1 [windows-x86_64]
#   ./build/build-php-windows.sh 8.4 windows-arm64
#
# Output: dist/php-<full-version>-<platform>.tar.gz plus its sidecars, from
# package-php-windows.sh, exactly as for php.net's own builds.
#
# For what php.net does not build. On x64 that is the end-of-life lines: their
# last zip never gets another fix, so this compiles one from the php.net
# source release patched with the reviewed backports in build/backports/, the
# same way the other platforms are. On arm64 it is every line: php.net
# publishes no Windows arm64 build at all, though it maintains the dependency
# set for one.
#
# The build itself is php.net's php-windows-builder, which brings the compiler
# and the dependency set php.net uses for the line. Those dependencies are
# frozen at what php.net last shipped for the toolset (vs16 x64 carries
# OpenSSL 1.1.1, for one), so backports fix PHP, not its libraries.
#
# Windows only: it runs MSVC through PowerShell.

PHP_LINE="${1:-}"
PLATFORM="${2:-windows-x86_64}"
if [[ -z "${PHP_LINE}" ]]; then
    echo "usage: $0 <php-line> [platform]   e.g. $0 8.1 windows-x86_64" >&2
    exit 2
fi
case "${PLATFORM}" in
    windows-x86_64) ARCH="x64" ;;
    windows-arm64)  ARCH="arm64" ;;
    *) echo "error: no Windows build for ${PLATFORM}" >&2; exit 1 ;;
esac
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

# Every Xdebug release, with the SHA256 of each file beside it.
XDEBUG_INDEX="${PV_XDEBUG_INDEX:-https://xdebug.org/download/historical}"
XDEBUG_FILES="${PV_XDEBUG_FILES:-https://xdebug.org/files}"

fail() { echo "error: $*" >&2; exit 1; }

PYTHON=""
for candidate in python3 python py; do
    if "${candidate}" -c 'import sys' >/dev/null 2>&1; then
        PYTHON="${candidate}"
        break
    fi
done
[[ -n "${PYTHON}" ]] || fail "python is required"

BACKPORTS_LIST="${SCRIPT_DIR}/backports/php-${PHP_LINE}.list"
if [[ "${ARCH}" == "x64" && ! -f "${BACKPORTS_LIST}" ]]; then
    fail "PHP ${PHP_LINE} has no backports list; php.net's own x64 build is the one to package"
fi

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
REVISION=""
if [[ -f "${BACKPORTS_LIST}" ]]; then
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
fi

# --- Builder --------------------------------------------------------------
git clone --quiet "${BUILDER_REPO}" "${WORK}/php-windows-builder"
git -C "${WORK}/php-windows-builder" checkout --quiet "${BUILDER_COMMIT}"
BUILDER="${WORK}/php-windows-builder/php/BuildPhp"
cp "${SCRIPT_DIR}/windows/Get-PhpSrc.ps1" "${BUILDER}/private/Get-PhpSrc.ps1"

XDEBUG_VERSION=""
if [[ "${ARCH}" == "arm64" ]]; then
    # The builder knows only x86 and x64, though php-sdk, php-src's
    # configure.js and php.net's dependency mirror all support arm64. Teach it
    # the rest:
    #   - accept the architecture;
    #   - skip the Oracle SDK, which Oracle publishes for x86 and x64 only;
    #   - configure without PGO, whose training scenarios run x64 servers;
    #   - build Xdebug in-tree, since xdebug.org publishes no arm64 DLL.
    VS="$("${PYTHON}" -I -c 'import json, sys; print(json.load(open(sys.argv[1]))["php"][sys.argv[2]])' \
        "$(cygpath -w "${BUILDER}/config/vs.json")" "${PHP_LINE}" | tr -d '\r')"
    [[ -n "${VS}" ]] || fail "php-windows-builder has no toolset for PHP ${PHP_LINE}"
    sed -i "s/\[ValidateSet('x86', 'x64')\]/[ValidateSet('x86', 'x64', 'arm64')]/" \
        "${BUILDER}/public/Invoke-PhpBuild.ps1"
    grep -q "'arm64'" "${BUILDER}/public/Invoke-PhpBuild.ps1" ||
        fail "could not teach php-windows-builder the arm64 architecture"
    sed -i 's/^\(\s*\)Get-OciSdk -Arch \$Arch/\1if ($Arch -ne '"'"'arm64'"'"') { Get-OciSdk -Arch $Arch }/' \
        "${BUILDER}/private/Add-BuildRequirements.ps1"
    grep -q "arm64" "${BUILDER}/private/Add-BuildRequirements.ps1" ||
        fail "could not skip the Oracle SDK for arm64"
    mkdir -p "${BUILDER}/config/${VS}/arm64"
    printf '%s\r\n' 'cscript /nologo configure.js "--enable-snapshot-build" "--enable-debug-pack" "--disable-zts" "--enable-object-out-dir=../obj/" "--enable-com-dotnet=shared" "--without-analyzer" "--with-xdebug=shared" %*' \
        > "${BUILDER}/config/${VS}/arm64/config.nts.bat"
    printf '%s\r\n' 'call buildconf.bat 2>&1' 'if errorlevel 1 exit 1' 'call config.nts.bat 2>&1' \
        'if errorlevel 1 exit 2' 'nmake 2>&1' 'if errorlevel 1 exit 3' 'nmake snap 2>&1' 'if errorlevel 1 exit 10' \
        > "${BUILDER}/runner/task-nts.bat"

    # The newest Xdebug that xdebug.org itself builds for this line, from source.
    curl -fsSL --retry 3 -o "${WORK}/xdebug.html" "${XDEBUG_INDEX}" || fail "could not fetch ${XDEBUG_INDEX}"
    "${PYTHON}" -I - "$(cygpath -w "${WORK}/xdebug.html")" "${PHP_LINE}" > "${WORK}/xdebug.txt" <<'PY' ||
import re, sys

page = open(sys.argv[1], encoding="utf-8").read()
line = re.escape(sys.argv[2])
built = {m.group(1) for m in re.finditer(rf"php_xdebug-(\d+\.\d+\.\d+)-{line}-", page)}
sources = {
    m.group(2): m.group(1)
    for m in re.finditer(r"title=\"SHA256:&nbsp;([0-9a-f]{64})\"\s+href='/files/xdebug-(\d+\.\d+\.\d+)\.tgz'", page)
}
candidates = sorted((v for v in built if v in sources), key=lambda v: tuple(map(int, v.split("."))))
if not candidates:
    raise SystemExit(1)
print(candidates[-1], sources[candidates[-1]])
PY
        fail "xdebug.org lists no stable Xdebug source for PHP ${PHP_LINE}"
    IFS=$' \t\r' read -r XDEBUG_VERSION XDEBUG_SHA256 < "${WORK}/xdebug.txt"
    curl -fsSL --retry 3 -o "${WORK}/xdebug.tgz" "${XDEBUG_FILES}/xdebug-${XDEBUG_VERSION}.tgz" ||
        fail "could not download Xdebug ${XDEBUG_VERSION}"
    actual="$(sha256sum "${WORK}/xdebug.tgz" | awk '{print $1}')"
    [[ "${actual}" == "${XDEBUG_SHA256}" ]] ||
        fail "checksum mismatch for xdebug-${XDEBUG_VERSION}.tgz (expected ${XDEBUG_SHA256}, got ${actual})"
    mkdir -p "${WORK}/source/php-src/ext/xdebug"
    "${PYTHON}" -I -c '
import sys, tarfile
with tarfile.open(sys.argv[1]) as archive:
    prefix = sys.argv[3] + "/"
    members = [m for m in archive.getmembers() if m.name.startswith(prefix)]
    for m in members:
        m.name = m.name[len(prefix):]
    archive.extractall(sys.argv[2], members=[m for m in members if m.name], filter="data")
' "$(cygpath -w "${WORK}/xdebug.tgz")" "$(cygpath -w "${WORK}/source/php-src/ext/xdebug")" "xdebug-${XDEBUG_VERSION}"
    [[ -f "${WORK}/source/php-src/ext/xdebug/config.w32" ]] || fail "Xdebug ${XDEBUG_VERSION} has no config.w32"
    echo ">>> verified Xdebug ${XDEBUG_VERSION} source; building it in-tree"
fi

# --- Build ----------------------------------------------------------------
echo ">>> building PHP ${PHP_VERSION} for ${ARCH} with php-windows-builder ${BUILDER_COMMIT:0:7}"
(
    cd "${WORK}"
    PV_PHP_SRC="$(cygpath -w "${WORK}/source/php-src")" pwsh -NoProfile -NonInteractive -Command "
        \$ErrorActionPreference = 'Stop'
        Import-Module '$(cygpath -w "${BUILDER}")' -Force
        Invoke-PhpBuild -PhpVersion '${PHP_VERSION}' -Arch ${ARCH} -Ts nts
    "
)

shopt -s nullglob
zips=("${WORK}"/artifacts/php-"${PHP_VERSION}"-nts-Win32-v*-"${ARCH}".zip)
[[ ${#zips[@]} -eq 1 ]] || fail "expected one nts ${ARCH} zip in ${WORK}/artifacts, found ${#zips[@]}"

# --- Package --------------------------------------------------------------
PV_WINDOWS_ZIP="${zips[0]}" PV_WINDOWS_BACKPORTS="${REVISION}" PV_WINDOWS_XDEBUG_VERSION="${XDEBUG_VERSION}" \
    exec "${SCRIPT_DIR}/package-php-windows.sh" "${PHP_LINE}" "${PLATFORM}"
