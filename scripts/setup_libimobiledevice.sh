#!/bin/bash
# setup_libimobiledevice.sh — Build libimobiledevice toolchain (static)
#
# Produces: idevicerestore, irecovery, and related idevice* tools
# Prefix:   .limd/  (override with LIMD_PREFIX env var)
# Requires: autoconf automake libtool pkg-config cmake git

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

PREFIX="${LIMD_PREFIX:-$PROJECT_DIR/.limd}"
SRC="$PREFIX/src"
LOG="$PREFIX/log"

NPROC="$(sysctl -n hw.logicalcpu)"
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
  for cmd in autoconf automake pkg-config cmake git; do
    command -v "$cmd" &>/dev/null || missing+=("$cmd")
  done
  command -v glibtoolize &>/dev/null || command -v libtoolize &>/dev/null ||
    missing+=("libtool(ize)")
  ((${#missing[@]} == 0)) || die "Missing: ${missing[*]} — brew install ${missing[*]}"
}

clone() {
  local url=$1 dir=$2
  if [[ -d "$dir/.git" ]]; then
    git -C "$dir" fetch --depth 1 origin --quiet
    git -C "$dir" reset --hard FETCH_HEAD --quiet
    git -C "$dir" clean -fdx --quiet
  else
    git clone --depth 1 "$url" "$dir" --quiet
  fi
}

build_lib() {
  local name=$1
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

# ── 1. Core libraries ───────────────────────────────────────────

echo "[1/3] Core libraries (using homebrew openssl@3)"
for lib in libplist libimobiledevice-glue libusbmuxd libtatsu libimobiledevice; do
  clone "https://github.com/libimobiledevice/$lib" "$SRC/$lib"
  case "$lib" in
    libplist | libimobiledevice) build_lib "$lib" --without-cython ;;
    *) build_lib "$lib" ;;
  esac
done

# ── 2. libirecovery (+ PCC research VM patch) ───────────────────

echo "[2/3] libirecovery + libzip"
clone "https://github.com/libimobiledevice/libirecovery" "$SRC/libirecovery"

# PR #150: register iPhone99,11 / vresearch101ap for PCC research VMs
if ! grep -q 'vresearch101ap' "$SRC/libirecovery/src/libirecovery.c"; then
  cd "$SRC/libirecovery"
  git apply "$SCRIPT_DIR/patches/libirecovery-pcc-vm.patch" ||
    die "Failed to apply libirecovery PCC patch — check context"
  cd "$SRC"
fi
build_lib libirecovery

# ── libzip (static, for idevicerestore) ──────────────────────────

LIBZIP_VER="1.11.4"
if [[ ! -f "$PREFIX/lib/pkgconfig/libzip.pc" ]]; then
  echo "  libzip"
  [[ -d "$SRC/libzip-$LIBZIP_VER" ]] ||
    curl -LfsS "https://github.com/nih-at/libzip/releases/download/v$LIBZIP_VER/libzip-$LIBZIP_VER.tar.gz" |
    tar xz -C "$SRC"
  cmake -S "$SRC/libzip-$LIBZIP_VER" -B "$SRC/libzip-$LIBZIP_VER/build" \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_OSX_SYSROOT="$SDKROOT" \
    -DBUILD_SHARED_LIBS=OFF -DBUILD_DOC=OFF -DBUILD_EXAMPLES=OFF \
    -DBUILD_REGRESS=OFF -DBUILD_TOOLS=OFF \
    -DENABLE_BZIP2=OFF -DENABLE_LZMA=OFF -DENABLE_ZSTD=OFF \
    -DENABLE_GNUTLS=OFF -DENABLE_MBEDTLS=OFF -DENABLE_OPENSSL=OFF \
    >"$LOG/libzip-cmake.log" 2>&1
  cmake --build "$SRC/libzip-$LIBZIP_VER/build" -j"$NPROC" \
    >"$LOG/libzip-build.log" 2>&1
  cmake --install "$SRC/libzip-$LIBZIP_VER/build" \
    >"$LOG/libzip-install.log" 2>&1
fi

# ── 3. idevicerestore ───────────────────────────────────────────

echo "[3/3] idevicerestore"
clone "https://github.com/libimobiledevice/idevicerestore" "$SRC/idevicerestore"
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
