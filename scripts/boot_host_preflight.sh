#!/bin/zsh
# boot_host_preflight.sh — Diagnose whether the host can launch the signed
# vphone-cli binary required for PV=3 virtualization boot/DFU flows.

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_ROOT="${SCRIPT_DIR:h}"

ASSERT_BOOTABLE=0
QUIET=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --assert-bootable)
      ASSERT_BOOTABLE=1
      shift
      ;;
    --quiet)
      QUIET=1
      shift
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 2
      ;;
  esac
done

cd "$PROJECT_ROOT"

RELEASE_BIN="${PROJECT_ROOT}/.build/release/vphone-cli"
DEBUG_BIN="${PROJECT_ROOT}/.build/debug/vphone-cli"
ENTITLEMENTS="${PROJECT_ROOT}/sources/vphone.entitlements"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/vphone-preflight.XXXXXX")"
TMP_SIGNED_DEBUG="${TMP_DIR}/vphone-cli.debug.signed"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

print_section() {
  (( QUIET == 0 )) || return 0
  echo ""
  echo "=== $1 ==="
}

run_capture() {
  local label="$1"
  shift

  local log_file="${TMP_DIR}/${label}.log"
  local rc=0
  "$@" >"$log_file" 2>&1 || rc=$?

  (( QUIET == 0 )) && echo "[${label}] exit=${rc}"
  if (( QUIET == 0 )) && [[ -s "$log_file" ]]; then
    sed -n '1,40p' "$log_file"
  fi
  return "$rc"
}

MODEL_NAME="$(system_profiler SPHardwareDataType 2>/dev/null | awk -F': ' '/Model Name/ {print $2; exit}')"
HV_VMM_PRESENT="$(sysctl -n kern.hv_vmm_present 2>/dev/null || true)"
SIP_STATUS="$(csrutil status)"
RESEARCH_GUEST_STATUS="$(
  # First pass with EOF stdin — captures the menu without blocking
  _out=$(csrutil allow-research-guests status </dev/null 2>/dev/null || true)
  if ! echo "$_out" | grep -q "Pick a macOS installation"; then
    # Single install or already got a direct answer
    echo "$_out"
  else
    # Multiple installs: try to auto-select "Macintosh HD"
    _num=$(echo "$_out" | awk '/Macintosh HD/ { match($0, /[0-9]+/); if (RSTART > 0) { print substr($0, RSTART, RLENGTH); exit } }')
    if [[ -n "$_num" ]]; then
      _result=$(printf '%s\n' "$_num" | csrutil allow-research-guests status 2>/dev/null \
        | grep -o 'Allow Research Guests status:.*' || true)
      if [[ -n "$_result" ]]; then
        echo "(auto-selected: Macintosh HD) $_result"
        exit 0
      fi
    fi
    # No Macintosh HD found, or auto-select failed — prompt interactively
    # only when a controlling TTY exists. Non-interactive runs should degrade
    # cleanly instead of failing on /dev/tty access under set -e.
    if { : >/dev/tty; } 2>/dev/null; then
      printf '%s\n' "$_out" >/dev/tty
      printf 'Pick a macOS installation: ' >/dev/tty
      read _choice </dev/tty
      if [[ -n "$_choice" ]]; then
        printf '%s\n' "$_choice" | csrutil allow-research-guests status 2>/dev/null \
          | grep -o 'Allow Research Guests status:.*' || echo 'unavailable'
      else
        echo 'unavailable'
      fi
    else
      echo 'unavailable (multiple installs; no interactive tty)'
    fi
  fi
)"
CURRENT_BOOT_ARGS="$(sysctl -n kern.bootargs 2>/dev/null || true)"
NEXT_BOOT_ARGS="$({ nvram boot-args 2>/dev/null || true; } | sed 's/^boot-args[[:space:]]*//')"
ASSESSMENT_STATUS="$(spctl --status 2>/dev/null || true)"

print_section "Host"
sw_vers
echo "model: $MODEL_NAME"
echo "kern.hv_vmm_present: $HV_VMM_PRESENT"
echo "SIP: $SIP_STATUS"
echo "allow-research-guests: $RESEARCH_GUEST_STATUS"
echo "current kern.bootargs: $CURRENT_BOOT_ARGS"
echo "next-boot nvram boot-args: $NEXT_BOOT_ARGS"
echo "assessment: $ASSESSMENT_STATUS"

if (( ASSERT_BOOTABLE == 1 )); then
  if [[ "$HV_VMM_PRESENT" == "1" ]] || [[ "$MODEL_NAME" == "Apple Virtual Machine 1" ]]; then
    (( QUIET == 0 )) && {
      echo ""
      echo "Error: nested Apple VM host detected; Virtualization.framework guest boot is unavailable here." >&2
    }
    exit 3
  fi
fi

print_section "Entitlements"
if [[ -f "$RELEASE_BIN" ]]; then
  codesign -d --entitlements :- "$RELEASE_BIN" 2>/dev/null || true
else
  echo "missing release binary: $RELEASE_BIN"
fi

print_section "Policy"
if [[ -f "$RELEASE_BIN" ]]; then
  spctl --assess --type execute --verbose=4 "$RELEASE_BIN" 2>&1 || true
fi

print_section "Unsigned Debug Binary"
DEBUG_HELP_RC=0
if [[ ! -f "$DEBUG_BIN" ]]; then
  echo "(skipped — debug binary not built; run 'make patcher_build' to include)"
else
  set +e
  run_capture "debug_help" "$DEBUG_BIN" --help
  DEBUG_HELP_RC=$?
  set -e
fi

print_section "Signed Release Binary"
if [[ ! -f "$RELEASE_BIN" ]]; then
  echo "missing release binary: $RELEASE_BIN"
  exit 1
fi
set +e
run_capture "release_help" "$RELEASE_BIN" --help
RELEASE_HELP_RC=$?
set -e

print_section "Signed Debug Control"
SIGNED_DEBUG_HELP_RC=0
if [[ ! -f "$DEBUG_BIN" ]]; then
  echo "(skipped — debug binary not built)"
else
  cp "$DEBUG_BIN" "$TMP_SIGNED_DEBUG"
  codesign --force --sign - --entitlements "$ENTITLEMENTS" "$TMP_SIGNED_DEBUG" >/dev/null
  set +e
  run_capture "signed_debug_help" "$TMP_SIGNED_DEBUG" --help
  SIGNED_DEBUG_HELP_RC=$?
  set -e
fi

print_section "Result"
echo "If unsigned debug runs but either signed binary exits 137 / signal 9,"
echo "the host is not currently permitting the required private virtualization entitlements."
echo "If the signed release binary exits 0 but the signed debug control still exits 137,"
echo "a path/CDHash-scoped amfidont bypass may already be active for this repo."
echo "Typical requirements for this project are:"
echo "  1. macOS 15+ with PV=3 support"
echo "  2. Host hardware must expose Virtualization.framework VM support (not a nested VM without virtualization availability)"
echo "  3. SIP disabled"
echo "  4. allow-research-guests enabled in Recovery OS"
echo "  5. AMFI / execution policy state that permits the private entitlements"
echo "  6. Gatekeeper / assessment configured so the signed binary is launchable"

if (( ASSERT_BOOTABLE == 1 )); then
  if (( RELEASE_HELP_RC != 0 )); then
    (( QUIET == 0 )) && {
      echo ""
      echo "Error: signed release vphone-cli is not launchable on this host (exit $RELEASE_HELP_RC)." >&2
    }
    exit "$RELEASE_HELP_RC"
  fi
fi
