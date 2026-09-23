#!/bin/zsh
# vphone-tier: build
# setup_tools.sh — Install all required host tools for vphone-cli
#
# Installs brew packages, builds trustcache from source, and builds insert_dylib
# from submodule source (a test reference — see step [3/3]).
#
# There is no interpreter step: the restore backend is linked into vphone-cli
# and the patchers are Swift, so nothing this script installs is an environment.
#
# Run: make setup_tools

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TOOLS_PREFIX="${TOOLS_PREFIX:-$PROJECT_DIR/.tools}"
REPOS_DIR="$SCRIPT_DIR/repos"

ensure_repo_submodule() {
    local rel_path="$1"
    local abs_path="$PROJECT_DIR/$rel_path"

    if [[ ! -e "$abs_path/.git" ]]; then
        git -C "$PROJECT_DIR" submodule update --init --recursive "$rel_path"
    fi
}

# ── Brew packages ──────────────────────────────────────────────

echo "[1/3] Checking brew packages..."

# No python here, and cmake and keystone are deliberately absent too: all three
# existed only so pip could build keystone-engine's native library for the
# Python firmware patchers, and those are Swift now (FirmwarePatcher's
# ARM64Encoder replaces keystone's asm(), the libcapstone-spm package replaces
# the capstone wheel). openssl@3 stays — the trustcache build below links it.
BREW_PACKAGES=(aria2 gnu-tar openssl@3 ldid-procursus sshpass zstd)
BREW_MISSING=()

for pkg in "${BREW_PACKAGES[@]}"; do
    if ! brew list "$pkg" &>/dev/null; then
        BREW_MISSING+=("$pkg")
    fi
done

if ((${#BREW_MISSING[@]} > 0)); then
    echo "  Installing: ${BREW_MISSING[*]}"
    brew install "${BREW_MISSING[@]}"
else
    echo "  All brew packages installed"
fi

# ── Trustcache ─────────────────────────────────────────────────

echo "[2/3] trustcache"

TRUSTCACHE_BIN="$TOOLS_PREFIX/bin/trustcache"
if [[ -x "$TRUSTCACHE_BIN" ]]; then
    echo "  Already built: $TRUSTCACHE_BIN"
else
    echo "  Building from submodule source (scripts/repos/trustcache)..."
    ensure_repo_submodule "scripts/repos/trustcache"

    BUILD_DIR=$(mktemp -d)
    trap "rm -rf '$BUILD_DIR'" EXIT

    ditto "$REPOS_DIR/trustcache" "$BUILD_DIR/trustcache"
    rm -rf "$BUILD_DIR/trustcache/.git"

    OPENSSL_PREFIX="$(brew --prefix openssl@3)"
    make -C "$BUILD_DIR/trustcache" \
        OPENSSL=1 \
        CFLAGS="-I$OPENSSL_PREFIX/include -DOPENSSL -w" \
        LDFLAGS="-L$OPENSSL_PREFIX/lib" \
        -j"$(sysctl -n hw.logicalcpu)" >/dev/null 2>&1

    mkdir -p "$TOOLS_PREFIX/bin"
    cp "$BUILD_DIR/trustcache/trustcache" "$TRUSTCACHE_BIN"
    echo "  Installed: $TRUSTCACHE_BIN"
fi

# ── insert_dylib (test reference only) ─────────────────────────
#
# Nothing in the product runs this any more: `CFWInjectDylib` injects the weak
# load command in-process, and the last caller that shelled out was
# scripts/patchers/cfw.py. It is still built because it is the independent
# reference CFWMachOTests.matchesInsertDylib compares the Swift injector
# against, byte for byte — that test skips silently when it is missing, which
# is the worst possible way to lose the check.

echo "[3/3] insert_dylib (byte-parity reference for CFWMachOTests)"

INSERT_DYLIB_BIN="$TOOLS_PREFIX/bin/insert_dylib"
if [[ -x "$INSERT_DYLIB_BIN" ]]; then
    echo "  Already built: $INSERT_DYLIB_BIN"
else
    INSERT_DYLIB_DIR="$REPOS_DIR/insert_dylib"
    ensure_repo_submodule "scripts/repos/insert_dylib"
    echo "  Building insert_dylib..."
    mkdir -p "$TOOLS_PREFIX/bin"
    clang -o "$INSERT_DYLIB_BIN" "$INSERT_DYLIB_DIR/insert_dylib/main.c" -framework Security -O2
    echo "  Installed: $INSERT_DYLIB_BIN"
fi

echo ""
echo "All tools installed."
