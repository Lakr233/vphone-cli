#!/bin/zsh
# start_amfidont_for_vphone.sh — Start amfidont for the current vphone build.
#
# This is the README "Option 2" host workaround packaged for this repo:
# - uses the project path so amfidont covers binaries relevant for the project
# - starts amfidont in daemon mode so signed vphone-cli launches are allowlisted
# - spoofs signatures to be recognized as apple signed for patchless variant

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_ROOT="${SCRIPT_DIR:h}"

if ! command -v amfidont &>/dev/null; then
  echo "amfidont not found" >&2
  echo "Install it first: xcrun python3 -m pip install -U amfidont" >&2
  exit 1
fi

# amfidont drives LLDB's Python bindings and must use *Xcode's* lldb (which
# matches its Xcode python3 runtime). If a Homebrew LLVM lldb is first on PATH it
# shadows Xcode's and ships incompatible bindings (e.g. Python 3.14 vs 3.9),
# producing a "_lldb did not return an extension module" failure. Force the
# Xcode toolchain so the `lldb -P` amfidont runs internally resolves correctly.
XCODE_BIN="$(xcode-select -p 2>/dev/null)/usr/bin"
AMFIDONT_BIN="$(command -v amfidont)"
LOG=/tmp/amfidont-vphone.log

sudo env PATH="$XCODE_BIN:/usr/bin:/bin" "$AMFIDONT_BIN" daemon \
    --path "$PROJECT_ROOT" \
    --spoof-apple \
    >"$LOG" 2>&1

echo "amfidont started (log: $LOG)"
