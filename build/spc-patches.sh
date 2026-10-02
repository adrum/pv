#!/bin/bash
# Reusable spc workaround layer.
#
# Sourced by build/build-php.sh. Functions assume $SPC_DIR is set to the spc
# working directory (the one that contains downloads/, source/, buildroot/).
#
# Everything here exists because a build failed, silently or confusingly, in
# a way that cost hours to trace. The comments record which failure each
# workaround answers; delete one only after reproducing the failure it names.
#
# Provides:
#   txz_is_valid <path>                 — end-to-end .txz integrity
#   scan_corrupt_txz                    — wipe failing pre-built archives
#   wipe_troublesome_prebuilts          — drop .txz for libs that need fresh fetch
#   repackage_lib <name> <glob> <style> — build from source if pre-built bad
#   write_openssl_bootstrap             — emit pv-openssl-bootstrap.cmake
#   patch_cmake_for_openssl <CMakeLists> — prepend OpenSSL fix into a CMakeLists.txt

# Absolute path to THIS file, captured at source/exec time (BASH_SOURCE[0] is
# only reliable at top level, not inside a function). arm_legacy_php_buildconf_hook
# bakes it into the SPC_CMD_PREFIX_PHP_BUILDCONF hook so spc can re-invoke this
# file as `bash <self> --post-extract-php-src`.
_SPC_PATCHES_SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

txz_is_valid() {
    xz -dc "$1" 2>/dev/null | tar -tf - >/dev/null 2>&1
}

scan_corrupt_txz() {
    local txz
    for txz in "${SPC_DIR}/downloads/"*-aarch64-darwin.txz; do
        [[ -f "${txz}" ]] || continue
        if ! txz_is_valid "${txz}"; then
            echo ">>> corrupt pre-built ${txz##*/} — removing"
            rm -f "${txz}"
        fi
    done
}

wipe_troublesome_prebuilts() {
    # libs without a repackage_lib handler whose pre-built CDN serves
    # corruption from this network — force spc to re-fetch source.
    local lib
    # ncurses is here for a different reason than the rest: its pre-built
    # archive is fine, but it ships only the names ncurses itself installs,
    # and libedit's .la asks the linker for -lcurses. Dropping the pre-built
    # forces repackage_lib to build it from source, which is where that alias
    # gets added. Without this the pre-built wins and php fails at the final
    # link with undefined _tgetent/_tputs/_tgoto.
    #
    # sqlite is here for a third reason again: its pre-built archive is
    # perfectly valid and simply built without SQLITE_ENABLE_COLUMN_METADATA.
    # repackage_lib's cache check verifies integrity, not content, so a valid
    # archive is trusted and the from-source build never runs — the flag goes
    # missing with nothing failing anywhere.
    for lib in gmp ncurses libssh2 sqlite; do
        rm -f "${SPC_DIR}/downloads/${lib}-aarch64-darwin.txz" 2>/dev/null || true
    done
}

