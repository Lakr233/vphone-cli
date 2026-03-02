#!/bin/zsh
# setup_machine.sh — Full vphone machine bootstrap through "First Boot".
#
# Runs README flow up to (but not including) "Subsequent Boots":
# 1) Host deps + project setup/build
# 2) vm_new + fw_prepare + fw_patch
# 3) DFU restore (boot_dfu + restore_get_shsh + restore)
# 4) Ramdisk + CFW (boot_dfu + ramdisk_build + ramdisk_send + iproxy + cfw_install)
# 5) First boot launch (`make boot`) with printed in-guest commands

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "$PROJECT_ROOT"

LOG_DIR="${PROJECT_ROOT}/setup_logs"
DFU_LOG="${LOG_DIR}/boot_dfu.log"
IPROXY_LOG="${LOG_DIR}/iproxy_2222.log"

DFU_PID=""
IPROXY_PID=""
BOOT_PID=""
BOOT_FIFO=""
BOOT_FIFO_FD=""

VM_DIR="${VM_DIR:-vm}"

die() {
  echo "[-] $*" >&2
  exit 1
}

require_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || die "Missing required command: $cmd"
}

list_descendants() {
  local pid
  local -a children

  children=("${(@f)$(pgrep -P "$1" 2>/dev/null || true)}")
  for pid in "${children[@]}"; do
    [[ -z "$pid" ]] && continue
    list_descendants "$pid"
    print -r -- "$pid"
  done
}

