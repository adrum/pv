#!/usr/bin/env bash
# Fetch the security backports for an end-of-life PHP line and check them
# against the reviewed list in build/backports/php-<line>.list.
#
#   ./build/fetch-backports.sh 8.1 8.1.34 <dir>
#
# Output: <dir>/apply.txt, the absolute paths of the patches to apply in
# series order, and <dir>/revision.txt. A line with no list has no backports;
# that is not an error, and no apply.txt is written.
#
# The patches come from Ondřej Surý's Debian packaging, which keeps
# backporting php.net's security fixes to lines php.net has stopped
# releasing. His series also carries Debian packaging changes and, in 2026,
# a patch that reports the PHP version over DNS, so nothing in it is applied
# on trust: the list names every patch in the series, reviewed, as applied
# (with its sha256) or skipped. Anything added, changed or removed since that
# review fails here, with what is new, before a binary is built from it.
#
# The newest revision is always the one fetched. A new revision therefore
# fails the line's build until someone has read the new patches and listed
# them, and the last good build stays published until then.

set -euo pipefail

PHP_LINE="${1:-}"
PHP_VERSION="${2:-}"
OUT_DIR="${3:-}"
if [[ -z "${PHP_LINE}" || -z "${PHP_VERSION}" || -z "${OUT_DIR}" ]]; then
    echo "usage: $0 <php-line> <php-version> <out-dir>   e.g. $0 8.1 8.1.34 /tmp/bp" >&2
    exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIST="${SCRIPT_DIR}/backports/php-${PHP_LINE}.list"
[[ -f "${LIST}" ]] || exit 0

if [[ "${PHP_VERSION}" != *.*.* ]]; then
    echo "error: PHP ${PHP_LINE} has backports, which are written against an exact" \
         "release, but the build resolved only '${PHP_VERSION}'" >&2
    exit 1
fi

# salsa's web front end answers non-browsers with a JavaScript challenge, so
# the archive and raw-file URLs are unusable from CI. Its git endpoint is not
# behind it.
REPO="https://salsa.debian.org/php-team/php.git"
BRANCH="debian/main/${PHP_LINE}"
CLONE="${OUT_DIR}/php-team"

mkdir -p "${OUT_DIR}"
if [[ -d "${CLONE}" ]]; then
    rm -rf "${CLONE}"
fi
# MSYS_NO_PATHCONV: Git for Windows' bash would otherwise rewrite the anchored
# patterns into Windows paths (/debian/... becomes C:/Program Files/Git/...)
# and check out nothing. It stops every conversion, so the command runs from
# inside the clone rather than naming it with -C. core.autocrlf=false: the
# patches must arrive byte for byte, or every reviewed sha256 mismatches and
# none of them applies to php-src's LF sources.
attempts=0
until git clone --quiet --depth 1 --filter=blob:none --sparse -c core.autocrlf=false \
          --branch "${BRANCH}" "${REPO}" "${CLONE}" \
      && (cd "${CLONE}" && MSYS_NO_PATHCONV=1 git sparse-checkout set --no-cone /debian/patches/ /debian/changelog)
do
    attempts=$((attempts + 1))
    if [[ "${attempts}" -ge 3 ]]; then
        echo "error: could not fetch ${BRANCH} from ${REPO}" >&2
        exit 1
    fi
    rm -rf "${CLONE}"
    echo ">>> fetching ${BRANCH} failed (attempt ${attempts}); retrying in 10s"
    sleep 10
done

# `php8.1 (8.1.34-9) unstable; ...`, or `php7.4 (1:7.4.33-31) ...` with an
# epoch. The patches are written against that upstream release and no other.
REVISION="$(head -1 "${CLONE}/debian/changelog" | sed -E 's/^[^(]*\(([^)]*)\).*/\1/')"
UPSTREAM="${REVISION#*:}"
UPSTREAM="${UPSTREAM%%-*}"
if [[ "${UPSTREAM}" != "${PHP_VERSION}" ]]; then
    echo "error: ${BRANCH} is packaging PHP ${UPSTREAM} (${REVISION}), not ${PHP_VERSION}" >&2
    exit 1
fi
COMMIT="$(git -C "${CLONE}" rev-parse --short HEAD)"
echo ">>> backports for PHP ${PHP_VERSION}: ${BRANCH} at ${COMMIT}, revision ${REVISION}"

python3 -I - "${CLONE}/debian/patches" "${LIST}" "${OUT_DIR}/apply.txt" <<'PY'
import hashlib, sys
from pathlib import Path

patches, listing, out = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])

series = [line.split()[0] for line in (patches / "series").read_text().splitlines()
          if line.strip() and not line.lstrip().startswith("#")]

reviewed = {}
for number, line in enumerate(listing.read_text().splitlines(), 1):
    fields = line.split("#", 1)[0].split()
    if not fields:
        continue
    if fields[0] == "apply" and len(fields) == 3:
        reviewed[fields[2]] = fields[1]
    elif fields[0] == "skip" and len(fields) == 2:
        reviewed[fields[1]] = None
    else:
        raise SystemExit(f"error: {listing.name}:{number} is neither "
                         "`apply <sha256> <patch>` nor `skip <patch>  # why`")

def sha256(name: str) -> str:
    return hashlib.sha256((patches / name).read_bytes()).hexdigest()

def touches(name: str) -> str:
    files = sorted({l[6:].strip() for l in (patches / name).read_text(errors="replace").splitlines()
                    if l.startswith("+++ b/")})
    return ", ".join(files) or "(no files)"

unreviewed = [name for name in series if name not in reviewed]
changed = [name for name in series if reviewed.get(name) and reviewed[name] != sha256(name)]
removed = [name for name in reviewed if name not in series]

if unreviewed or changed or removed:
    print(f"error: the series has changed since {listing.name} was reviewed.", file=sys.stderr)
    for title, names in (("new", unreviewed), ("changed", changed)):
        for name in names:
            print(f"  {title}: {name}\n      touches {touches(name)}\n"
                  f"      if it is a fix to apply: apply {sha256(name)} {name}", file=sys.stderr)
    for name in removed:
        print(f"  removed from the series: {name}", file=sys.stderr)
    print(f"Read each patch in {patches}, then list it in build/backports/{listing.name}.",
          file=sys.stderr)
    raise SystemExit(1)

apply = [name for name in series if reviewed[name]]
out.write_text("".join(f"{patches / name}\n" for name in apply))
print(f">>> {len(apply)} of {len(series)} patches reviewed for applying, "
      f"{len(series) - len(apply)} skipped")
PY

echo "${BRANCH} ${COMMIT} ${REVISION}" > "${OUT_DIR}/revision.txt"