# repackage_lib <name> <source-tarball-glob> <build-style>
#   build-style is one of:
#     autoconf-static    ./configure --enable-static --disable-shared
#     libiconv-static    autoconf-static + --enable-extra-encodings (CP437 et al)
#     zlib-static        ./configure --static       (zlib's custom configure)
#     openssl-static     ./Configure darwin64-arm64-cc no-shared
#     ncurses-static     ./configure --without-shared --enable-widec
#     icu-static         (cd source && ./runConfigureICU MacOSX ...)
repackage_lib() {
    local name="$1" src_glob="$2" style="$3"
    local txz="${SPC_DIR}/downloads/${name}-aarch64-darwin.txz"
    if [[ -f "${txz}" ]] && txz_is_valid "${txz}"; then
        return 0
    fi
    # Find first source tarball matching glob without using ls|head — under
    # `set -euo pipefail` that pipe dies when ls finds no match (no -G in
    # POSIX ls + pipefail amplifies non-zero), killing the whole script.
    local src_tarball=""
    local _f
    shopt -s nullglob
    for _f in "${SPC_DIR}/downloads/"${src_glob}; do
        src_tarball="${_f}"
        break
    done
    shopt -u nullglob
    # Fall back to a source directory: some libs (e.g. libaom) are fetched by
    # spc as a git checkout under downloads/<name>/ rather than as a tarball.
    local src_dir=""
    if [[ -z "${src_tarball}" && -d "${SPC_DIR}/downloads/${name}" ]]; then
        src_dir="${SPC_DIR}/downloads/${name}"
    fi
    if [[ -z "${src_tarball}" && -z "${src_dir}" ]]; then
        # Nothing to build from. Usually that means this lib is not in the
        # current build's lib set, which is fine — but it also happens when
        # the glob simply does not match what spc named the download, and
        # then this workaround quietly does nothing and the build dies later
        # on a corrupt pre-built archive that nobody repackaged. Say so.
        echo ">>> note: no source for ${name} matching '${src_glob}' in downloads/ —" \
             "cannot repackage it if its pre-built archive turns out to be corrupt" >&2
        return 0
    fi
    echo ">>> Repackaging ${name} from source..."
    local work="${SPC_DIR}/.repack-${name}"
    rm -rf "${work}"
    mkdir -p "${work}/src" "${work}/install"
    if [[ -n "${src_tarball}" ]]; then
        # -xf auto-detects gz/xz/bz2 on macOS BSD tar.
        tar -xf "${src_tarball}" -C "${work}/src" --strip-components=1
    else
        # Directory source: copy the checkout into the work tree so an
        # in-tree cmake build can't dirty spc's downloads/.
        cp -R "${src_dir}/." "${work}/src/"
    fi

    # spc's post-build LicenseDumper greps source/<name>/ for COPYING /
    # LICENSE files. Because our repackage skips spc's own source
    # extraction (we ship the .txz directly), that dir doesn't exist
    # and the dumper errors out. Stage a copy at the expected path.
    local spc_src="${SPC_DIR}/source/${name}"
    if [[ ! -d "${spc_src}" ]]; then
        mkdir -p "${spc_src}"
        if [[ -n "${src_tarball}" ]]; then
            tar -xf "${src_tarball}" -C "${spc_src}" --strip-components=1
        else
            cp -R "${src_dir}/." "${spc_src}/"
        fi
    fi
    (
        cd "${work}/src" || exit 1
        case "${style}" in
            autoconf-static)
                ./configure --prefix="${work}/install" \
                    --enable-static --disable-shared \
                    --with-pic CFLAGS="-arch arm64 -mmacosx-version-min=11.0"
                ;;
            libiconv-static)
                # PHP's iconv sanity check (assert iconv('UTF-8','CP437',...))
                # requires the DOS/Windows codepage encodings that libiconv
                # only ships when --enable-extra-encodings is passed.
                ./configure --prefix="${work}/install" \
                    --enable-static --disable-shared --enable-extra-encodings \
                    --with-pic CFLAGS="-arch arm64 -mmacosx-version-min=11.0"
                ;;
            zlib-static)
                CFLAGS="-arch arm64 -mmacosx-version-min=11.0 -fPIC" \
                    ./configure --prefix="${work}/install" --static
                ;;
            icu-static)
                # ICU's tarball unpacks to icu/ (not icu4c/), and configure
                # lives in icu/source/. We already strip-components=1 so
                # ${work}/src points at icu/ — descend one more level.
                # NOTE: keep icuio enabled — spc's postgres recipe checks for
                # icu-io.pc and bails if it's missing.
                cd source || exit 1
                CFLAGS="-arch arm64 -mmacosx-version-min=11.0 -fPIC" \
                CXXFLAGS="-arch arm64 -mmacosx-version-min=11.0 -fPIC" \
                    ./runConfigureICU MacOSX \
                        --prefix="${work}/install" \
                        --enable-static --disable-shared \
                        --disable-tests --disable-samples \
                        --disable-extras --disable-layoutex
                ;;
            ncurses-static)
                # Ghostty (and some other terminals) export TERMINFO pointing
                # into their .app bundle; ncurses's install honors that and
                # writes the compiled terminfo DB straight into the bundle.
                # Strip those env vars and force the terminfo dir into OUR
                # workdir so install can't escape. --disable-db-install
                # skips compiling the DB at all (PHP / libedit only need
                # the static .a libs + headers).
                # --with-termlib is deliberately NOT passed: it moves the
                # terminfo/termcap entry points into a separate libtinfo, and
                # libedit's .la asks the linker only for -lcurses, so php then
                # fails at the final link with undefined _tgetent/_tputs. Keep
                # them inside the main library. --enable-termcap adds the
                # termcap-compat entry points libedit actually calls.
                unset TERMINFO TERMINFO_DIRS TIC TICDIR
                CFLAGS="-arch arm64 -mmacosx-version-min=11.0 -fPIC" \
                    ./configure --prefix="${work}/install" \
                        --with-default-terminfo-dir="${work}/install/share/terminfo" \
                        --with-terminfo-dirs="${work}/install/share/terminfo" \
                        --disable-db-install \
                        --without-shared --without-debug --without-ada \
                        --without-tests --without-manpages \
                        --enable-widec --with-normal --enable-termcap
                ;;
            openssl-static)
                # --openssldir hard-codes where libssl looks at RUNTIME for
                # openssl.cnf and the CA bundle. macOS keeps /etc/ssl/cert.pem
                # as a system-managed PEM of trusted roots; pointing here
                # makes our static PHP's TLS work out of the box. (Using a
                # build-time tmp dir would leave PHP with no trust roots and
                # every HTTPS call would fail with certificate-verify errors.)
                ./Configure darwin64-arm64-cc no-shared \
                    --prefix="${work}/install" \
                    --openssldir=/etc/ssl \
                    -mmacosx-version-min=11.0
                make -j"$(nproc 2>/dev/null || sysctl -n hw.ncpu)" build_libs
                make install_dev
                # Strip OpenSSL 3.x's OSSL_DEPRECATEDIN_3_0 attribute from
                # the installed macros.h. PHP 8.0/7.4's ext/openssl uses
                # 1.x-era APIs marked with that attribute and clang's
                # parser bails. The APIs still work at runtime.
                if [[ -f "${work}/install/include/openssl/macros.h" ]] \
                   && grep -qE '__attribute__\(\(deprecated' "${work}/install/include/openssl/macros.h"; then
                    sed -E -i.bak 's|__attribute__\(\(deprecated(\([^)]*\))?\)\)||g' \
                        "${work}/install/include/openssl/macros.h"
                    rm -f "${work}/install/include/openssl/macros.h.bak"
                fi
                touch "${work}/.skip-make-install"
                ;;
            cmake-static)
                # CMake-only libs (brotli) — no ./configure. Static + PIC +
                # arm64, tests off, installed into ${work}/install for the
                # common packager below. BROTLI_DISABLE_TESTS is brotli-specific
                # but harmless (CMake ignores unknown cache vars with a warning).
                cmake -S . -B _build \
                    -DCMAKE_INSTALL_PREFIX="${work}/install" \
                    -DCMAKE_INSTALL_LIBDIR=lib \
                    -DBUILD_SHARED_LIBS=OFF \
                    -DBROTLI_DISABLE_TESTS=ON \
                    -DCMAKE_BUILD_TYPE=Release \
                    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
                    -DCMAKE_OSX_ARCHITECTURES=arm64 \
                    -DCMAKE_OSX_DEPLOYMENT_TARGET=11.0
                cmake --build _build -j"$(nproc 2>/dev/null || sysctl -n hw.ncpu)"
                cmake --install _build
                touch "${work}/.skip-make-install"
                ;;
            libssh2-cmake)
                # libssh2 needs a crypto backend, and at patch time the
                # buildroot is empty — spc populates it later, during the
                # build. Rather than depend on that ordering, unpack the
                # OpenSSL archive already sitting in downloads/ into a scratch
                # prefix and point cmake at it. Zlib compression is off so
                # this needs exactly one dependency, not two.
                local ssl_prefix="${SPC_DIR}/.ssl-prefix"
                if [[ ! -f "${ssl_prefix}/lib/libcrypto.a" ]]; then
                    local ssl_txz="${SPC_DIR}/downloads/openssl-aarch64-darwin.txz"
                    if [[ -f "${ssl_txz}" ]] && txz_is_valid "${ssl_txz}"; then
                        mkdir -p "${ssl_prefix}"
                        tar -xf "${ssl_txz}" -C "${ssl_prefix}" --strip-components=1
                    elif [[ -f "${SPC_DIR}/buildroot/lib/libcrypto.a" ]]; then
                        ssl_prefix="${SPC_DIR}/buildroot"
                    else
                        # Failing here is deliberate. The pre-built archive
                        # was already dropped, so carrying on just means spc
                        # refetches the unusable one and dies later with a
                        # message that says nothing about OpenSSL.
                        echo ">>> error: no OpenSSL to build libssh2 against —" \
                             "expected downloads/openssl-aarch64-darwin.txz" >&2
                        exit 1
                    fi
                fi
                cmake -S . -B _build \
                    -DCMAKE_INSTALL_PREFIX="${work}/install" \
                    -DCMAKE_INSTALL_LIBDIR=lib \
                    -DBUILD_SHARED_LIBS=OFF \
                    -DBUILD_EXAMPLES=OFF \
                    -DBUILD_TESTING=OFF \
                    -DENABLE_ZLIB_COMPRESSION=OFF \
                    -DCRYPTO_BACKEND=OpenSSL \
                    -DOPENSSL_ROOT_DIR="${ssl_prefix}" \
                    -DOPENSSL_USE_STATIC_LIBS=ON \
                    -DCMAKE_BUILD_TYPE=Release \
                    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
                    -DCMAKE_OSX_ARCHITECTURES=arm64 \
                    -DCMAKE_OSX_DEPLOYMENT_TARGET=11.0
                cmake --build _build -j"$(nproc 2>/dev/null || sysctl -n hw.ncpu)"
                cmake --install _build
                touch "${work}/.skip-make-install"
                ;;
            sqlite-static)
                # PHP's own sqlite3 sanity check wants
                # sqlite_compileoption_used('ENABLE_COLUMN_METADATA'), and
                # frameworks use column metadata for schema introspection.
                # spc's pre-built sqlite does not have it, and a plain
                # autoconf-static build does not either — it is a
                # preprocessor define rather than a ./configure switch.
                ./configure --prefix="${work}/install" \
                    --enable-static --disable-shared --with-pic \
                    CFLAGS="-arch arm64 -mmacosx-version-min=11.0 -DSQLITE_ENABLE_COLUMN_METADATA=1"
                ;;
            libaom-cmake)
                # libaom (AV1) — pulled in by libheif/libavif for AVIF support.
                # spc fetches it as a git checkout, and the pre-built .txz it
                # would otherwise use is persistently corrupt on this CDN. Build
                # the static lib in place; skip the test suite/testdata, docs,
                # examples and CLI tools (multi-minute, none of which imagick
                # links). arm64 needs no nasm — libaom uses NEON intrinsics.
                cmake -S . -B _build \
                    -DCMAKE_INSTALL_PREFIX="${work}/install" \
                    -DCMAKE_INSTALL_LIBDIR=lib \
                    -DBUILD_SHARED_LIBS=OFF \
                    -DENABLE_TESTS=OFF \
                    -DENABLE_TESTDATA=OFF \
                    -DENABLE_EXAMPLES=OFF \
                    -DENABLE_TOOLS=OFF \
                    -DENABLE_DOCS=OFF \
                    -DCONFIG_PIC=1 \
                    -DCMAKE_BUILD_TYPE=Release \
                    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
                    -DCMAKE_OSX_ARCHITECTURES=arm64 \
                    -DCMAKE_OSX_DEPLOYMENT_TARGET=11.0
                cmake --build _build -j"$(nproc 2>/dev/null || sysctl -n hw.ncpu)"
                cmake --install _build
                touch "${work}/.skip-make-install"
                ;;
            libwebp-cmake)
                # libwebp — corrupt pre-built on this CDN (imagick codec).
                # Build the static core + mux/demux/sharpyuv libraries that
                # ImageMagick links; skip every CLI tool (cwebp/dwebp/… pull in
                # their own deps and none are linked into imagick).
                cmake -S . -B _build \
                    -DCMAKE_INSTALL_PREFIX="${work}/install" \
                    -DCMAKE_INSTALL_LIBDIR=lib \
                    -DBUILD_SHARED_LIBS=OFF \
                    -DWEBP_BUILD_CWEBP=OFF \
                    -DWEBP_BUILD_DWEBP=OFF \
                    -DWEBP_BUILD_GIF2WEBP=OFF \
                    -DWEBP_BUILD_IMG2WEBP=OFF \
                    -DWEBP_BUILD_VWEBP=OFF \
                    -DWEBP_BUILD_WEBPINFO=OFF \
                    -DWEBP_BUILD_WEBPMUX=OFF \
                    -DWEBP_BUILD_ANIM_UTILS=OFF \
                    -DWEBP_BUILD_EXTRAS=OFF \
                    -DCMAKE_BUILD_TYPE=Release \
                    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
                    -DCMAKE_OSX_ARCHITECTURES=arm64 \
                    -DCMAKE_OSX_DEPLOYMENT_TARGET=11.0
                cmake --build _build -j"$(nproc 2>/dev/null || sysctl -n hw.ncpu)"
                cmake --install _build
                touch "${work}/.skip-make-install"
                ;;
            bzip2-make)
                # bzip2 ships only a Makefile (no configure/cmake). Build just
                # the static libbz2.a (skip the CLI + its self-test) and stage
                # the two files consumers need: the archive + bzlib.h.
                make -j"$(nproc 2>/dev/null || sysctl -n hw.ncpu)" libbz2.a \
                    CC=cc \
                    CFLAGS="-arch arm64 -mmacosx-version-min=11.0 -fPIC -O2 -D_FILE_OFFSET_BITS=64 -Wall -Winline"
                mkdir -p "${work}/install/lib" "${work}/install/include"
                cp libbz2.a "${work}/install/lib/"
                cp bzlib.h "${work}/install/include/"
                touch "${work}/.skip-make-install"
                ;;
            lz4-make)
                # lz4 uses a plain Makefile; build+install the static lib only
                # (BUILD_SHARED=no) from lib/. Installs liblz4.a, the headers,
                # and liblz4.pc (whose prefix the .pc rewrite below repoints).
                make -C lib -j"$(nproc 2>/dev/null || sysctl -n hw.ncpu)" \
                    BUILD_SHARED=no BUILD_STATIC=yes \
                    CFLAGS="-arch arm64 -mmacosx-version-min=11.0 -fPIC -O2"
                make -C lib install \
                    PREFIX="${work}/install" \
                    BUILD_SHARED=no BUILD_STATIC=yes
                touch "${work}/.skip-make-install"
                ;;
            xz-static)
                # xz (liblzma) — autoconf, but build only the library: the CLI
                # tools want gettext/po and aren't linked by anything here.
                ./configure --prefix="${work}/install" \
                    --enable-static --disable-shared --with-pic \
                    --disable-xz --disable-xzdec --disable-lzmadec \
                    --disable-lzmainfo --disable-scripts --disable-doc \
                    CFLAGS="-arch arm64 -mmacosx-version-min=11.0"
                ;;
            *)
                echo "error: unknown build style ${style}" >&2
                exit 1
                ;;
        esac
        if [[ ! -f "${work}/.skip-make-install" ]]; then
            make -j"$(nproc 2>/dev/null || sysctl -n hw.ncpu)"
            make install
        fi
        # ncurses ships only the wide-char variants when --enable-widec is
        # passed (libncursesw.a, libtinfow.a, libpanelw.a, libmenuw.a,
        # libformw.a). spc's postgres recipe specifically probes for
        # libncurses.a; copy the wide variants to the non-w names so any
        # consumer finds either spelling.
        if [[ "${style}" == "ncurses-static" ]]; then
            for lib in ncurses tinfo panel menu form; do
                src_a="${work}/install/lib/lib${lib}w.a"
                [[ -f "${src_a}" ]] && cp "${src_a}" "${work}/install/lib/lib${lib}.a"
            done
            # libedit's .la asks the linker for -lcurses, the historical name
            # ncurses installs only when it is configured as the system
            # curses. Without that alias the link finds no terminfo and php
            # fails at the very last step with undefined _tgetent/_tputs/
            # _tgoto — an error that names libedit and says nothing about
            # ncurses, after every library has already been built.
            src_a="${work}/install/lib/libncursesw.a"
            [[ -f "${src_a}" ]] && cp "${src_a}" "${work}/install/lib/libcurses.a"
        fi
    )
    # spc's post-extract pass on ICU reads bin/icu-config to rewrite the
    # baked-in prefix. For most other libs bin/ is dead weight (and can
    # contain dev tools like `tic` that aren't useful in a static
    # buildroot), so default-exclude it but make ICU an exception.
    local exclude_pattern='^(sbin)$'
    case "${style}" in
        icu-static)
            exclude_pattern='^(sbin)$'
            # ICU installs symlinks under lib/icu/ (current → 77.1, etc.).
            # spc's PHP-based tar extractor bails on the first symlink it
            # encounters, leaving bin/icu-config unextracted. Strip them
            # before packaging — they're build-time helpers we don't need
            # at runtime (we statically link libicu*.a).
            find "${work}/install" -type l -delete 2>/dev/null || true
            ;;
        *)          exclude_pattern='^(bin|sbin)$' ;;
    esac
    # libtool .la archives embed absolute paths into ${work} (libdir=,
    # dependency_libs=), which rm -rf below turns into dead references.
    # Worse, they propagate: spc builds libxslt from source against this
    # buildroot, and ITS .la then records the dead libiconv.la path —
    # the libphp (embed SAPI) link chases the chain and hard-fails on
    # any later --rebuild. Static .a + headers + .pc are all consumers
    # need; without .la files libtool falls back to the -l/-L flags.
    find "${work}/install" -name '*.la' -delete

    # .pc files bake the build-time prefix (${work}/install), but that dir is
    # rm -rf'd right after packaging and the libs live at ${SPC_DIR}/buildroot
    # once spc extracts the .txz. A consumer that materializes a CMake imported
    # target from the .pc (e.g. curl's CURL::brotli) validates its include path
    # at configure time and hard-fails on the dangling one. Repoint the prefix
    # to the final buildroot location.
    find "${work}/install" -type f -name '*.pc' -exec \
        sed -i '' "s|${work}/install|${SPC_DIR}/buildroot|g" {} +

    # spc extracts pre-built .txz archives with `tar -xf … --strip-components 1`,
    # so the archive's top-level entry gets stripped. spc's CDN format
    # wraps everything under `buildroot/` for that reason. We mirror that
    # layout: stage install/ under a buildroot/ wrapper dir, then pack.
    (
        cd "${work}" || exit 1
        # Move install/ contents under a buildroot/ wrapper if not already.
        rm -rf buildroot
        mkdir buildroot
        for entry in install/*; do
            [[ -e "${entry}" ]] || continue
            local base
            base="$(basename "${entry}")"
            if echo "${base}" | grep -qE "${exclude_pattern}"; then
                continue
            fi
            mv "${entry}" "buildroot/${base}"
        done
        tar -cJf "${txz}" buildroot
    )
    rm -rf "${work}"
    echo ">>> Wrote valid ${txz##*/} ($(du -h "${txz}" | awk '{print $1}'))"
}

