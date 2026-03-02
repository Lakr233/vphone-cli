#!/bin/zsh
# setup_tools.sh — Install all required host tools for vphone-cli
#
# Installs brew packages, builds trustcache from source,
# builds libimobiledevice toolchain, and creates Python venv.
#
# Run: make setup_tools

set -euo pipefail

SCRIPT_DIR="${0:a:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
TOOLS_PREFIX="${TOOLS_PREFIX:-$PROJECT_DIR/.tools}"

# ── Brew packages ──────────────────────────────────────────────

echo "[1/4] Checking brew packages..."

BREW_PACKAGES=(gnu-tar openssl@3 ldid-procursus sshpass)
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
  echo "  Building from source (CRKatri/trustcache)..."
  BUILD_DIR=$(mktemp -d)
  trap "rm -rf '$BUILD_DIR'" EXIT

  git clone --depth 1 https://github.com/CRKatri/trustcache.git "$BUILD_DIR/trustcache" --quiet

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

# ── Libimobiledevice ──────────────────────────────────────────

echo "[3/4] libimobiledevice"
bash "$SCRIPT_DIR/setup_libimobiledevice.sh"

# ── Python venv ────────────────────────────────────────────────

echo "[4/4] Python venv"
zsh "$SCRIPT_DIR/setup_venv.sh"

echo ""
echo "All tools installed."
