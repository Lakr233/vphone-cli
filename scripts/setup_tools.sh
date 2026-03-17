#!/bin/zsh
# setup_tools.sh — Install all required host tools for vphone-cli
#
# Installs brew packages, builds trustcache from source,
# builds insert_dylib from submodule source, and creates Python venv
# (including pymobiledevice3 restore/usbmux tooling).
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

echo "[1/4] Checking brew packages..."

BREW_PACKAGES=(aria2 gnu-tar openssl@3 ldid-procursus sshpass)
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

echo "[2/4] trustcache"

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

# ── insert_dylib ───────────────────────────────────────────────

echo "[3/4] insert_dylib"

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

# ── Python venv ────────────────────────────────────────────────

echo "[4/4] Python venv"
zsh "$SCRIPT_DIR/setup_venv.sh"

echo ""
echo "All tools installed."