# Emit pv-openssl-bootstrap.cmake in $SPC_DIR. The file is included
# both into the main CMakeLists (via patch_cmake_for_openssl) and into
# try_compile() projects (via CMAKE_TRY_COMPILE_PROJECT_INCLUDE) so
# OpenSSL::SSL / OpenSSL::Crypto imported targets exist everywhere.
write_openssl_bootstrap() {
    OPENSSL_BOOTSTRAP="${SPC_DIR}/pv-openssl-bootstrap.cmake"
    cat > "${OPENSSL_BOOTSTRAP}" << EOF
set(OPENSSL_ROOT_DIR       "${SPC_DIR}/buildroot"                 CACHE PATH     "" FORCE)
set(OPENSSL_INCLUDE_DIR    "${SPC_DIR}/buildroot/include"         CACHE PATH     "" FORCE)
set(OPENSSL_CRYPTO_LIBRARY "${SPC_DIR}/buildroot/lib/libcrypto.a" CACHE FILEPATH "" FORCE)
set(OPENSSL_SSL_LIBRARY    "${SPC_DIR}/buildroot/lib/libssl.a"    CACHE FILEPATH "" FORCE)
set(OPENSSL_FOUND          TRUE                                   CACHE BOOL     "" FORCE)
if(NOT TARGET OpenSSL::Crypto)
    add_library(OpenSSL::Crypto STATIC IMPORTED)
    set_target_properties(OpenSSL::Crypto PROPERTIES
        IMPORTED_LOCATION             "${SPC_DIR}/buildroot/lib/libcrypto.a"
        INTERFACE_INCLUDE_DIRECTORIES "${SPC_DIR}/buildroot/include")
endif()
if(NOT TARGET OpenSSL::SSL)
    add_library(OpenSSL::SSL STATIC IMPORTED)
    set_target_properties(OpenSSL::SSL PROPERTIES
        IMPORTED_LOCATION             "${SPC_DIR}/buildroot/lib/libssl.a"
        INTERFACE_INCLUDE_DIRECTORIES "${SPC_DIR}/buildroot/include"
        INTERFACE_LINK_LIBRARIES      OpenSSL::Crypto)
endif()
EOF
    export OPENSSL_BOOTSTRAP
}

