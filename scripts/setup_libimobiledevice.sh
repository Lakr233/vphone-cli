#!/bin/bash
# setup_libimobiledevice.sh — Build libimobiledevice toolchain (static)
#
# Produces: idevicerestore, irecovery, and related idevice* tools
# Prefix:   .limd/  (override with LIMD_PREFIX env var)
# Source:   scripts/repos/* git submodules (staged into .limd/src before build)
# Requires: autoconf automake libtool pkg-config cmake git

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPOS_DIR="$SCRIPT_DIR/repos"

PREFIX="${LIMD_PREFIX:-$PROJECT_DIR/.limd}"
SRC="$PREFIX/src"
LOG="$PREFIX/log"

NPROC="$(sysctl -n hw.logicalcpu 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"

OPENSSL_PREFIX="$(brew --prefix openssl@3 2>/dev/null || true)"
[[ -d "$OPENSSL_PREFIX" ]] || {
    echo "[-] openssl@3 not found. Run: brew install openssl@3" >&2
    exit 1
}

export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:$OPENSSL_PREFIX/lib/pkgconfig"
export CFLAGS="-mmacosx-version-min=14.0 -isysroot $SDKROOT"
export CPPFLAGS="$CFLAGS"
export LDFLAGS="-mmacosx-version-min=14.0"

mkdir -p "$SRC" "$LOG"

# ── Helpers ──────────────────────────────────────────────────────

die() {
    echo "[-] $*" >&2
    exit 1
}

check_tools() {
    local missing=()
    for cmd in autoconf automake pkg-config cmake git patch; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    command -v glibtoolize &>/dev/null || command -v libtoolize &>/dev/null ||
        missing+=("libtool(ize)")
    ((${#missing[@]} == 0)) || die "Missing: ${missing[*]} — brew install ${missing[*]}"
}

ensure_repo_submodule() {
    local rel_path="$1"
    local abs_path="$PROJECT_DIR/$rel_path"

    if [[ ! -e "$abs_path/.git" ]]; then
        git -C "$PROJECT_DIR" submodule update --init --recursive "$rel_path"
    fi
}

stage_repo_source() {
    local name="$1"
    local src_dir="$REPOS_DIR/$name"
    local dst_dir="$SRC/$name"
    local version=""

    ensure_repo_submodule "scripts/repos/$name"
    rm -rf "$dst_dir"
    ditto "$src_dir" "$dst_dir"

    # Some autotools projects expect either git metadata or .tarball-version.
    # Staged sources are intentionally detached from git, so preserve version info.
    version="$(git -C "$src_dir" describe --tags --always 2>/dev/null || true)"
    if [[ -n "$version" ]]; then
        printf "%s\n" "$version" >"$dst_dir/.tarball-version"
    fi

    rm -rf "$dst_dir/.git"
}

build_lib() {
    local name="$1"
    shift
    echo "  $name"
    cd "$SRC/$name"
    ./autogen.sh --prefix="$PREFIX" \
        --enable-shared=no --enable-static=yes \
        "$@" >"$LOG/$name-configure.log" 2>&1
    make -j"$NPROC" >"$LOG/$name-build.log" 2>&1
    make install >"$LOG/$name-install.log" 2>&1
    cd "$SRC"
}

# ── Preflight ────────────────────────────────────────────────────

check_tools
echo "Building libimobiledevice toolchain → $PREFIX"
echo ""
echo "Using submodule sources from scripts/repos/"
echo ""

# ── 1. Core libraries ───────────────────────────────────────────

echo "[1/3] Core libraries (using homebrew openssl@3)"
for lib in libplist libimobiledevice-glue libusbmuxd libtatsu libimobiledevice; do
    stage_repo_source "$lib"
    case "$lib" in
        libplist | libimobiledevice) build_lib "$lib" --without-cython ;;
        *) build_lib "$lib" ;;
    esac
done

# ── 2. libirecovery (+ PCC research VM patch) ───────────────────

echo "[2/3] libirecovery + libzip"
stage_repo_source "libirecovery"

# PR #150: register iPhone99,11 / vresearch101ap for PCC research VMs
if ! grep -q 'vresearch101ap' "$SRC/libirecovery/src/libirecovery.c"; then
    if ! (cd "$SRC/libirecovery" && /usr/bin/patch -p1 --batch --forward --dry-run <"$SCRIPT_DIR/patches/libirecovery-pcc-vm.patch" >/dev/null); then
        die "Failed to validate libirecovery PCC patch — check context"
    fi
    if ! (cd "$SRC/libirecovery" && /usr/bin/patch -p1 --batch --forward <"$SCRIPT_DIR/patches/libirecovery-pcc-vm.patch" >"$LOG/libirecovery-pcc-vm.patch.log" 2>&1); then
        die "Failed to apply libirecovery PCC patch — see $LOG/libirecovery-pcc-vm.patch.log"
    fi
    grep -q 'vresearch101ap' "$SRC/libirecovery/src/libirecovery.c" ||
        die "libirecovery PCC patch command succeeded but expected marker is still missing"
fi
build_lib libirecovery

# ── libzip (static, for idevicerestore, from submodule) ───────────

if [[ ! -f "$PREFIX/lib/pkgconfig/libzip.pc" ]]; then
    echo "  libzip"
    stage_repo_source "libzip"
    cmake -S "$SRC/libzip" -B "$SRC/libzip/build" \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_OSX_SYSROOT="$SDKROOT" \
        -DBUILD_SHARED_LIBS=OFF -DBUILD_DOC=OFF -DBUILD_EXAMPLES=OFF \
        -DBUILD_REGRESS=OFF -DBUILD_TOOLS=OFF \
        -DENABLE_BZIP2=OFF -DENABLE_LZMA=OFF -DENABLE_ZSTD=OFF \
        -DENABLE_GNUTLS=OFF -DENABLE_MBEDTLS=OFF -DENABLE_OPENSSL=OFF \
        >"$LOG/libzip-cmake.log" 2>&1
    cmake --build "$SRC/libzip/build" -j"$NPROC" \
        >"$LOG/libzip-build.log" 2>&1
    cmake --install "$SRC/libzip/build" \
        >"$LOG/libzip-install.log" 2>&1
fi

# ── 3. idevicerestore ───────────────────────────────────────────

echo "[3/3] idevicerestore"
stage_repo_source "idevicerestore"
build_lib idevicerestore \
    libcurl_CFLAGS="-I$SDKROOT/usr/include" \
    libcurl_LIBS="-lcurl" \
    libcurl_VERSION="$(/usr/bin/curl-config --version | cut -d' ' -f2)" \
    zlib_CFLAGS="-I$SDKROOT/usr/include" \
    zlib_LIBS="-lz" \
    zlib_VERSION="1.2"

# ── Done ─────────────────────────────────────────────────────────

echo ""
echo "Installed to $PREFIX/bin/:"
ls "$PREFIX/bin/" | sed 's/^/  /'
