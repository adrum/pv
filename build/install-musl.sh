#!/bin/bash
set -euo pipefail

# Install the musl libc that static-php-cli links Linux PHP against, into
# /usr/local/musl — the exact location and version `spc doctor` probes for
# (it wants /usr/local/musl/lib/libc.a plus /lib/ld-musl-<arch>.so.1). With
# those in place doctor's musl-wrapper check passes and it never runs its own
# fixer, which is the point:
#
#   spc's fixer downloads straight from musl.libc.org, a single unmirrored
#   host that is regularly unreachable from our networks — the linux-x86_64
#   CI runner burns 135s on a connect timeout and every PHP job dies with
#   "Fix failed: Download failed ... code: 28" before compiling anything.
#
# So we fetch the same 1.2.5 tarball from a mirror that stays up, pinned by
# hash, and apply the same security patches Alpine ships for it (spc patches
# iconv.c for CVE-2025-26519 too; we add the two later CVE fixes while we're
# here). Everything is verified before it is built — a mirror we don't control
# is only acceptable with a pinned hash.
#
# No-op when musl is already installed, so the Tart image (which bakes it via
# packer) and a second run both skip straight through.

MUSL_VERSION="${MUSL_VERSION:-1.2.5}"
MUSL_SHA256="a9a118bbe84d8764da0ea0d28b3ab3fae8477fc7e4085d90102b8596fc7c75e4"

# Immutable aports commit, so the patch content can't move under the pins.
APORTS_REF="4cf45b216950507916b36662f54c606673b6a4ae"
APORTS_RAW="https://raw.githubusercontent.com/alpinelinux/aports/${APORTS_REF}/main/musl"
# name:sha512 — Alpine's own published sums for these files.
MUSL_PATCHES=(
    "CVE-2025-26519:7a6a9836d2de91afc1115868e68f347bd2365fa48188e65938cfa654ae9bafdbb3a56bf12d3185a96800a85198378c8dbf9c25d977ca0e318220529fa4458123"
    "CVE-2026-6042:f7849abeab0e4eab992a80464afa07b9c8aae5cee76040523b9dbc0931435f28ea8f5792b8a4a0cd6d608ac2f37e3225e89afcb3171a0a6df44450ed57cee83b"
    "CVE-2026-40200:a64ab7688d1a85e560b5687783df482d2467a79a74400da5a1601382847d6b4e6a79b7529a8dc80c46ddda8dc2a812f2261557fc8ee98dc3bdf7322761bd6d9c"
)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICES_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PREFIX="${MUSL_PREFIX:-/usr/local/musl}"

[[ "$(uname -s)" == "Linux" ]] || { echo "install-musl: not Linux, nothing to do"; exit 0; }

if [[ -f "${PREFIX}/lib/libc.a" ]]; then
    echo "musl already installed at ${PREFIX}"
    exit 0
fi

_maybe_sudo() { if [[ "$(id -u)" -eq 0 ]]; then "$@"; else sudo "$@"; fi; }
_sha() { # _sha <bits> <file> -> hex digest
    if command -v "sha${1}sum" >/dev/null 2>&1; then "sha${1}sum" "$2" | cut -d' ' -f1
    else shasum -a "$1" "$2" | cut -d' ' -f1; fi
}

WORK="${SERVICES_DIR}/build/musl-${MUSL_VERSION}"
mkdir -p "${WORK}"
TARBALL="${WORK}/musl-${MUSL_VERSION}.tar.gz"

# Upstream first (authoritative when it answers), Debian's pool second — its
# .orig tarball is upstream's bytes, and it is reachable when musl.libc.org
# isn't. The hash check below is what actually makes either source safe.
MUSL_MIRRORS=(
    "https://musl.libc.org/releases/musl-${MUSL_VERSION}.tar.gz"
    "http://deb.debian.org/debian/pool/main/m/musl/musl_${MUSL_VERSION}.orig.tar.gz"
)

if [[ -f "${TARBALL}" ]] && [[ "$(_sha 256 "${TARBALL}")" != "${MUSL_SHA256}" ]]; then
    rm -f "${TARBALL}"
fi
if [[ ! -f "${TARBALL}" ]]; then
    for url in "${MUSL_MIRRORS[@]}"; do
        echo ">>> Fetching musl ${MUSL_VERSION} from ${url}"
        # Short connect timeout: a dead mirror should cost seconds, not the
        # two minutes spc spends before giving up.
        if curl -fL --connect-timeout 15 --max-time 300 --retry 2 --retry-delay 3 \
            "${url}" -o "${TARBALL}"; then
            break
        fi
        echo "warn: ${url} unreachable, trying next mirror" >&2
        rm -f "${TARBALL}"
    done
fi
if [[ ! -f "${TARBALL}" ]]; then
    echo "error: could not download musl ${MUSL_VERSION} from any mirror" >&2
    exit 1
fi
got="$(_sha 256 "${TARBALL}")"
if [[ "${got}" != "${MUSL_SHA256}" ]]; then
    echo "error: musl tarball sha256 mismatch" >&2
    echo "  expected ${MUSL_SHA256}" >&2
    echo "  got      ${got}" >&2
    rm -f "${TARBALL}"
    exit 1
fi

SRC="${WORK}/musl-${MUSL_VERSION}"
rm -rf "${SRC}"
tar -xzf "${TARBALL}" -C "${WORK}"

for entry in "${MUSL_PATCHES[@]}"; do
    name="${entry%%:*}"
    want="${entry#*:}"
    file="${WORK}/${name}.patch"
    if [[ ! -f "${file}" ]] || [[ "$(_sha 512 "${file}")" != "${want}" ]]; then
        curl -fL --connect-timeout 15 --max-time 120 --retry 3 --retry-delay 3 \
            "${APORTS_RAW}/${name}.patch" -o "${file}"
    fi
    got="$(_sha 512 "${file}")"
    if [[ "${got}" != "${want}" ]]; then
        echo "error: ${name}.patch sha512 mismatch (expected ${want}, got ${got})" >&2
        exit 1
    fi
    echo ">>> Applying ${name}"
    ( cd "${SRC}" && patch -p1 < "${file}" )
done

echo ">>> Building musl ${MUSL_VERSION} → ${PREFIX}"
(
    cd "${SRC}"
    # --disable-gcc-wrapper matches what spc's own fixer configures; spc drives
    # the compiler itself and never calls musl-gcc.
    ./configure --prefix="${PREFIX}" --disable-gcc-wrapper
    make -j"$(nproc 2>/dev/null || echo 4)"
    _maybe_sudo make install
)

# musl's install drops the dynamic loader in syslibdir (/lib) — the other half
# of what doctor checks. Create it if this build didn't.
arch="$(uname -m)"
if [[ ! -e "/lib/ld-musl-${arch}.so.1" && -e "${PREFIX}/lib/libc.so" ]]; then
    _maybe_sudo mkdir -p /lib
    _maybe_sudo ln -sf "${PREFIX}/lib/libc.so" "/lib/ld-musl-${arch}.so.1"
fi

echo "musl ${MUSL_VERSION} installed at ${PREFIX}"