patch_cmake_for_openssl() {
    local cmakefile="$1"
    # Source tree may not be extracted yet (spc extracts during `spc build`,
    # not always at `spc download` time). Defer silently — we'll re-run
    # against the curl tree just before spc build.
    if [[ ! -f "${cmakefile}" ]]; then
        return 0
    fi
    # If the new V2 marker is already there, skip. Older PV_OPENSSL_FIX
    # patches (cache-vars only, no try_compile bootstrap) need replacement.
    if grep -q "PV_OPENSSL_FIX_V2" "${cmakefile}"; then
        return 0
    fi
    # Strip the old patch block if present so we don't stack two copies.
    if grep -q "PV_OPENSSL_FIX" "${cmakefile}"; then
        sed -i.pv-bak '/^# --- PV_OPENSSL_FIX/,/^# ---------------------------------------------------------------------/d' "${cmakefile}"
        rm -f "${cmakefile}.pv-bak"
    fi
    local tmp
    tmp="$(mktemp)"
    {
        cat << EOF
# --- PV_OPENSSL_FIX_V2 --------------------------------------------
# Includes pv-openssl-bootstrap.cmake into the main scope AND into
# try_compile() projects so OpenSSL::SSL / OpenSSL::Crypto imported
# targets exist in both — curl's CheckSymbolExists target-links them.
include("${OPENSSL_BOOTSTRAP}")
set(CMAKE_TRY_COMPILE_PROJECT_INCLUDE "${OPENSSL_BOOTSTRAP}" CACHE FILEPATH "" FORCE)
# ---------------------------------------------------------------------

EOF
        cat "${cmakefile}"
    } > "${tmp}"
    mv "${tmp}" "${cmakefile}"
    echo ">>> Patched ${cmakefile#"${SPC_DIR}"/}"
}

