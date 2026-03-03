#!/bin/zsh
# setup_machine.sh — Full vphone machine bootstrap through "First Boot".
#
# Runs README flow up to (but not including) "Subsequent Boots":
# 1) Host deps + project setup/build
# 2) vm_new + fw_prepare + fw_patch (or fw_patch_jb with --jb)
# 3) DFU restore (boot_dfu + restore_get_shsh + restore)
# 4) Ramdisk + CFW (boot_dfu + ramdisk_build + ramdisk_send + iproxy + cfw_install / cfw_install_jb)
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
VM_DIR_ABS="${VM_DIR:A}"
AUTO_KILL_VM_LOCKS="${AUTO_KILL_VM_LOCKS:-1}"
POST_RESTORE_KILL_DELAY="${POST_RESTORE_KILL_DELAY:-30}"
POST_KILL_SETTLE_DELAY="${POST_KILL_SETTLE_DELAY:-5}"
RAMDISK_SSH_TIMEOUT="${RAMDISK_SSH_TIMEOUT:-60}"
RAMDISK_SSH_INTERVAL="${RAMDISK_SSH_INTERVAL:-2}"
RAMDISK_SSH_PORT="${RAMDISK_SSH_PORT:-2222}"
RAMDISK_SSH_USER="${RAMDISK_SSH_USER:-root}"
RAMDISK_SSH_PASS="${RAMDISK_SSH_PASS:-alpine}"
JB_MODE=0
SKIP_PROJECT_SETUP=0

die() {
  echo "[-] $*" >&2
  exit 1
}

require_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || die "Missing required command: $cmd"
}

