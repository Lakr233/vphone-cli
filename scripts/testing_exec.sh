#!/usr/bin/env zsh
set -euo pipefail

# Quick testing flow:
#   pkill -9 vphone-cli
#   make fw_prepare
#   make fw_patch / fw_patch_dev / fw_patch_jb
#   make testing_ramdisk_build
#   make testing_ramdisk_send &
#   make boot_dfu

PROJECT_DIR="$(cd "$(dirname "${0:a:h}")" && pwd)"
cd "$PROJECT_DIR"

VM_DIR="${VM_DIR:-vm}"
BASE_PATCH="${BASE_PATCH:-jb}"
WATCH_TIMEOUT_SECONDS="${WATCH_TIMEOUT_SECONDS:-30}"
RUN_TS="$(date '+%Y%m%d_%H%M%S')"

case "$BASE_PATCH" in
  normal)
    PATCH_TARGET="fw_patch"
    ;;
  dev)
    PATCH_TARGET="fw_patch_dev"
    ;;
  jb)
    PATCH_TARGET="fw_patch_jb"
    ;;
  *)
    echo "[-] Invalid BASE_PATCH: $BASE_PATCH"
    echo "    Use BASE_PATCH=normal|dev|jb"
    exit 1
    ;;
esac

if [[ "$VM_DIR" = /* ]]; then
  VM_ABS_DIR="$VM_DIR"
else
  VM_ABS_DIR="$PROJECT_DIR/$VM_DIR"
fi
mkdir -p "$VM_ABS_DIR"

BOOT_LOG="$VM_ABS_DIR/testing_exec_boot_${RUN_TS}.log"
WATCH_LOG="$VM_ABS_DIR/testing_exec_watch_${RUN_TS}.log"
touch "$BOOT_LOG" "$WATCH_LOG"

BOOT_PID=""
TAIL_PID=""

log_watch() {
  local ts="$1"
  shift
  echo "[testing_exec][watch][$ts] $*" | tee -a "$WATCH_LOG"
}

cleanup() {
  if [[ -n "${TAIL_PID:-}" ]]; then
    kill "$TAIL_PID" 2>/dev/null || true
    wait "$TAIL_PID" 2>/dev/null || true
  fi
  if [[ -n "${BOOT_PID:-}" ]]; then
    kill "$BOOT_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

echo "[testing_exec] killing existing vphone-cli..."
pkill -9 vphone-cli 2>/dev/null || true
sleep 1

echo "[testing_exec] fw_prepare..."
make fw_prepare VM_DIR="$VM_DIR"

echo "[testing_exec] $PATCH_TARGET (base_patch=$BASE_PATCH)..."
make "$PATCH_TARGET" VM_DIR="$VM_DIR"

echo "[testing_exec] testing_ramdisk_build..."
make testing_ramdisk_build VM_DIR="$VM_DIR"

echo "[testing_exec] testing_ramdisk_send (background)..."
make testing_ramdisk_send VM_DIR="$VM_DIR" &
SEND_PID=$!

echo "[testing_exec] boot_dfu..."
log_watch "$(date '+%Y-%m-%d %H:%M:%S')" \
  "start boot_dfu, inactivity timeout=${WATCH_TIMEOUT_SECONDS}s, boot_log=$BOOT_LOG"

tail -n +1 -f "$BOOT_LOG" &
TAIL_PID=$!

make boot_dfu VM_DIR="$VM_DIR" >>"$BOOT_LOG" 2>&1 &
BOOT_PID=$!

LAST_SIZE="$(stat -f%z "$BOOT_LOG" 2>/dev/null || echo 0)"
LAST_ACTIVITY="$(date +%s)"
WATCHDOG_TRIGGERED=0

while kill -0 "$BOOT_PID" 2>/dev/null; do
  sleep 1
  CURRENT_SIZE="$(stat -f%z "$BOOT_LOG" 2>/dev/null || echo 0)"
  if (( CURRENT_SIZE > LAST_SIZE )); then
    LAST_SIZE="$CURRENT_SIZE"
    LAST_ACTIVITY="$(date +%s)"
  fi

  NOW="$(date +%s)"
  if (( NOW - LAST_ACTIVITY >= WATCH_TIMEOUT_SECONDS )); then
    WATCHDOG_TRIGGERED=1
    log_watch "$(date '+%Y-%m-%d %H:%M:%S')" \
      "no new boot output for ${WATCH_TIMEOUT_SECONDS}s, killing vphone-cli and boot_dfu"
    pkill -9 vphone-cli 2>/dev/null || true
    kill "$BOOT_PID" 2>/dev/null || true
    break
  fi
done

BOOT_STATUS=0
wait "$BOOT_PID" 2>/dev/null || BOOT_STATUS=$?

if (( WATCHDOG_TRIGGERED == 1 )); then
  log_watch "$(date '+%Y-%m-%d %H:%M:%S')" "watchdog timeout exit (124)"
  exit 124
fi

if (( BOOT_STATUS != 0 )); then
  log_watch "$(date '+%Y-%m-%d %H:%M:%S')" "boot_dfu failed with exit code $BOOT_STATUS"
  exit "$BOOT_STATUS"
fi

log_watch "$(date '+%Y-%m-%d %H:%M:%S')" "boot_dfu completed successfully"

wait "$SEND_PID" 2>/dev/null || true