# If buildroot exists but is missing OpenSSL's static libs (e.g. an
# earlier partial run extracted openssl then a later lib wiped it via
# spc's "dangerous rm -rf buildroot" behavior), wipe the whole buildroot
# AND every pre-built .txz so spc redoes the full dependency chain in
# order. repackage_lib will recreate the affected .txz files from source.
guard_stale_buildroot() {
    if [[ ! -d "${SPC_DIR}/buildroot" ]]; then
        return
    fi

    # A buildroot that was built somewhere else is poison. pkg-config files
    # and libtool archives record absolute -L paths, so a buildroot copied or
    # moved between trees hands the linker search paths that no longer exist;
    # the build then dies with undefined symbols in some unrelated library
    # (libedit missing terminfo, say) and nothing in that message points at
    # the real cause. Detect it by its own recorded paths, not by where we
    # think it came from.
    local foreign
    foreign="$(grep -rlE '(^|[^A-Za-z0-9_])/[^ ]*\.spc-cache/' \
                    "${SPC_DIR}/buildroot/lib/pkgconfig" \
                    "${SPC_DIR}/buildroot/lib" 2>/dev/null \
               | while read -r f; do
                     grep -qF "${SPC_DIR}" "${f}" || { echo "${f}"; break; }
                 done)"
    if [[ -n "${foreign}" ]]; then
        echo ">>> buildroot references another build tree (${foreign##*/}) — wiping stale state"
        rm -rf "${SPC_DIR}/buildroot"
        rm -f "${SPC_DIR}/downloads/"*-aarch64-darwin.txz 2>/dev/null || true
        return
    fi

    if [[ -f "${SPC_DIR}/buildroot/lib/libcrypto.a" \
       && -f "${SPC_DIR}/buildroot/lib/libssl.a" \
       && -d "${SPC_DIR}/buildroot/include/openssl" ]]; then
        return
    fi
    echo ">>> buildroot missing OpenSSL artifacts — wiping stale state"
    rm -rf "${SPC_DIR}/buildroot"
    rm -f "${SPC_DIR}/downloads/"*-aarch64-darwin.txz 2>/dev/null || true
}

# Some libs are configured in spc as `provide-pre-built: true` (e.g.,
# libpng), meaning spc only ever fetches the pre-built .txz from the CDN
# and never the source. When that CDN is unreliable from this network,
# we need a source tarball ourselves to feed repackage_lib. Fetch
# libpng's GitHub tag archive into downloads/ with a glob-matching name.
presource_libiconv() {
    # libiconv is fetched as source by spc, but our guard_stale_buildroot
    # may have wiped downloads/*.txz alongside buildroot/ — and if a
    # previous run interrupted the spc download mid-flight, the source
    # tarball can be missing too. Pre-fetch from a mirror rotation so
    # repackage_lib libiconv always has source to build from.
    local ver="1.17"
    local out="${SPC_DIR}/downloads/libiconv-${ver}.tar.gz"
    if [[ -f "${out}" ]] && gzip -t "${out}" 2>/dev/null; then
        return 0
    fi
    # Also accept any existing matching source tarball.
    local existing=""
    local _f
    shopt -s nullglob
    for _f in "${SPC_DIR}/downloads/"libiconv-*.tar.gz; do
        if gzip -t "${_f}" 2>/dev/null; then
            existing="${_f}"
            break
        fi
    done
    shopt -u nullglob
    [[ -n "${existing}" ]] && return 0

    echo ">>> Pre-fetching libiconv ${ver} source"
    mkdir -p "${SPC_DIR}/downloads"
    rm -f "${out}"
    local mirrors=(
        "https://ftpmirror.gnu.org/libiconv/libiconv-${ver}.tar.gz"
        "https://mirror.csclub.uwaterloo.ca/gnu/libiconv/libiconv-${ver}.tar.gz"
        "https://mirror.kumi.systems/gnu/libiconv/libiconv-${ver}.tar.gz"
        "https://ftp.gnu.org/pub/gnu/libiconv/libiconv-${ver}.tar.gz"
        "https://ftp.nluug.nl/gnu/libiconv/libiconv-${ver}.tar.gz"
    )
    for url in "${mirrors[@]}"; do
        if curl -fsSL --connect-timeout 15 --max-time 300 "${url}" -o "${out}" \
                && gzip -t "${out}" 2>/dev/null; then
            return 0
        fi
        rm -f "${out}"
    done
    echo "warning: libiconv pre-fetch failed from all mirrors" >&2
    return 0
}

presource_icu() {
    # spc pins icu as ghrel with `provide-pre-built: true`, so source is
    # only fetched if the .txz is missing. ICU's source tarball is named
    # icu4c-<MAJ>_<MIN>-src.tgz on GitHub releases.
    local ver="76_1"
    local out="${SPC_DIR}/downloads/icu4c-${ver}-src.tgz"
    local existing=""
    local _f
    shopt -s nullglob
    for _f in "${SPC_DIR}/downloads/"icu4c-*-src.tgz "${SPC_DIR}/downloads/"icu-*.tar.* ; do
        existing="${_f}"
        break
    done
    shopt -u nullglob
    [[ -n "${existing}" ]] && return 0

    echo ">>> Pre-fetching ICU ${ver/_/.} source (spc only fetches pre-built)"
    mkdir -p "${SPC_DIR}/downloads"
    local url="https://github.com/unicode-org/icu/releases/download/release-${ver//_/-}/icu4c-${ver}-src.tgz"
    if ! curl -fsSL --connect-timeout 15 --max-time 600 "${url}" -o "${out}"; then
        echo "warning: ICU pre-fetch failed; intl/idn extensions will break" >&2
        return 0
    fi
}

