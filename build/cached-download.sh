#!/bin/bash
# Downloads through a cache CI keeps between waves. Sourced by the Windows
# build scripts.
#
#   cached_download <url> <dest> <sha256>
#   prune_download_cache
#
# PV_DOWNLOAD_CACHE names the cache; without it this is a plain verified
# download. Every file is checked against the sha256 the caller already holds,
# from the cache or from the network alike, so a stale or corrupt cache entry
# costs a download, never a wrong build. prune_download_cache then drops what
# this build did not use, so the cache holds what the next one needs and no
# more.

_pv_sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

cached_download() {
    local url="$1" dest="$2" sha="$3"
    local cache="${PV_DOWNLOAD_CACHE:-}" name actual
    name="$(basename "${dest}")"
    if [[ -n "${cache}" ]]; then
        mkdir -p "${cache}"
        echo "${name}" >> "${cache}/.used"
        if [[ -f "${cache}/${name}" && "$(_pv_sha256 "${cache}/${name}")" == "${sha}" ]]; then
            cp "${cache}/${name}" "${dest}"
            echo ">>> ${name} from the download cache"
            return 0
        fi
    fi
    curl -fsSL --retry 3 -o "${dest}" "${url}" || { echo "error: could not download ${url}" >&2; return 1; }
    actual="$(_pv_sha256 "${dest}")"
    if [[ "${actual}" != "${sha}" ]]; then
        echo "error: checksum mismatch for ${name} (expected ${sha}, got ${actual})" >&2
        return 1
    fi
    if [[ -n "${cache}" ]]; then
        cp "${dest}" "${cache}/${name}"
    fi
}

prune_download_cache() {
    local cache="${PV_DOWNLOAD_CACHE:-}" f
    [[ -n "${cache}" && -f "${cache}/.used" ]] || return 0
    for f in "${cache}"/*; do
        [[ -f "${f}" ]] || continue
        grep -qxF "$(basename "${f}")" "${cache}/.used" || rm -f "${f}"
    done
    rm -f "${cache}/.used"
}
