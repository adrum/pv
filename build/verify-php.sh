#!/bin/bash
set -euo pipefail

# Verify a packaged PHP tree before it becomes an artifact.
#
#   ./build/verify-php.sh <tree> <requested,extensions>
#
# Every check here has shipped broken at least once when it was skipped, and
# each failure is silent: the build exits 0 and the problem surfaces on a
# user's machine.

TREE="${1:?usage: verify-php.sh <tree> <extensions>}"
REQUESTED="${2:-}"
PHP="${TREE}/bin/php"

fail() { echo "verify: $*" >&2; exit 1; }

[[ -x "${PHP}" ]] || fail "${PHP} is missing or not executable"

# --- Does it run ----------------------------------------------------------
VERSION="$("${PHP}" -r 'echo PHP_VERSION;')" || fail "php does not run"
echo "verify: php ${VERSION}"

# --- Are all the extensions there ----------------------------------------
# A missing extension is a silent build regression: spc drops it and exits 0.
MODULES="$("${PHP}" -m | tr '[:upper:]' '[:lower:]')"
missing=()
for ext in ${REQUESTED//,/ }; do
    case "${ext}" in
        # Not modules in their own right — checked by behavior below.
        mbregex|password-argon2) continue ;;
        opcache) needle="zend opcache" ;;
        pdo) needle="pdo" ;;
        *) needle="${ext}" ;;
    esac
    grep -qx "${needle}" <<<"${MODULES}" || missing+=("${ext}")
done
if [[ ${#missing[@]} -gt 0 ]]; then
    fail "php -m is missing requested extensions: ${missing[*]}"
fi

# mbregex is its own spc extension; without it mbstring is configured
# --disable-mbregex and mb_split() is simply undefined at runtime, while the
# build and `php -m` both look perfectly healthy.
if [[ ",${REQUESTED}," == *",mbregex,"* ]]; then
    "${PHP}" -r 'exit(function_exists("mb_split") ? 0 : 1);' ||
        fail "mbstring was built without mbregex — mb_split() is undefined"
fi

# sodium alone does not wire Argon2 into the password API.
if [[ ",${REQUESTED}," == *",password-argon2,"* ]]; then
    "${PHP}" -r 'exit(defined("PASSWORD_ARGON2ID") ? 0 : 1);' ||
        fail "PASSWORD_ARGON2ID is undefined — password-argon2 did not build in"
fi

# --- Does it link anything that only exists on the build host -------------
# The single most valuable check in the pipeline: a binary linking a package
# manager's library works perfectly in CI and fails on every user's machine.
check_links() {
    local binary="$1" links=""
    if command -v otool >/dev/null 2>&1; then
        links="$(otool -L "${binary}" | tail -n +2 | awk '{print $1}')"
    elif command -v ldd >/dev/null 2>&1; then
        links="$(ldd "${binary}" 2>/dev/null | awk '{print $3}' || true)"
    fi
    local bad
    bad="$(grep -E '^(/opt/homebrew|/usr/local/opt|/opt/local|/home/linuxbrew)' <<<"${links}" || true)"
    if [[ -n "${bad}" ]]; then
        echo "verify: ${binary} links build-host-only libraries:" >&2
        sed 's/^/  /' <<<"${bad}" >&2
        return 1
    fi
}
for binary in "${TREE}"/bin/* "${TREE}"/lib/*.so; do
    [[ -f "${binary}" ]] || continue
    check_links "${binary}" || fail "build-host-only library references"
done

# --- Is it relocatable ----------------------------------------------------
# Nothing may depend on an absolute path chosen at build time, so the whole
# tree is exercised again from a directory it has never seen.
RELOCATED="$(mktemp -d)/$(date +%s)-relocated"
trap 'rm -rf "$(dirname "${RELOCATED}")"' EXIT
mkdir -p "${RELOCATED}"
cp -R "${TREE}/." "${RELOCATED}/"

RELOCATED_PHP="${RELOCATED}/bin/php"
"${RELOCATED_PHP}" -v >/dev/null || fail "php does not run from a relocated tree"
[[ "$("${RELOCATED_PHP}" -m | wc -l)" == "$(echo "${MODULES}" | wc -l)" ]] ||
    fail "the relocated tree reports a different extension list"

# Extensions that reach for data files or shared libraries at runtime are
# where relocation actually breaks, so touch them rather than trusting -m.
"${RELOCATED_PHP}" -r '
    $checks = [
        "intl"       => fn() => class_exists("Collator") && (new Collator("en_US"))->compare("a", "b") !== false,
        "openssl"    => fn() => is_string(openssl_digest("pv", "sha256")),
        "pdo_mysql"  => fn() => in_array("mysql", PDO::getAvailableDrivers(), true),
        "pdo_sqlite" => fn() => (new PDO("sqlite::memory:"))->query("select 1") !== false,
    ];
    foreach ($checks as $name => $check) {
        if (!extension_loaded($name)) {
            continue;
        }
        if (!$check()) {
            fwrite(STDERR, "verify: {$name} is loaded but not working after relocation\n");
            exit(1);
        }
    }
' || fail "an extension stopped working after relocation"

if [[ -f "${RELOCATED}/lib/xdebug.so" ]]; then
    "${RELOCATED_PHP}" -d "zend_extension=${RELOCATED}/lib/xdebug.so" \
        -r 'exit(extension_loaded("xdebug") ? 0 : 1);' ||
        fail "lib/xdebug.so does not load"
fi

echo "verify: ok"