kill_descendants() {
  local -a descendants
  descendants=("${(@f)$(list_descendants "$1")}")
  [[ ${#descendants[@]} -gt 0 ]] && kill -9 "${descendants[@]}" >/dev/null 2>&1 || true
}

cleanup() {
  if [[ -n "$BOOT_FIFO_FD" ]]; then
    exec {BOOT_FIFO_FD}>&- || true
    BOOT_FIFO_FD=""
  fi

  if [[ -n "$BOOT_PID" ]] && kill -0 "$BOOT_PID" 2>/dev/null; then
    kill_descendants "$BOOT_PID"
    kill -9 "$BOOT_PID" >/dev/null 2>&1 || true
    wait "$BOOT_PID" 2>/dev/null || true
    BOOT_PID=""
  fi

  if [[ -n "$BOOT_FIFO" && -p "$BOOT_FIFO" ]]; then
    rm -f "$BOOT_FIFO" || true
    BOOT_FIFO=""
  fi

  if [[ -n "$IPROXY_PID" ]]; then
    kill -9 "$IPROXY_PID" >/dev/null 2>&1 || true
    wait "$IPROXY_PID" 2>/dev/null || true
    IPROXY_PID=""
  fi

  if [[ -n "$DFU_PID" ]]; then
    kill_descendants "$DFU_PID"
    kill -9 "$DFU_PID" >/dev/null 2>&1 || true
    wait "$DFU_PID" 2>/dev/null || true
    DFU_PID=""
  fi
}

start_first_boot() {
  BOOT_FIFO="$(mktemp -u "${TMPDIR:-/tmp}/vphone-first-boot.XXXXXX")"
  mkfifo "$BOOT_FIFO"

  make boot <"$BOOT_FIFO" &
  BOOT_PID=$!

  exec {BOOT_FIFO_FD}>"$BOOT_FIFO"

  sleep 2
  if ! kill -0 "$BOOT_PID" 2>/dev/null; then
    die "make boot exited early during first boot stage"
  fi
}

send_first_boot_commands() {
  [[ -n "$BOOT_FIFO_FD" ]] || die "First boot command channel is not open"

  local commands=(
    "export PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/bin/X11:/usr/games:/iosbinpack64/usr/local/sbin:/iosbinpack64/usr/local/bin:/iosbinpack64/usr/sbin:/iosbinpack64/usr/bin:/iosbinpack64/sbin:/iosbinpack64/bin'"
    "mkdir -p /var/dropbear"
    "cp /iosbinpack64/etc/profile /var/profile"
    "cp /iosbinpack64/etc/motd /var/motd"
    "dropbearkey -t rsa -f /var/dropbear/dropbear_rsa_host_key"
    "dropbearkey -t ecdsa -f /var/dropbear/dropbear_ecdsa_host_key"
    "shutdown -h now"
  )

  local cmd
  for cmd in "${commands[@]}"; do
    print -r -- "$cmd" >&${BOOT_FIFO_FD}
  done
}

trap cleanup EXIT INT TERM

check_platform() {
  [[ "$(uname -s)" == "Darwin" ]] || die "This script supports macOS only"

  local major
  major="$(sw_vers -productVersion | cut -d. -f1)"
  if [[ -z "$major" || "$major" -lt 14 ]]; then
    die "macOS 14+ required (detected: $(sw_vers -productVersion))"
  fi
}

install_brew_deps() {
  require_cmd brew

  local deps=(
    autoconf
    automake
    cmake
    git
    keystone
    libtool
    pkg-config
    python@3.13
  )

  echo "=== Installing Homebrew dependencies ==="
  for pkg in "${deps[@]}"; do
    if brew list --formula "$pkg" >/dev/null 2>&1; then
      echo "  $pkg: already installed"
    else
      echo "  $pkg: installing"
      brew install "$pkg"
    fi
  done
  echo ""
}

ensure_python_linked() {
  if ! command -v python3.13 >/dev/null 2>&1; then
    local pybin
    pybin="$(brew --prefix python@3.13)/bin"
    export PATH="$pybin:$PATH"
  fi

  require_cmd python3.13
}

run_make() {
  local label="$1"
  shift

  echo ""
  echo "=== ${label} ==="
  make "$@"
}

start_boot_dfu() {
  mkdir -p "$LOG_DIR"

  if [[ -n "$DFU_PID" ]] && kill -0 "$DFU_PID" 2>/dev/null; then
    return
  fi

  : > "$DFU_LOG"
  echo "[*] Starting DFU boot in background..."
  (make boot_dfu >"$DFU_LOG" 2>&1) &
  DFU_PID=$!

  sleep 2
  if ! kill -0 "$DFU_PID" 2>/dev/null; then
    echo "[-] make boot_dfu exited early. Last log lines:"
    tail -n 40 "$DFU_LOG" || true
    exit 1
  fi

  echo "[+] boot_dfu running (pid=$DFU_PID, log=$DFU_LOG)"
}

stop_boot_dfu() {
  if [[ -n "$DFU_PID" ]] && kill -0 "$DFU_PID" 2>/dev/null; then
    echo "[*] Stopping background DFU boot (pid=$DFU_PID)..."
    kill_descendants "$DFU_PID"
    kill -9 "$DFU_PID" >/dev/null 2>&1 || true
    wait "$DFU_PID" 2>/dev/null || true
  fi
  DFU_PID=""
}

wait_for_recovery() {
  local irecovery="${PROJECT_ROOT}/.limd/bin/irecovery"
  [[ -x "$irecovery" ]] || die "irecovery not found at $irecovery"

  echo "[*] Waiting for recovery/DFU endpoint..."
  local i
  for i in {1..90}; do
    if "$irecovery" -q >/dev/null 2>&1; then
      echo "[+] Device endpoint is reachable"
      return
    fi
    sleep 2
  done

  echo "[-] Timed out waiting for device endpoint. Last DFU log lines:"
  tail -n 60 "$DFU_LOG" || true
  exit 1
}

start_iproxy_2222() {
  local iproxy_bin
  iproxy_bin="${PROJECT_ROOT}/.limd/bin/iproxy"
  [[ -x "$iproxy_bin" ]] || die "iproxy not found at $iproxy_bin (run: make setup_libimobiledevice)"

  mkdir -p "$LOG_DIR"
  : > "$IPROXY_LOG"

  echo "[*] Starting iproxy 2222 -> 22..."
  ("$iproxy_bin" 2222 22 >"$IPROXY_LOG" 2>&1) &
  IPROXY_PID=$!

  sleep 1
  if ! kill -0 "$IPROXY_PID" 2>/dev/null; then
    echo "[-] iproxy exited early. Log:"
    tail -n 40 "$IPROXY_LOG" || true
    exit 1
  fi

  echo "[+] iproxy running (pid=$IPROXY_PID, log=$IPROXY_LOG)"
}

stop_iproxy_2222() {
  if [[ -n "$IPROXY_PID" ]] && kill -0 "$IPROXY_PID" 2>/dev/null; then
    echo "[*] Stopping iproxy (pid=$IPROXY_PID)..."
    kill_descendants "$IPROXY_PID"
    kill -9 "$IPROXY_PID" >/dev/null 2>&1 || true
    wait "$IPROXY_PID" 2>/dev/null || true
  fi
  IPROXY_PID=""
}

main() {
  check_platform
  install_brew_deps
  ensure_python_linked

  run_make "Project setup" setup_libimobiledevice
  run_make "Project setup" setup_venv
  run_make "Project setup" build

  run_make "Firmware prep" vm_new
  run_make "Firmware prep" fw_prepare
  run_make "Firmware patch" fw_patch

  echo ""
  echo "=== Restore phase ==="
  start_boot_dfu
  wait_for_recovery
  run_make "Restore" restore_get_shsh
  run_make "Restore" restore
  stop_boot_dfu

  echo ""
  echo "=== Ramdisk + CFW phase ==="
  start_boot_dfu
  wait_for_recovery
  run_make "Ramdisk" ramdisk_build
  run_make "Ramdisk" ramdisk_send
  start_iproxy_2222

  sleep 10 # for some reason there is a statistical faiure here if not enough time is given to initialization

  run_make "CFW install" cfw_install
  stop_iproxy_2222
  stop_boot_dfu

  echo ""
  echo "=== First boot ==="
  read -r "?[*] press Enter to start VM, after the VM has finished booting, press Enter again to finish last stage"

  start_first_boot

  read -r "?[*] Press Enter once the VM is fully booted"
  send_first_boot_commands

  echo "[*] Commands sent. Waiting for VM shutdown..."
  wait "$BOOT_PID"
  BOOT_PID=""

  exec {BOOT_FIFO_FD}>&- || true
  BOOT_FIFO_FD=""
  rm -f "$BOOT_FIFO" || true
  BOOT_FIFO=""

  echo ""
  echo "=== Done ==="
  echo "Setup completed."

  echo "=== Booting VM ==="
  run_make "Booting VM" boot
}

main "$@"
