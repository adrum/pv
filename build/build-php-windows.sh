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
# shellcheck source=build/cached-download.sh
source "${SCRIPT_DIR}/cached-download.sh"

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
cached_download "https://www.php.net/distributions/${TARBALL}" "${WORK}/${TARBALL}" "${EXPECTED}" ||
    fail "could not fetch a verified ${TARBALL}"
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

# Unpack <archive>'s top directory <prefix>/ into <dest>, as an extension
# source tree under php-src/ext/.
extract_into() {
    mkdir -p "$2"
    "${PYTHON}" -I -c '
import sys, tarfile
with tarfile.open(sys.argv[1]) as archive:
    prefix = sys.argv[3] + "/"
    members = [m for m in archive.getmembers() if m.name.startswith(prefix)]
    for m in members:
        m.name = m.name[len(prefix):]
    archive.extractall(sys.argv[2], members=[m for m in members if m.name], filter="data")
' "$(cygpath -w "$1")" "$(cygpath -w "$2")" "$3"
}

XDEBUG_VERSION=""
PECL_META=""
if [[ "${ARCH}" == "arm64" ]]; then
    # The builder knows only x86 and x64, though php-sdk, php-src's
    # configure.js and php.net's dependency mirror all support arm64. Teach it
    # the rest:
    #   - accept the architecture;
    #   - skip the Oracle SDK, which Oracle publishes for x86 and x64 only;
    #   - configure without PGO, whose training scenarios run x64 servers;
    #   - build Xdebug and the PECL extensions in-tree, since neither
    #     xdebug.org nor PECL publishes an arm64 Windows build.
    VS="$("${PYTHON}" -I -c 'import json, sys; print(json.load(open(sys.argv[1]))["php"][sys.argv[2]])' \
        "$(cygpath -w "${BUILDER}/config/vs.json")" "${PHP_LINE}" | tr -d '\r')"
    [[ -n "${VS}" ]] || fail "php-windows-builder has no toolset for PHP ${PHP_LINE}"
    # windows-11-arm has Visual Studio 2022 only, and php.net publishes arm64
    # dependencies for 8.2 and 8.3 under vs16 alone. MSVC 2015-2022 are binary
    # compatible and a newer linker takes older libraries, and on arm64 PHP and
    # every extension are compiled together here, so build with vs17 against
    # the vs16 dependency set. That goes for the lines pv ports to arm64 too
    # (vc15 7.4, vs16 8.0 and 8.1), which take 8.2's vs16 set below.
    export PV_DEPS_VS=""
    if [[ "${VS}" == "vs16" || "${VS}" == "vc15" ]]; then
        PV_DEPS_VS="vs16"
        VS="vs17"
        "${PYTHON}" -I -c '
