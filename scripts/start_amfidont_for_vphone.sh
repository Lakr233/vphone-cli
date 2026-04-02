#!/bin/zsh
# start_amfidont_for_vphone.sh — Start amfidont for the current vphone build.
#
# This is the README "Option 2" host workaround packaged for this repo:
# - computes the signed bundle binary CDHash (what `make boot` actually launches)
# - uses the .build path so amfidont covers binaries inside the .app bundle
# - starts amfidont in daemon mode so signed vphone-cli launches are allowlisted

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_ROOT="${SCRIPT_DIR:h}"
BUNDLE_BIN="${PROJECT_ROOT}/.build/vphone-cli.app/Contents/MacOS/vphone-cli"
AMFIDONT_BIN="${HOME}/Library/Python/3.9/bin/amfidont"
AMFREE_BIN="$(command -v amfree 2>/dev/null || true)"

# ── amfree path (preferred if amfidont is absent) ────────────────

if [[ ! -x "$AMFIDONT_BIN" && -x "$AMFREE_BIN" ]]; then
  AMFI_PATH="${PROJECT_ROOT}/.build"
  echo "[*] Project root:      $PROJECT_ROOT"
  echo "[*] AMFI path:         $AMFI_PATH"
  echo "[*] Using amfree (amfidont not installed)"
  sudo "$AMFREE_BIN" --path "$AMFI_PATH"
  exit $?
fi

# ── amfidont path ────────────────────────────────────────────────

[[ -x "$AMFIDONT_BIN" ]] || {
  echo "Neither amfidont nor amfree found." >&2
  echo "Install amfree: brew install amfree" >&2
  echo "Or install amfidont: xcrun python3 -m pip install --user amfidont" >&2
  exit 1
}

[[ -x "$BUNDLE_BIN" ]] || {
  echo "Missing bundle binary: $BUNDLE_BIN" >&2
  echo "Run 'make bundle' first." >&2
  exit 1
}

CDHASH="$(
  codesign -dv --verbose=4 "$BUNDLE_BIN" 2>&1 \
    | sed -n 's/^CDHash=//p' \
    | head -n1
)"
[[ -n "$CDHASH" ]] || {
  echo "Failed to extract CDHash for $BUNDLE_BIN" >&2
  exit 1
}

# amfidont --path must cover the actual binary location inside the .app
AMFI_PATH="${PROJECT_ROOT}/.build"
ENCODED_AMFI_PATH="${AMFI_PATH// /%20}"

echo "[*] Project root:      $PROJECT_ROOT"
echo "[*] AMFI path:         $AMFI_PATH"
echo "[*] Bundle CDHash:     $CDHASH"

sudo env PYTHONPATH="/Applications/Xcode.app/Contents/SharedFrameworks/LLDB.framework/Resources/Python" \
    /usr/bin/python3 "$AMFIDONT_BIN" daemon \
    --path "$ENCODED_AMFI_PATH" \
    --cdhash "$CDHASH" \
    --verbose \
    >/dev/null 2>&1
