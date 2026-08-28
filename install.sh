#!/bin/sh
set -eu

# Install pv.
#
#   curl -fsSL https://raw.githubusercontent.com/OWNER/pv/main/install.sh | sh
#
# Downloads the newest published pv for this platform, verifies it against the
# sha256 published beside it, and puts the binary on disk. Nothing else — it
# does not edit shell profiles, because a script that rewrites your rc files
# from a pipe is a worse trade than a line you paste yourself.
#
# Deliberately POSIX sh with no JSON parsing: this is the one piece of pv that
# runs before pv exists, on a machine we know nothing about. Everything it
# needs is in the asset names and a .sha256 sidecar.

REPO="${PV_REPO:-austindrummond/pv}"
BASE_URL="${PV_INSTALL_BASE_URL:-https://github.com/${REPO}/releases/latest/download}"
BIN_DIR="${PV_BIN_DIR:-${HOME}/.local/bin}"

die() { echo "pv install: $*" >&2; exit 1; }

# https is pinned for the published location. An explicit PV_INSTALL_BASE_URL
# is someone deliberately pointing at a mirror or a test server, so the pin
# follows the scheme they chose rather than blocking them — but it says so.
case "${BASE_URL}" in
    https://*) proto_args="--proto =https --tlsv1.2" ;;
    *)
        proto_args=""
        echo "pv install: warning: ${BASE_URL} is not https" >&2
        ;;
esac

need() { command -v "$1" >/dev/null 2>&1 || die "$1 is required but not installed"; }
need curl
need tar

case "$(uname -s)" in
    Darwin) os="darwin" ;;
    Linux)  os="linux" ;;
    *) die "unsupported operating system $(uname -s) — pv builds for darwin and linux" ;;
esac
case "$(uname -m)" in
    arm64|aarch64) arch="arm64" ;;
    x86_64|amd64)  arch="x86_64" ;;
    *) die "unsupported architecture $(uname -m)" ;;
esac
platform="${os}-${arch}"

# Both names are published by the release workflow: the unversioned one so
# this script needs no way to discover the current version.
archive="pv-${platform}.tar.gz"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT INT TERM

echo "pv install: fetching ${archive}"
# shellcheck disable=SC2086  # proto_args is intentionally word-split
curl -fsSL ${proto_args} -o "${tmp}/${archive}" "${BASE_URL}/${archive}" ||
    die "could not download ${BASE_URL}/${archive}"
# shellcheck disable=SC2086  # proto_args is intentionally word-split
curl -fsSL ${proto_args} -o "${tmp}/${archive}.sha256" "${BASE_URL}/${archive}.sha256" ||
    die "could not download the checksum for ${archive} — refusing to install unverified"

# Verification fails closed: no checksum, a malformed one, or a mismatch all
# stop the install. An unverifiable download is not a reason to continue.
expected="$(awk '{print $1; exit}' "${tmp}/${archive}.sha256")"
case "${expected}" in
    ????????????????????????????????????????????????????????????????) ;;
    *) die "the published checksum for ${archive} is not a sha256 — refusing to install" ;;
esac

if command -v shasum >/dev/null 2>&1; then
    actual="$(shasum -a 256 "${tmp}/${archive}" | awk '{print $1}')"
elif command -v sha256sum >/dev/null 2>&1; then
    actual="$(sha256sum "${tmp}/${archive}" | awk '{print $1}')"
else
    die "neither shasum nor sha256sum is available — cannot verify the download"
fi
[ "${expected}" = "${actual}" ] ||
    die "checksum mismatch for ${archive} (expected ${expected}, got ${actual}) — nothing was installed"

tar -xzf "${tmp}/${archive}" -C "${tmp}"
binary="$(find "${tmp}" -type f -name pv -perm -u+x -print | head -n 1)"
[ -n "${binary}" ] || die "${archive} did not contain a pv binary"

mkdir -p "${BIN_DIR}" || die "could not create ${BIN_DIR}"
# Install by rename so a half-copied binary is never left on PATH, and so
# replacing a running pv is safe.
cp "${binary}" "${BIN_DIR}/pv.incoming" || die "could not write to ${BIN_DIR}"
chmod 0755 "${BIN_DIR}/pv.incoming"
mv "${BIN_DIR}/pv.incoming" "${BIN_DIR}/pv"

echo "pv install: installed $("${BIN_DIR}/pv" --version) to ${BIN_DIR}/pv"

case ":${PATH}:" in
    *":${BIN_DIR}:"*) ;;
    *)
        echo
        echo "${BIN_DIR} is not on your PATH. Add it:"
        echo "  export PATH=\"${BIN_DIR}:\$PATH\""
        ;;
esac

echo
echo "Next:"
echo "  pv install 8.4          # get a PHP"
echo "  eval \"\$(pv init zsh)\"   # add this to your shell profile"
echo "  pv doctor               # confirm it worked"