presource_libpng() {
    local ver="1.6.49"
    local out="${SPC_DIR}/downloads/libpng-${ver}.tar.xz"
    # Skip if we already have a libpng source tarball (any matching name).
    local existing=""
    local _f
    shopt -s nullglob
    for _f in "${SPC_DIR}/downloads/"libpng-*.tar.xz "${SPC_DIR}/downloads/"libpng-*.tar.gz; do
        existing="${_f}"
        break
    done
    shopt -u nullglob
    [[ -n "${existing}" ]] && return 0

    echo ">>> Pre-fetching libpng ${ver} source (spc only fetches pre-built)"
    mkdir -p "${SPC_DIR}/downloads"
    # GitHub archive is the canonical mirror — sourceforge has been
    # serving 503s intermittently. The tag tarball unpacks to libpng-N.M.O/
    # which repackage_lib's --strip-components=1 handles.
    local url="https://github.com/pnggroup/libpng/archive/refs/tags/v${ver}.tar.gz"
    if ! curl -fsSL --connect-timeout 15 --max-time 300 "${url}" -o "${out%.tar.xz}.tar.gz"; then
        echo "warning: libpng pre-fetch failed; build may break on libpng" >&2
        return 0
    fi
    # gzip-compressed (GitHub serves .tar.gz). Rename to .tar.gz so our
    # repackage glob `libpng-*.tar.xz` won't match it — broaden the glob
    # in apply_all_spc_patches to handle .tar.gz too.
}

# Older libxml2 (≤2.12) defined `ATTRIBUTE_UNUSED` as a compatibility
# macro; 2.13+ removed it. PHP 8.0 / 7.4's ext/libxml/libxml.c uses it
# unconditionally and clang treats the identifier as part of the
# function declarator, breaking the parse with "expected ')'". Define
# the macro at the top of libxml.c so the build doesn't depend on
# libxml2 exporting it.
patch_php_libxml_attribute_unused() {
    local f="${SPC_DIR}/source/php-src/ext/libxml/libxml.c"
    [[ -f "${f}" ]] || return 0
    # Idempotent: skip if our marker is already there.
    if grep -q 'PV_ATTRIBUTE_UNUSED_SHIM' "${f}"; then
        return 0
    fi
    local tmp
    tmp="$(mktemp)"
    {
        cat << 'EOF'
/* --- PV_ATTRIBUTE_UNUSED_SHIM ----------------------------------- */
/* libxml2 ≤2.12 defined ATTRIBUTE_UNUSED; 2.13+ removed it. PHP 8.0/7.4
   use the symbol unconditionally — supply our own definition. */
#ifndef ATTRIBUTE_UNUSED
# if defined(__GNUC__) || defined(__clang__)
#  define ATTRIBUTE_UNUSED __attribute__((unused))
# else
#  define ATTRIBUTE_UNUSED
# endif
#endif
/* -------------------------------------------------------------------- */

EOF
        cat "${f}"
    } > "${tmp}"
    mv "${tmp}" "${f}"
    echo ">>> Shimmed ATTRIBUTE_UNUSED in PHP ext/libxml/libxml.c"
}

# PHP 7.4's ext/gd/config.m4 uses `PHP_TEST_BUILD(foobar, ..., [char foobar () {}])`
# — a tiny test program that compiles a return-less char-returning function.
# That's undefined behavior; newer clang emits `ud2` and the program traps
# at runtime ("Illegal instruction: 4"), making configure decide GD is broken
# even though it links fine. Patch the test program to return 0 so it's
# well-defined.
patch_php_intl_cxx17() {
    # PHP 8.0 / 7.4 ext/intl/config.m4 hardcodes C++11 (PHP_CXX_COMPILE_STDCXX(11,...)).
    # ICU 77+ uses std::enable_if_t / is_same_v which need C++17. Bump the
    # standard so intl compiles against modern ICU.
    local cfg="${SPC_DIR}/source/php-src/ext/intl/config.m4"
    [[ -f "${cfg}" ]] || return 0
    if grep -q 'PHP_CXX_COMPILE_STDCXX(11' "${cfg}" 2>/dev/null; then
        sed -i.bak 's|PHP_CXX_COMPILE_STDCXX(11,|PHP_CXX_COMPILE_STDCXX(17,|' "${cfg}"
        rm -f "${cfg}.bak"
        rm -f "${SPC_DIR}/source/php-src/configure"
        echo ">>> Bumped PHP ext/intl C++ standard 11 → 17 for ICU 77+ compat"
    fi
}

# libxml2 2.13+ added `const` to xmlStructuredErrorFunc and made
# xmlGetLastError() return `const xmlError *`. PHP 7.4/8.0 still use
# the non-const xmlErrorPtr, which clang 16+ treats as a hard error
# (-Werror=incompatible-function-pointer-types). Rewrite the affected
# signatures in ext/libxml/libxml.c to take `const xmlError *`.
patch_php_libxml_const_callback() {
    local f="${SPC_DIR}/source/php-src/ext/libxml/libxml.c"
    [[ -f "${f}" ]] || return 0
    if grep -q 'PV_LIBXML_CONST_CB' "${f}"; then
        return 0
    fi
    # Marker + signature rewrites. Each sed is idempotent thanks to the
    # marker guard above.
    sed -i.bak \
        -e 's|^static void _php_list_set_error_structure(xmlErrorPtr error,|static void _php_list_set_error_structure(const xmlError *error,|' \
        -e 's|^PHP_LIBXML_API void php_libxml_structured_error_handler(void \*userData, xmlErrorPtr error)|PHP_LIBXML_API void php_libxml_structured_error_handler(void *userData, const xmlError *error)|' \
        "${f}"
    # `xmlErrorPtr error;` followed by `error = xmlGetLastError();` —
    # rewrite both local-variable decls to const.
    sed -i.bak2 's|^\txmlErrorPtr error;$|\tconst xmlError *error;|' "${f}"
    # Drop the const when storing into the llist copy (xmlCopyError dst).
    # error_copy is already a writable local xmlError, so no change needed
    # there. Tag the file so we don't re-run.
    sed -i.bak3 '1i\
/* PV_LIBXML_CONST_CB: signatures patched for libxml2 2.13+ */
' "${f}"
    rm -f "${f}.bak" "${f}.bak2" "${f}.bak3"
    echo ">>> Patched PHP ext/libxml/libxml.c for libxml2 2.13+ const callback"
}