import json, sys
path, line = sys.argv[1], sys.argv[2]
config = json.load(open(path))
config["php"][line] = "vs17"
json.dump(config, open(path, "w"), indent=2)
' "$(cygpath -w "${BUILDER}/config/vs.json")" "${PHP_LINE}"
        sed -i 's/^\(\s*\)process {/\1process {\n\1    if ($env:PV_DEPS_VS) { $VsVersion = $env:PV_DEPS_VS }/' \
            "${BUILDER}/private/Add-PhpDeps.ps1"
        grep -q 'PV_DEPS_VS' "${BUILDER}/private/Add-PhpDeps.ps1" ||
            fail "could not point php-windows-builder at the vs16 arm64 dependencies"
    fi
    # php-src's Windows build system learned arm64 in 8.2. Earlier lines carry
    # pv's port of that support, build/windows/arm64/php-<line>.patch, and
    # take 8.2's arm64 dependency set, php.net publishing none for them.
    export PV_DEPS_PHP=""
    ARM64_PORT="${SCRIPT_DIR}/windows/arm64/php-${PHP_LINE}.patch"
    if [[ -f "${ARM64_PORT}" ]]; then
        # GIT_CEILING_DIRECTORIES: php-src sits inside this repository's
        # checkout, and git apply in a repository's subdirectory takes paths
        # from the repository root, skips everything outside the directory,
        # and still succeeds. Keep git from finding the repository, and check
        # the port is in place rather than trusting the exit status.
        (
            cd "${WORK}/source/php-src"
            export GIT_CEILING_DIRECTORIES="${WORK}/source"
            git apply --whitespace=nowarn "${ARM64_PORT}" &&
                git apply --whitespace=nowarn --check -R "${ARM64_PORT}"
        ) || fail "$(basename "${ARM64_PORT}") did not apply to PHP ${PHP_VERSION}"
        echo ">>> applied pv's arm64 port for PHP ${PHP_LINE}"
        PV_DEPS_PHP="8.2"
        # Take 8.2's set as published: deps-overrides.json pins older libraries
        # for 8.2 releases below a cutoff, which 8.1.34 would otherwise count
        # as, and those were never built for arm64.
        sed -i 's/^\(\s*\)\$seriesUrl = /\1if ($env:PV_DEPS_PHP) { $depsPhpVersion = $env:PV_DEPS_PHP; $configPath = Join-Path $env:TEMP "pv-no-deps-overrides.json" }\n\1$seriesUrl = /' \
            "${BUILDER}/private/Get-PhpDepsPackages.ps1"
        grep -q 'PV_DEPS_PHP' "${BUILDER}/private/Get-PhpDepsPackages.ps1" ||
            fail "could not point php-windows-builder at 8.2's arm64 dependencies"
    fi
    # Fifteen functions validate the architecture, each written out by hand,
    # and every one of them sits on some path through the build.
    find "${BUILDER}" -name '*.ps1' -exec \
        sed -i -E "s/\[ValidateSet\('x86', ?'x64'\)\]/[ValidateSet('x86', 'x64', 'arm64')]/" {} +
    if grep -rqE "ValidateSet\('x86', ?'x64'\)" "${BUILDER}"; then
        fail "could not teach php-windows-builder the arm64 architecture"
    fi
    sed -i 's/^\(\s*\)Get-OciSdk -Arch \$Arch/\1if ($Arch -ne '"'"'arm64'"'"') { Get-OciSdk -Arch $Arch }/' \
        "${BUILDER}/private/Add-BuildRequirements.ps1"
    grep -q "arm64" "${BUILDER}/private/Add-BuildRequirements.ps1" ||
        fail "could not skip the Oracle SDK for arm64"
    printf '%s\r\n' 'call buildconf.bat 2>&1' 'if errorlevel 1 exit 1' 'call config.nts.bat 2>&1' \
        'if errorlevel 1 exit 2' 'nmake 2>&1' 'if errorlevel 1 exit 3' 'nmake snap 2>&1' 'if errorlevel 1 exit 10' \
        > "${BUILDER}/runner/task-nts.bat"

    # NEON is arm64's baseline the way SSE2 is x64's, and php-src 8.2 and 8.3
    # name the snapshot zip without a SIMD suffix for either. 8.4 and later
    # lost the NEON half, so the zip comes out as ...-arm64-NEON.zip, which
    # php-sdk's compliance step refuses as an unsupported archive name.
    # Restore 8.2's line; where it is already there this changes nothing.
    sed -i 's/^!if "\$(PHP_SIMD_SCALE)" == "SSE2"\r\?$/!if "$(PHP_SIMD_SCALE)" == "SSE2" || "$(PHP_SIMD_SCALE)" == "NEON"/' \
        "${WORK}/source/php-src/win32/build/Makefile"
    grep -q '"$(PHP_SIMD_SCALE)" == "NEON"' "${WORK}/source/php-src/win32/build/Makefile" ||
        fail "could not stop the arm64 snapshot being named -NEON"

    # 8.5's SSE-on-NEON emulation (Zend/zend_simd.h, and bcmath's xsse.h it
    # grew from) covers MSVC arm64 too, but passes braced initializers
    # containing commas into vreinterpretq_*(), which MSVC's arm_neon.h
    # defines as macros: "too many arguments for function-like macro
    # invocation". Keep that emulation to GCC and Clang. MSVC arm64 then
    # defines no XSSE2 and takes the scalar code every caller already has
    # for targets without SIMD. Lines without the headers are untouched.
    for header in Zend/zend_simd.h ext/bcmath/libbcmath/src/xsse.h; do
        header="${WORK}/source/php-src/${header}"
        if [[ -f "${header}" ]] && grep -q 'defined(__aarch64__) || defined(_M_ARM64)' "${header}"; then
            sed -i 's/defined(__aarch64__) || defined(_M_ARM64)/defined(__aarch64__)/g' "${header}"
            echo ">>> limited $(basename "${header}")'s NEON emulation to GCC and Clang"
        fi
    done

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
    cached_download "${XDEBUG_FILES}/xdebug-${XDEBUG_VERSION}.tgz" "${WORK}/xdebug-${XDEBUG_VERSION}.tgz" \
        "${XDEBUG_SHA256}" || fail "could not fetch a verified Xdebug ${XDEBUG_VERSION}"
    extract_into "${WORK}/xdebug-${XDEBUG_VERSION}.tgz" "${WORK}/source/php-src/ext/xdebug" "xdebug-${XDEBUG_VERSION}"
    [[ -f "${WORK}/source/php-src/ext/xdebug/config.w32" ]] || fail "Xdebug ${XDEBUG_VERSION} has no config.w32"
    echo ">>> verified Xdebug ${XDEBUG_VERSION} source; building it in-tree"

    # The PECL extensions x64 takes from PECL's Windows builds, compiled
    # in-tree from the source releases pecl-source.lock pins. Their licenses
    # and provenance go to the packaging step through PV_WINDOWS_PECL_DIR.
    PECL_META="${WORK}/pecl"
    mkdir -p "${PECL_META}/licenses"
    : > "${PECL_META}/sources.txt"
    PECL_CONFIGURE=""
    while IFS=$' \t\r' read -r s_ext s_version s_sha256; do
        [[ -z "${s_ext}" || "${s_ext}" == \#* ]] && continue
        s_tgz="${s_ext}-${s_version}.tgz"
        cached_download "https://pecl.php.net/get/${s_tgz}" "${WORK}/${s_tgz}" "${s_sha256}" ||
            fail "could not fetch ${s_tgz} matching build/windows/pecl-source.lock"
        extract_into "${WORK}/${s_tgz}" "${WORK}/source/php-src/ext/${s_ext}" "${s_ext}-${s_version}"
        [[ -f "${WORK}/source/php-src/ext/${s_ext}/config.w32" ]] || fail "${s_tgz} has no config.w32"
        # mongodb turns on SSPI authentication whenever php.net's libsasl is
        # present but never links secur32.lib, where SSPI lives; x64 gets it
        # from elsewhere, arm64 fails to link. Link it alongside.
        if [[ "${s_ext}" == "mongodb" ]]; then
            sed -i 's/^\(\s*\)mongoc_opts.MONGOC_ENABLE_SASL_SSPI = 1;/&\n\1ADD_FLAG("LIBS_MONGODB", "secur32.lib");/' \
                "${WORK}/source/php-src/ext/mongodb/config.w32"
            grep -q 'secur32.lib' "${WORK}/source/php-src/ext/mongodb/config.w32" ||
                fail "could not link mongodb against secur32.lib"
        fi
        case "${s_ext}" in
            ssh2)  PECL_CONFIGURE+=' "--with-ssh2=shared"' ;;
            # The serializer redis can use, built just before it.
            redis) PECL_CONFIGURE+=' "--enable-redis=shared" "--enable-redis-igbinary"' ;;
            *)     PECL_CONFIGURE+=" \"--enable-${s_ext}=shared\"" ;;
        esac
        s_licenses=0
        for f in "${WORK}/source/php-src/ext/${s_ext}"/{LICENSE,COPYING}*; do
            [[ -f "${f}" ]] || continue
            s_name="$(basename "${f}")"
            cp "${f}" "${PECL_META}/licenses/${s_ext}-${s_name%.txt}.txt"
            s_licenses=$((s_licenses + 1))
        done
        [[ "${s_licenses}" -gt 0 ]] || fail "${s_tgz} carries no license — refusing to ship it without one"
        printf '%s %s: https://pecl.php.net/get/%s\n  sha256 %s\n' \
            "${s_ext}" "${s_version}" "${s_tgz}" "${s_sha256}" >> "${PECL_META}/sources.txt"
        echo ">>> verified ${s_tgz}; building it in-tree"
    done < "${SCRIPT_DIR}/windows/pecl-source.lock"

    mkdir -p "${BUILDER}/config/${VS}/arm64"
    printf '%s\r\n' 'cscript /nologo configure.js "--enable-snapshot-build" "--enable-debug-pack" "--disable-zts" "--enable-object-out-dir=../obj/" "--enable-com-dotnet=shared" "--without-analyzer" "--with-xdebug=shared"'"${PECL_CONFIGURE}"' %*' \
        > "${BUILDER}/config/${VS}/arm64/config.nts.bat"
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
    PV_WINDOWS_PECL_DIR="${PECL_META}" \
    exec "${SCRIPT_DIR}/package-php-windows.sh" "${PHP_LINE}" "${PLATFORM}"