collect_vm_lock_pids() {
  local -a paths pids
  local path pid
  typeset -U pids

  paths=(
    "${VM_DIR_ABS}/nvram.bin"
    "${VM_DIR_ABS}/machineIdentifier.bin"
    "${VM_DIR_ABS}/Disk.img"
    "${VM_DIR_ABS}/SEPStorage"
  )

  for path in "${paths[@]}"; do
    [[ -e "$path" ]] || continue
    while IFS= read -r pid; do
      [[ "$pid" == <-> ]] || continue
      [[ "$pid" == "$$" ]] && continue
      pids+=("$pid")
    done < <(lsof -t -- "$path" 2>/dev/null || true)
  done

  (( ${#pids[@]} > 0 )) && print -l -- "${pids[@]}" || true
}

check_vm_storage_locks() {
  if ! command -v lsof >/dev/null 2>&1; then
    echo "[!] lsof not found; skipping VM lock preflight."
    return
  fi

  local -a lock_pids
  lock_pids=(${(@f)$(collect_vm_lock_pids)})
  (( ${#lock_pids[@]} == 0 )) && return

  echo "[-] VM storage files are currently in use: ${VM_DIR_ABS}"
  echo "    This usually means another vphone process is still running."

  local pid proc_info
  for pid in "${lock_pids[@]}"; do
    [[ -z "$pid" || "$pid" == "$$" ]] && continue
    proc_info="$(ps -o pid=,ppid=,command= -p "$pid" 2>/dev/null || true)"
    [[ -n "$proc_info" ]] && echo "    $proc_info" || echo "    pid=$pid"
  done

  if [[ "$AUTO_KILL_VM_LOCKS" == "1" ]]; then
    echo "[*] AUTO_KILL_VM_LOCKS=1 set; terminating lock holder processes..."
    for pid in "${lock_pids[@]}"; do
      [[ -z "$pid" || "$pid" == "$$" ]] && continue
      kill_descendants "$pid"
      kill -9 "$pid" >/dev/null 2>&1 || true
    done
    sleep 1

    lock_pids=(${(@f)$(collect_vm_lock_pids)})
    (( ${#lock_pids[@]} == 0 )) && { echo "[+] Cleared VM storage locks"; return; }
    echo "[-] VM storage locks still present after AUTO_KILL_VM_LOCKS attempt."
  fi

  die "Stop those processes and retry. You can also set AUTO_KILL_VM_LOCKS=1."
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

force_release_vm_locks() {
  local -a lock_pids
  local pid

  lock_pids=(${(@f)$(collect_vm_lock_pids)})
  (( ${#lock_pids[@]} == 0 )) && return

  echo "[*] Releasing lingering VM lock holders..."
  for pid in "${lock_pids[@]}"; do
    [[ -z "$pid" || "$pid" == "$$" ]] && continue
    kill_descendants "$pid"
    kill -9 "$pid" >/dev/null 2>&1 || true
  done

  sleep 1
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
  check_vm_storage_locks

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

  check_vm_storage_locks

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
  force_release_vm_locks
}

wait_for_post_restore_reboot() {
  local remaining="${POST_RESTORE_KILL_DELAY}"
  local panic_seen=0

  echo "[*] Restore complete; waiting up to ${POST_RESTORE_KILL_DELAY}s for reboot/panic before stopping DFU..."
  while (( remaining > 0 )); do
    if [[ -f "$DFU_LOG" ]] && grep -Eiq 'panic|kernel panic' "$DFU_LOG"; then
      panic_seen=1
      break
    fi
    if [[ -n "$DFU_PID" ]] && ! kill -0 "$DFU_PID" 2>/dev/null; then
      echo "[*] DFU process exited during post-restore reboot window."
      return
    fi
    sleep 1
    (( remaining-- ))
  done

  if (( panic_seen == 1 )); then
    echo "[+] Panic marker observed; stopping DFU now."
  else
    echo "[*] No panic marker observed in ${POST_RESTORE_KILL_DELAY}s; stopping DFU anyway."
  fi
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
  local -a stale_pids
  local pid
  iproxy_bin="${PROJECT_ROOT}/.limd/bin/iproxy"
  [[ -x "$iproxy_bin" ]] || die "iproxy not found at $iproxy_bin (run: make setup_libimobiledevice)"

  stale_pids=(${(@f)$(lsof -n -t -iTCP:2222 -sTCP:LISTEN 2>/dev/null || true)})
  if (( ${#stale_pids[@]} > 0 )); then
    echo "[*] Found stale listener(s) on tcp/2222, terminating..."
    for pid in "${stale_pids[@]}"; do
      [[ -z "$pid" || "$pid" == "$$" ]] && continue
      kill_descendants "$pid"
      kill -9 "$pid" >/dev/null 2>&1 || true
    done
    sleep 1
  fi

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

wait_for_ramdisk_ssh() {
  local sshpass_bin
  local waited=0

  [[ "$RAMDISK_SSH_TIMEOUT" == <-> ]] || die "RAMDISK_SSH_TIMEOUT must be an integer (seconds)"
  [[ "$RAMDISK_SSH_INTERVAL" == <-> ]] || die "RAMDISK_SSH_INTERVAL must be an integer (seconds)"
  (( RAMDISK_SSH_TIMEOUT > 0 )) || die "RAMDISK_SSH_TIMEOUT must be > 0"
  (( RAMDISK_SSH_INTERVAL > 0 )) || die "RAMDISK_SSH_INTERVAL must be > 0"

  sshpass_bin="$(command -v sshpass || true)"
  [[ -x "$sshpass_bin" ]] || die "sshpass not found (run: make setup_tools)"

  echo "[*] Waiting for ramdisk SSH on ${RAMDISK_SSH_USER}@127.0.0.1:${RAMDISK_SSH_PORT} (timeout=${RAMDISK_SSH_TIMEOUT}s)..."
  while (( waited < RAMDISK_SSH_TIMEOUT )); do
    if "$sshpass_bin" -p "$RAMDISK_SSH_PASS" ssh \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      -o PreferredAuthentications=password \
      -o ConnectTimeout=5 \
      -q \
      -p "$RAMDISK_SSH_PORT" \
      "${RAMDISK_SSH_USER}@127.0.0.1" "echo ready" >/dev/null 2>&1
    then
      echo "[+] Ramdisk SSH is ready"
      return
    fi

    if (( waited == 0 || waited % 10 == 0 )); then
      echo "  waiting... ${waited}s elapsed"
    fi

    sleep "$RAMDISK_SSH_INTERVAL"
    (( waited += RAMDISK_SSH_INTERVAL ))
  done

  echo "[-] Timed out waiting for ramdisk SSH readiness."
  echo "[-] iproxy log tail:"
  tail -n 40 "$IPROXY_LOG" 2>/dev/null || true
  echo "[-] boot_dfu log tail:"
  tail -n 60 "$DFU_LOG" 2>/dev/null || true
  die "Ramdisk SSH did not become ready in ${RAMDISK_SSH_TIMEOUT}s."
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

parse_args() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --jb)
        JB_MODE=1
        ;;
      --skip-project-setup)
        SKIP_PROJECT_SETUP=1
        ;;
      -h|--help)
        cat <<'EOF'
Usage: setup_machine.sh [--jb] [--skip-project-setup]

Options:
  --jb                    Use jailbreak firmware patching + jailbreak CFW install.
  --skip-project-setup    Skip setup_tools/build stage.
EOF
        exit 0
        ;;
      *)
        die "Unknown argument: $arg"
        ;;
    esac
  done
}

main() {
  parse_args "$@"

  local fw_patch_target="fw_patch"
  local cfw_install_target="cfw_install"

  if [[ "$JB_MODE" -eq 1 ]]; then
    fw_patch_target="fw_patch_jb"
    cfw_install_target="cfw_install_jb"
  fi

  echo "[*] setup_machine mode: $([[ "$JB_MODE" -eq 1 ]] && echo "jailbreak" || echo "base"), project_setup=$([[ "$SKIP_PROJECT_SETUP" -eq 1 ]] && echo "skip" || echo "run")"

  if [[ "$SKIP_PROJECT_SETUP" -eq 1 ]]; then
    echo ""
    echo "=== Project setup ==="
    echo "[*] Skipping setup_tools/build"
  else
    check_platform
    install_brew_deps
    ensure_python_linked

    run_make "Project setup" setup_tools
    run_make "Project setup" build
  fi

  run_make "Firmware prep" vm_new
  run_make "Firmware prep" fw_prepare
  run_make "Firmware patch" "$fw_patch_target"

  echo ""
  echo "=== Restore phase ==="
  start_boot_dfu
  wait_for_recovery
  run_make "Restore" restore_get_shsh
  run_make "Restore" restore
  wait_for_post_restore_reboot
  stop_boot_dfu
  echo "[*] Waiting ${POST_KILL_SETTLE_DELAY}s for cleanup before ramdisk stage..."
  sleep "$POST_KILL_SETTLE_DELAY"

  echo ""
  echo "=== Ramdisk + CFW phase ==="
  start_boot_dfu
  wait_for_recovery
  run_make "Ramdisk" ramdisk_build
  run_make "Ramdisk" ramdisk_send
  start_iproxy_2222

  wait_for_ramdisk_ssh

  run_make "CFW install" "$cfw_install_target"
  stop_boot_dfu
  stop_iproxy_2222

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