# PHP 8.0 renamed the SAPI archive from libphp7.{a,la,so} to libphp.{a,la,so}
# (php-src ad53bacf38, "Fix bug #78681"). static-php-cli hardcodes the 8.0
# spelling with no version conditional — MacOSBuilder::buildEmbed() runs
# `ar -t <buildroot>/lib/libphp.a` — so on PHP 7.x the embed step dies with
# "The lib archive file .../libphp.a does not exist, please build it first"
# even though cli + fpm linked fine (they use separate make targets).
#
# We never ask for the embed target: --build-shared=xdebug implicitly enables it
# (BuildPHPCommand: `$this->getOption('build-embed') || !empty($shared_extensions)`),
# so shipping Xdebug on 7.4 is what trips this. Rather than drop Xdebug there,
# apply 8.0's rename to 7.x's build system.
#
# The version infix appears in TWO spellings and both must be rewritten, or the
# build breaks worse than it started:
#   - m4 form     `libphp[]$PHP_MAJOR_VERSION[.a]`   — configure.ac, build/php.m4
#                 (sets SAPI_STATIC/SAPI_LIBTOOL/OVERALL_TARGET)
#   - make form   `libphp$(PHP_MAJOR_VERSION).la`    — build/Makefile.global:18
#                 (the RULE that actually builds the target)
# Rewriting only the m4 form leaves `install-sapi: $(OVERALL_TARGET)` depending
# on libphp.la while the rule producing it is still named libphp7.la, and make
# dies with "No rule to make target `libphp.la'".
#
# Stripping the infix is all that's needed for both: m4 quoting collapses
# `libphp[]$PHP_MAJOR_VERSION[.a]` → `libphp[.a]` → exactly `libphp.a`, and the
# make form becomes a plain `libphp.la` target. Verified byte-identical to
# upstream 8.1's build/Makefile.global. Runs before ./buildconf --force, so the
# regenerated configure and Makefile both carry it. Pattern-guarded, so it's a
# no-op on 8.0+ where upstream already renamed it.
patch_php7_libphp_name() {
    local root="${SPC_DIR}/source/php-src"
    [[ -d "${root}" ]] || return 0
    local files f
    # -F: the needles are literals containing [, ], $, ( and ). Scope to the
    # build system (configure.ac + build/ + sapi/), not all of php-src.
    files="$(grep -rlF -e 'libphp[]$PHP_MAJOR_VERSION' -e 'libphp$(PHP_MAJOR_VERSION)' \
        "${root}/configure.ac" "${root}/build" "${root}/sapi" 2>/dev/null || true)"
    [[ -n "${files}" ]] || return 0
    while IFS= read -r f; do
        [[ -n "${f}" ]] || continue
        sed -i.bak \
            -e 's|libphp\[\]\$PHP_MAJOR_VERSION|libphp|g' \
            -e 's|libphp\$(PHP_MAJOR_VERSION)|libphp|g' \
            "${f}"
        rm -f "${f}.bak"
        echo ">>> Renamed libphp7 → libphp in ${f#"${root}/"} (spc hardcodes libphp.a)"
    done <<< "${files}"
}

arm_legacy_php_buildconf_hook() {
    # PHP 7.4 / 8.0 need several php-src edits to build against a modern
    # toolchain (Xcode 26 clang + libxml2 2.13+ + ICU 77+):
    #   - GD "build test": links + RUNS a trivial binary that SIGILLs under
    #     -fstack-protector-strong -fpic -fpie -Os, so config.m4 aborts configure
    #     with "GD build test failed" — a false negative (lib already located).
    #   - ext/libxml/libxml.c: libxml2 2.13+ made xmlStructuredErrorFunc take
    #     `const xmlError *` and dropped ATTRIBUTE_UNUSED — 7.4/8.0 use the old
    #     non-const signature + the removed macro (compile errors, not warnings).
    #   - ext/intl/config.m4: hardcodes C++11; ICU 77+ needs C++17.
    #   - configure.ac/build/sapi: PHP 7.x names the SAPI archive libphp7.a,
    #     but spc hardcodes libphp.a, so the embed step (pulled in implicitly by
    #     --build-shared=xdebug) fails. 7.x only — 8.0 renamed it upstream.
    # 8.1+ carry these upstream, so this is scoped to 7.4/8.0.
    #
    # None of this can be fixed by editing the extracted tree before
    # `spc build`: spc build RE-EXTRACTS php-src fresh from the tarball, then
    # runs `./buildconf --force` to regenerate ./configure — wiping every
    # pre-build edit. (Confirmed in CI spc.output.log: "Extracting source
    # [php-src] ... php-7.4.33.tar.xz", then the libxml/GD errors firing despite
    # the patches.)
    #
    # The durable fix hooks spc's OWN buildconf command via the documented
    # SPC_CMD_PREFIX_PHP_BUILDCONF override (external env beats spc's
    # config/env.ini default — verified: spc [EXEC]s exactly this string). The
    # hook runs INSIDE spc build, AFTER re-extraction:
    #   1. re-invoke this file (--post-extract-php-src) to apply the libxml +
    #      intl source patches to the freshly-extracted tree,
    #   2. run the real ./buildconf --force (regenerates configure from the now
    #      C++17-bumped config.m4),
    #   3. blank the regenerated configure's fatal GD line to a no-op (`:`)
    #      before spc executes ./configure.
    # SPC_DIR is exported so the sub-invocation's functions resolve php-src.
    # The export persists to `spc build` because spc-patches.sh is sourced into
    # build-static.sh's shell.
    # The caller's name for the PHP line. Falls back to PHP_SHORT for older
    # callers — an unset variable here silently disarms every 7.4/8.0 patch
    # and the build dies much later on "GD build test failed", which points
    # nowhere near the real cause.
    local line="${PHP_LINE:-${PHP_SHORT:-}}"
    if [[ -z "${line}" ]]; then
        echo ">>> warning: neither PHP_LINE nor PHP_SHORT is set — legacy php-src" \
             "patches cannot be armed" >&2
        return 0
    fi
    case "${line}" in
    7.4 | 8.0)
        export SPC_DIR
        export SPC_CMD_PREFIX_PHP_BUILDCONF="bash '${_SPC_PATCHES_SELF}' --post-extract-php-src && ./buildconf --force && sed -i.bak 's/.*GD build test failed.*/:/' configure && rm -f configure.bak"
        echo ">>> Armed post-extract php-src hook for PHP ${line} (libxml const/attr + intl C++17 + GD test + libphp archive name)"
        ;;
    esac
}

# spc extracts library sources lazily when each lib is built. The
# curl CMakeLists patch needs to be in place BEFORE spc invokes cmake,
# so pre-extract curl from its downloaded tarball into source/curl/.
# Idempotent: re-extraction is skipped if a CMakeLists.txt already exists.
preextract_curl() {
    local target="${SPC_DIR}/source/curl"
    [[ -f "${target}/CMakeLists.txt" ]] && return 0
    local tarball=""
    local _f
    shopt -s nullglob
    for _f in "${SPC_DIR}/downloads/"curl-*.tar.xz; do
        tarball="${_f}"
        break
    done
    shopt -u nullglob
    [[ -n "${tarball}" ]] || return 0   # spc hasn't downloaded curl yet
    echo ">>> Pre-extracting $(basename "${tarball}") so we can patch CMakeLists.txt"
    rm -rf "${target}"
    mkdir -p "${target}"
    tar -xf "${tarball}" -C "${target}" --strip-components=1
}

# Newer libraries (libxml2 2.13+, OpenSSL 3.x) mark old API and struct
# fields with __attribute__((deprecated[("msg")])). Clang's parser can
# fail with "expected ')'" when these attributes appear in places older
# PHP versions don't expect (PHP 8.0/7.4's ext/libxml/libxml.c parses the
# struct definitions; ext/openssl uses deprecated 3.0 APIs). The
# deprecated APIs/fields still work — just hide the attribute.
#
# Patches both the source trees (so a libxml2/openssl rebuild from source
# installs the de-deprecated header) AND the buildroot copies (in case
# spc skips the rebuild on this run).
neuter_deprecation_attrs() {
    local files=(
        "${SPC_DIR}/source/libxml2/include/libxml/xmlexports.h"
        "${SPC_DIR}/buildroot/include/libxml2/libxml/xmlexports.h"
        "${SPC_DIR}/buildroot/include/openssl/macros.h"
    )
    local patched=false
    for f in "${files[@]}"; do
        [[ -f "${f}" ]] || continue
        if grep -qE '__attribute__\(\(deprecated' "${f}" 2>/dev/null; then
            sed -E -i.bak \
                's|__attribute__\(\(deprecated(\([^)]*\))?\)\)||g' "${f}"
            rm -f "${f}.bak"
            patched=true
        fi
    done
    if [[ "${patched}" == "true" ]]; then
        echo ">>> Neutered __attribute__((deprecated)) in libxml2/openssl headers"
    fi
}

# repackage_lib builds into a temp ${SPC_DIR}/.repack-<lib>/install
# prefix, and the .la archives it installs into buildroot embed that
# absolute path in dependency_libs. The temp dirs don't survive
# cleanups, and libtool hard-fails chasing a dead .la reference when
# linking libphp (the embed SAPI) on a later --rebuild. Rewrite dead
# .repack references to buildroot/lib, where the same archives live.
# References to .repack dirs that still exist are left alone.
fix_stale_la_paths() {
    local la dir changed=0
    shopt -s nullglob
    for la in "${SPC_DIR}/buildroot/lib/"*.la; do
        # Version symlinks (libpng.la → libpng16.la) point at files this
        # loop already visits; sed -i refuses symlinks anyway.
        [[ -L "${la}" ]] && continue
        while IFS= read -r dir; do
            [[ -z "${dir}" || -d "${dir}" ]] && continue
            sed -i.stale-bak "s|${dir}/install/lib|${SPC_DIR}/buildroot/lib|g" "${la}"
            rm -f "${la}.stale-bak"
            changed=1
        done < <(grep -o "${SPC_DIR}/\.repack-[A-Za-z0-9_-]*" "${la}" 2>/dev/null | sort -u)
    done
    shopt -u nullglob
    if [[ "${changed}" -eq 1 ]]; then
        echo ">>> Rewrote stale .repack paths in buildroot .la archives"
    fi
    return 0
}

# Convenience: apply the whole patch set in one go.
apply_all_spc_patches() {
    guard_stale_buildroot
    scan_corrupt_txz
    wipe_troublesome_prebuilts
    neuter_deprecation_attrs
    presource_libiconv
    repackage_lib libiconv  'libiconv-*.tar.gz'  libiconv-static
    repackage_lib zlib      'zlib-*.tar.gz'      zlib-static
    repackage_lib openssl   'openssl-*.tar.gz'   openssl-static
    # gmp's pre-built CDN .txz is corrupt from this network ("Cannot extract
    # package"), and wiping it just makes spc re-fetch the same bad archive —
    # so build it from source like the others.
    repackage_lib gmp       'gmp-*.tar.*'        autoconf-static
    # libssh2's pre-built archive arrives unusable and deleting it only makes
    # spc fetch the same one again, so ssh2 was the one advertised extension
    # that could not be built. Source build, against the OpenSSL above.
    repackage_lib libssh2   '*libssh2-*.tar.*'   libssh2-cmake
    # brotli's pre-built CDN .txz is intermittently corrupt from this network
    # (pulled in by imagick via libjxl/libheif); build it from source. CMake-only.
    repackage_lib brotli    '*brotli-*.tar.*'    cmake-static
    # libaom's pre-built CDN .txz is persistently corrupt from this network
    # (pulled in by imagick via libheif/libavif for AVIF). spc fetches libaom
    # as a git checkout under downloads/libaom/, so the glob won't match a
    # tarball and repackage_lib falls back to that directory.
    repackage_lib libaom    '*libaom-*.tar.*'    libaom-cmake
    # More imagick-chain pre-builts that are corrupt / at risk on this CDN.
    # libwebp is confirmed corrupt; bzip2/lz4/xz sit *after* the multi-minute
    # source-codec builds in spc's link order, so build them up-front from
    # source rather than discover a corrupt pre-built ~15 min in.
    repackage_lib libwebp   '*libwebp-*.tar.*'   libwebp-cmake
    repackage_lib bzip2     'bzip2-*.tar.*'      bzip2-make
    repackage_lib liblz4    'lz4-*.tar.*'        lz4-make
    repackage_lib xz        'xz-*.tar.*'         xz-static
    repackage_lib libsodium 'libsodium-*.tar.gz' autoconf-static
    repackage_lib ncurses   'ncurses-*.tar.gz'   ncurses-static
    presource_libpng
    repackage_lib libpng    'libpng-*.tar.*'     autoconf-static
    presource_icu
    repackage_lib icu       'icu4c-*-src.tgz'    icu-static
    repackage_lib sqlite    'sqlite-*.tar.*'     sqlite-static
    fix_stale_la_paths
    write_openssl_bootstrap
    preextract_curl
    patch_cmake_for_openssl "${SPC_DIR}/source/curl/CMakeLists.txt"
    # 7.4/8.0 php-src fixes (GD test, libxml const/attr, intl C++17, libphp
    # archive name) can't be
    # applied here: `spc build` re-extracts php-src, wiping them. This arms an
    # SPC_CMD_PREFIX_PHP_BUILDCONF hook that re-applies them post-extraction
    # (see arm_legacy_php_buildconf_hook + the --post-extract-php-src dispatch).
    arm_legacy_php_buildconf_hook
}

# ---------------------------------------------------------------------------
# Post-extract hook entrypoint (7.4/8.0).
#
# spc build re-extracts php-src from the tarball at build time, wiping any
# php-src edits made before `spc build`. arm_legacy_php_buildconf_hook wires
# SPC_CMD_PREFIX_PHP_BUILDCONF to invoke THIS file directly
# (`bash spc-patches.sh --post-extract-php-src`) immediately before
# ./buildconf — i.e. AFTER extraction — so these source patches land on the
# tree spc actually compiles. SPC_DIR is inherited from the exported build env;
# each patch is idempotent (marker/pattern guarded), so a repeat run is a no-op.
# Guarded on direct execution so sourcing (build-static.sh) never triggers it.
# ---------------------------------------------------------------------------
if [[ "${BASH_SOURCE[0]}" == "${0}" && "${1:-}" == "--post-extract-php-src" ]]; then
    patch_php_libxml_attribute_unused
    patch_php_libxml_const_callback
    patch_php_intl_cxx17
    patch_php7_libphp_name
fi
