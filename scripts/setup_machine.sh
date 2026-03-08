#!/bin/zsh
# setup_machine.sh — Full vphone machine bootstrap through "First Boot".
#
# Runs README flow up to (but not including) "Subsequent Boots":
# 1) Host deps + project setup/build
# 2) vm_new + fw_prepare + fw_patch (or fw_patch_dev/ fw_patch_jb with --dev/--jb)
# 3) DFU restore (boot_dfu + restore_get_shsh + restore)
# 4) Ramdisk + CFW (boot_dfu + ramdisk_build + ramdisk_send + iproxy + cfw_install / cfw_install_dev / cfw_install_jb)
# 5) First boot launch (`make boot`) with printed in-guest commands

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "$PROJECT_ROOT"

LOG_DIR="${PROJECT_ROOT}/setup_logs"
DFU_LOG="${LOG_DIR}/boot_dfu.log"
IPROXY_LOG=""
BOOT_LOG="${LOG_DIR}/boot.log"

DFU_PID=""
IPROXY_PID=""
BOOT_PID=""
BOOT_FIFO=""
BOOT_FIFO_FD=""
SUDO_ASKPASS_SCRIPT=""

VM_DIR="${VM_DIR:-vm}"
VM_DIR_ABS="${VM_DIR:A}"
AUTO_KILL_VM_LOCKS="${AUTO_KILL_VM_LOCKS:-1}"
POST_RESTORE_KILL_DELAY="${POST_RESTORE_KILL_DELAY:-30}"
POST_KILL_SETTLE_DELAY="${POST_KILL_SETTLE_DELAY:-5}"
RAMDISK_SSH_TIMEOUT="${RAMDISK_SSH_TIMEOUT:-60}"
RAMDISK_SSH_INTERVAL="${RAMDISK_SSH_INTERVAL:-2}"
RAMDISK_SSH_PORT="${RAMDISK_SSH_PORT:-}"
RAMDISK_SSH_USER="${RAMDISK_SSH_USER:-root}"
RAMDISK_SSH_PASS="${RAMDISK_SSH_PASS:-alpine}"
IPROXY_UDID="${IPROXY_UDID:-}"
IPROXY_DEVICE_WAIT_TIMEOUT="${IPROXY_DEVICE_WAIT_TIMEOUT:-90}"
IPROXY_DEVICE_WAIT_INTERVAL="${IPROXY_DEVICE_WAIT_INTERVAL:-1}"
RAMDISK_SSH_PORT_EXPLICIT=0
if [[ -n "$RAMDISK_SSH_PORT" ]]; then
  RAMDISK_SSH_PORT_EXPLICIT=1
fi

DEVICE_UDID=""
DEVICE_ECID=""
IPROXY_TARGET_UDID=""
IPROXY_RESOLVE_REASON=""
BOOT_ANALYSIS_TIMEOUT="${BOOT_ANALYSIS_TIMEOUT:-300}"
BOOT_PROMPT_FALLBACK_TIMEOUT="${BOOT_PROMPT_FALLBACK_TIMEOUT:-60}"
BOOT_BASH_PROMPT_REGEX="${BOOT_BASH_PROMPT_REGEX:-bash-[0-9]+(\.[0-9]+)+#}"
BOOT_PANIC_REGEX="${BOOT_PANIC_REGEX:-panic|kernel panic|panic\\.apple\\.com|stackshot succeeded}"
NONE_INTERACTIVE_RAW="${NONE_INTERACTIVE:-0}"
NONE_INTERACTIVE=0
JB_MODE=0
DEV_MODE=0
SKIP_PROJECT_SETUP=0

die() {
  echo "[-] $*" >&2
  exit 1
}

require_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || die "Missing required command: $cmd"
}

normalize_ecid() {
  local ecid="$1"
  ecid="${ecid#0x}"
  ecid="${ecid#0X}"
  [[ "$ecid" =~ ^[0-9A-Fa-f]{1,16}$ ]] || return 1
  printf "%016s" "${ecid:u}" | tr ' ' '0'
}

load_device_identity() {
  local prediction_file="${VM_DIR_ABS}/udid-prediction.txt"
  local timeout=30
  local waited=0
  local key value
  local udid_ecid

  while [[ ! -f "$prediction_file" && "$waited" -lt "$timeout" ]]; do
    if [[ -n "$DFU_PID" ]] && ! kill -0 "$DFU_PID" 2>/dev/null; then
      break
    fi
    sleep 1
    (( waited++ ))
  done

  [[ -f "$prediction_file" ]] || die "Missing ${prediction_file}. Rebuild and run make boot_dfu to generate it."

  DEVICE_UDID=""
  DEVICE_ECID=""
  while IFS='=' read -r key value; do
    case "$key" in
      UDID)
        DEVICE_UDID="${value:u}"
        ;;
      ECID)
        DEVICE_ECID="$(normalize_ecid "$value" || true)"
        ;;
    esac
  done < "$prediction_file"

  [[ "$DEVICE_UDID" =~ ^[0-9A-F]{8}-[0-9A-F]{16}$ ]] \
    || die "Invalid UDID in ${prediction_file}: ${DEVICE_UDID}"

  if [[ -z "$DEVICE_ECID" ]]; then
    DEVICE_ECID="${DEVICE_UDID#*-}"
  fi
  [[ "$DEVICE_ECID" =~ ^[0-9A-F]{16}$ ]] \
    || die "Invalid ECID in ${prediction_file}: ${DEVICE_ECID}"

  udid_ecid="${DEVICE_UDID#*-}"
  [[ "$udid_ecid" == "$DEVICE_ECID" ]] \
    || die "UDID/ECID mismatch in ${prediction_file}: ${DEVICE_UDID} vs 0x${DEVICE_ECID}"

  echo "[+] Device identity loaded: UDID=${DEVICE_UDID} ECID=0x${DEVICE_ECID}"
}

list_usbmux_udids() {
  local idevice_id_bin
  idevice_id_bin="${PROJECT_ROOT}/.limd/bin/idevice_id"

  if [[ ! -x "$idevice_id_bin" ]]; then
    idevice_id_bin="$(command -v idevice_id || true)"
  fi
  [[ -x "$idevice_id_bin" ]] || return 0

  "$idevice_id_bin" -l 2>/dev/null | tr -d '\r' | sed '/^[[:space:]]*$/d'
}

print_usbmux_udids() {
  local -a udids
  local udid
  udids=(${(@f)$(list_usbmux_udids)})

  if (( ${#udids[@]} == 0 )); then
    echo "    (none)"
    return
  fi

  for udid in "${udids[@]}"; do
    echo "    - ${udid}"
  done
}

try_resolve_iproxy_target_udid() {
  local -a usbmux_udids ecid_matches
  local udid
  local ecid_lower

  IPROXY_TARGET_UDID=""
  IPROXY_RESOLVE_REASON=""

  if [[ -n "$IPROXY_UDID" ]]; then
    IPROXY_TARGET_UDID="$IPROXY_UDID"
    IPROXY_RESOLVE_REASON="override"
    return 0
  fi

  usbmux_udids=(${(@f)$(list_usbmux_udids)})
  if (( ${#usbmux_udids[@]} == 0 )); then
    IPROXY_RESOLVE_REASON="none"
    return 1
  fi

  for udid in "${usbmux_udids[@]}"; do
    if [[ "$udid" == "$DEVICE_UDID" ]]; then
      IPROXY_TARGET_UDID="$udid"
      IPROXY_RESOLVE_REASON="restore_match"
      return 0
    fi
  done

  ecid_lower="${DEVICE_ECID:l}"
  ecid_matches=()
  for udid in "${usbmux_udids[@]}"; do
    if [[ "${udid:l}" == *"${ecid_lower}"* ]]; then
      ecid_matches+=("$udid")
    fi
  done

  if (( ${#ecid_matches[@]} == 1 )); then
    IPROXY_TARGET_UDID="${ecid_matches[1]}"
    IPROXY_RESOLVE_REASON="ecid_match"
    return 0
  fi

  if (( ${#usbmux_udids[@]} == 1 )); then
    IPROXY_RESOLVE_REASON="single_mismatch"
    return 3
  fi

  IPROXY_RESOLVE_REASON="ambiguous"
  return 2
}

wait_for_iproxy_target_udid() {
  local timeout interval waited rc

  timeout="$IPROXY_DEVICE_WAIT_TIMEOUT"
  interval="$IPROXY_DEVICE_WAIT_INTERVAL"
  waited=0

  [[ "$timeout" == <-> ]] || die "IPROXY_DEVICE_WAIT_TIMEOUT must be an integer (seconds)"
  [[ "$interval" == <-> ]] || die "IPROXY_DEVICE_WAIT_INTERVAL must be an integer (seconds)"
  (( timeout > 0 )) || die "IPROXY_DEVICE_WAIT_TIMEOUT must be > 0"
  (( interval > 0 )) || die "IPROXY_DEVICE_WAIT_INTERVAL must be > 0"

  echo "[*] Resolving iproxy target UDID (timeout=${timeout}s)..."
  while (( waited < timeout )); do
    if try_resolve_iproxy_target_udid; then
      echo "[*] USBMux IDs currently visible:"
      print_usbmux_udids
      case "$IPROXY_RESOLVE_REASON" in
        override)
          echo "[*] Using explicit IPROXY_UDID override: ${IPROXY_TARGET_UDID}"
          ;;
        restore_match)
          echo "[+] iproxy target UDID matched restore UDID: ${IPROXY_TARGET_UDID}"
          ;;
        ecid_match)
          echo "[+] iproxy target UDID matched ECID substring: ${IPROXY_TARGET_UDID}"
          ;;
      esac
      return
    fi
    rc=$?

    if (( waited == 0 || waited % 5 == 0 )); then
      case "$rc" in
        2)
          echo "  waiting for USBMux disambiguation... ${waited}s elapsed"
          ;;
        3)
          echo "  waiting for restore UDID/ECID match (strict mode)... ${waited}s elapsed"
          ;;
        *)
          echo "  waiting for USBMux device... ${waited}s elapsed"
          ;;
      esac
    fi

    sleep "$interval"
    (( waited += interval ))
  done

  echo "[-] Timed out resolving iproxy target UDID after ${timeout}s."
  echo "[-] USBMux IDs currently visible:"
  print_usbmux_udids
  if [[ "$IPROXY_RESOLVE_REASON" == "single_mismatch" ]]; then
    die "Only non-matching USBMux device was visible. Strict identity isolation is enabled; wait for restore UDID/ECID or set IPROXY_UDID explicitly."
  fi
  if [[ "$IPROXY_RESOLVE_REASON" == "ambiguous" ]]; then
    die "Multiple USBMux devices detected and none uniquely matched restore UDID/ECID. Set IPROXY_UDID explicitly."
  fi
  die "No USBMux devices detected for iproxy. Ensure ramdisk has fully booted USB stack."
}

port_is_listening() {
  local port="$1"
  lsof -n -t -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1
}

pick_random_ssh_port() {
  local attempt port
  for attempt in {1..200}; do
    port=$((20000 + (RANDOM % 40000)))
    if ! port_is_listening "$port"; then
      echo "$port"
      return 0
    fi
  done
  return 1
}

choose_ramdisk_ssh_port() {
  if [[ -n "$RAMDISK_SSH_PORT" ]]; then
    [[ "$RAMDISK_SSH_PORT" == <-> ]] || die "RAMDISK_SSH_PORT must be an integer"
    (( RAMDISK_SSH_PORT >= 1 && RAMDISK_SSH_PORT <= 65535 )) \
      || die "RAMDISK_SSH_PORT out of range: ${RAMDISK_SSH_PORT}"
    if port_is_listening "$RAMDISK_SSH_PORT"; then
      die "RAMDISK_SSH_PORT ${RAMDISK_SSH_PORT} is already in use"
    fi
    return
  fi

  RAMDISK_SSH_PORT="$(pick_random_ssh_port)" \
    || die "Failed to allocate a random local SSH forward port"
}

parse_bool() {
  local raw="${1:-0}"
  # zsh `${var:l}` lowercases value for tolerant bool parsing.
  case "${raw:l}" in
    1|true|yes|on) return 0 ;;
    *) return 1 ;;
  esac
}

setup_sudo_noninteractive() {
  [[ -n "${SUDO_PASSWORD:-}" ]] || return 0

  SUDO_ASKPASS_SCRIPT="$(mktemp "${TMPDIR:-/tmp}/vphone-sudo-askpass.XXXXXX")"
  cat >"$SUDO_ASKPASS_SCRIPT" <<'EOF'
#!/bin/sh
printf '%s\n' "${SUDO_PASSWORD:-}"
EOF
  chmod 700 "$SUDO_ASKPASS_SCRIPT"
  export SUDO_ASKPASS="$SUDO_ASKPASS_SCRIPT"

  if sudo -A -v >/dev/null 2>&1; then
    echo "[+] sudo credential preloaded via SUDO_PASSWORD"
  else
    echo "[!] SUDO_PASSWORD provided but sudo -A validation failed; continuing without preload"
  fi
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
      stop_process_tree "$pid"
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

stop_process_tree() {
  local pid="$1"
  [[ -n "$pid" && "$pid" == <-> ]] || return 0
  kill -0 "$pid" 2>/dev/null || return 0

  kill_descendants "$pid"
  kill "$pid" >/dev/null 2>&1 || true
  sleep 1
  if kill -0 "$pid" 2>/dev/null; then
    kill -9 "$pid" >/dev/null 2>&1 || true
  fi
  wait "$pid" 2>/dev/null || true
}

force_release_vm_locks() {
  local -a lock_pids
  local pid

  lock_pids=(${(@f)$(collect_vm_lock_pids)})
  (( ${#lock_pids[@]} == 0 )) && return

  echo "[*] Releasing lingering VM lock holders..."
  for pid in "${lock_pids[@]}"; do
    [[ -z "$pid" || "$pid" == "$$" ]] && continue
    stop_process_tree "$pid"
  done

  sleep 1
}

cleanup() {
  if [[ -n "$BOOT_FIFO_FD" ]]; then
    exec {BOOT_FIFO_FD}>&- || true
    BOOT_FIFO_FD=""
  fi

  if [[ -n "$BOOT_PID" ]] && kill -0 "$BOOT_PID" 2>/dev/null; then
    stop_process_tree "$BOOT_PID"
    BOOT_PID=""
  fi

  if [[ -n "$BOOT_FIFO" && -p "$BOOT_FIFO" ]]; then
    rm -f "$BOOT_FIFO" || true
    BOOT_FIFO=""
  fi

  if [[ -n "$IPROXY_PID" ]]; then
    stop_process_tree "$IPROXY_PID"
    IPROXY_PID=""
  fi

  if [[ -n "$DFU_PID" ]]; then
    stop_process_tree "$DFU_PID"
    DFU_PID=""
  fi

  if [[ -n "$SUDO_ASKPASS_SCRIPT" && -f "$SUDO_ASKPASS_SCRIPT" ]]; then
    rm -f "$SUDO_ASKPASS_SCRIPT" || true
    SUDO_ASKPASS_SCRIPT=""
  fi
}

start_first_boot() {
  check_vm_storage_locks
  mkdir -p "$LOG_DIR"
  : > "$BOOT_LOG"

  BOOT_FIFO="$(mktemp -u "${TMPDIR:-/tmp}/vphone-first-boot.XXXXXX")"
  mkfifo "$BOOT_FIFO"

  (make boot <"$BOOT_FIFO" >"$BOOT_LOG" 2>&1) &
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
    "cp /iosbinpack64/etc/profile /var/profile"
    "cp /iosbinpack64/etc/motd /var/motd"
    # generate SSH host keys (required for SSH to work)
    mkdir -p /var/dropbear
    dropbearkey -t rsa -f /var/dropbear/dropbear_rsa_host_key
    dropbearkey -t ecdsa -f /var/dropbear/dropbear_ecdsa_host_key
    "shutdown -h now"
  )

  local cmd
  for cmd in "${commands[@]}"; do
    print -r -- "$cmd" >&${BOOT_FIFO_FD}
  done
}

monitor_boot_log_until() {
  local timeout="$1"
  local waited=0

  [[ "$timeout" == <-> ]] || die "monitor timeout must be integer seconds"
  (( timeout > 0 )) || die "monitor timeout must be > 0"

  while (( waited < timeout )); do
    if [[ -f "$BOOT_LOG" ]] && grep -Eiq "$BOOT_PANIC_REGEX" "$BOOT_LOG"; then
      echo "panic"
      return 0
    fi
    if [[ -f "$BOOT_LOG" ]] && grep -Eq "$BOOT_BASH_PROMPT_REGEX" "$BOOT_LOG"; then
      echo "bash"
      return 0
    fi
    if [[ -n "$BOOT_PID" ]] && ! kill -0 "$BOOT_PID" 2>/dev/null; then
      echo "exited"
      return 0
    fi
    sleep 1
    (( ++waited ))
  done

  echo "timeout"
}

wait_for_first_boot_prompt_auto() {
  local boot_state
  boot_state="$(monitor_boot_log_until "$BOOT_PROMPT_FALLBACK_TIMEOUT")"
  case "$boot_state" in
    panic)
      echo "[-] Panic detected while waiting for first-boot shell prompt."
      tail -n 80 "$BOOT_LOG" 2>/dev/null || true
      die "First boot panicked before command injection."
      ;;
    bash)
      echo "[+] First-boot shell prompt detected"
      ;;
    exited)
      echo "[-] make boot exited before first-boot command injection."
      tail -n 80 "$BOOT_LOG" 2>/dev/null || true
      die "First boot exited before command injection."
      ;;
    timeout)
      echo "[!] Shell prompt not detected within ${BOOT_PROMPT_FALLBACK_TIMEOUT}s; fallback to timed continue."
      ;;
  esac
}

wait_for_device_ssh() {
  local port="${1:-22222}"
  local timeout="${2:-120}"
  local pass="${3:-alpine}"
  local sshpass_bin waited=0

  sshpass_bin="$(command -v sshpass || true)"
  [[ -x "$sshpass_bin" ]] || die "sshpass not found (run: make setup_tools)"

  echo "[*] Waiting for device SSH on localhost:${port} (timeout=${timeout}s)..."
  while (( waited < timeout )); do
    if [[ -n "$BOOT_PID" ]] && ! kill -0 "$BOOT_PID" 2>/dev/null; then
      die "VM exited while waiting for device SSH."
    fi
    if "$sshpass_bin" -p "$pass" ssh \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      -o PreferredAuthentications=password \
      -o ConnectTimeout=5 -q \
      -p "$port" root@localhost "echo ready" >/dev/null 2>&1; then
      echo "[+] Device SSH is ready on port ${port}"
      return
    fi
    if (( waited == 0 || waited % 10 == 0 )); then
      echo "  waiting... ${waited}s elapsed"
    fi
    sleep 2
    (( waited += 2 ))
  done
  die "Device SSH not ready after ${timeout}s"
}

halt_device_ssh() {
  local port="${1:-22222}"
  local pass="${2:-alpine}"
  local sshpass_bin
  sshpass_bin="$(command -v sshpass)"
  echo "[*] Halting device via SSH..."
  "$sshpass_bin" -p "$pass" ssh \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o PreferredAuthentications=password \
    -o ConnectTimeout=10 -q \
    -p "$port" root@localhost "halt" 2>/dev/null || true
}

run_boot_analysis() {
  local boot_state

  check_vm_storage_locks
  mkdir -p "$LOG_DIR"
  : > "$BOOT_LOG"
  (make boot >"$BOOT_LOG" 2>&1) &
  BOOT_PID=$!

  sleep 2
  if ! kill -0 "$BOOT_PID" 2>/dev/null; then
    echo "[-] make boot exited early during boot analysis."
    tail -n 80 "$BOOT_LOG" 2>/dev/null || true
    die "Boot analysis failed: process exited early."
  fi

  boot_state="$(monitor_boot_log_until "$BOOT_ANALYSIS_TIMEOUT")"
  case "$boot_state" in
    panic)
      echo "[-] Boot analysis: panic detected, stopping VM."
      stop_process_tree "$BOOT_PID"
      BOOT_PID=""
      tail -n 80 "$BOOT_LOG" 2>/dev/null || true
      die "Boot analysis failed: panic detected."
      ;;
    bash)
      echo "[+] Boot analysis: bash prompt detected, boot success."
      stop_process_tree "$BOOT_PID"
      BOOT_PID=""
      ;;
    exited)
      echo "[-] Boot analysis: VM process exited before success marker."
      BOOT_PID=""
      tail -n 80 "$BOOT_LOG" 2>/dev/null || true
      die "Boot analysis failed: process exited."
      ;;
    timeout)
      echo "[-] Boot analysis timeout (${BOOT_ANALYSIS_TIMEOUT}s); stopping VM."
      stop_process_tree "$BOOT_PID"
      BOOT_PID=""
      tail -n 80 "$BOOT_LOG" 2>/dev/null || true
      die "Boot analysis timeout."
      ;;
  esac
}

trap cleanup EXIT INT TERM

check_platform() {
  [[ "$(uname -s)" == "Darwin" ]] || die "This script supports macOS only"

  local major
  major="$(sw_vers -productVersion | cut -d. -f1)"
  if [[ -z "$major" || "$major" -lt 15 ]]; then
    die "macOS 15+ required (detected: $(sw_vers -productVersion))"
  fi

  xcrun -sdk iphoneos --show-sdk-path >/dev/null 2>&1 \
    || die "iOS SDK not found. Full Xcode is required (Command Line Tools alone does not include the iOS SDK).\n  Install Xcode from the App Store, then run:\n    sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
}

install_brew_deps() {
  require_cmd brew

  local deps=(
    ideviceinstaller wget gnu-tar openssl@3 ldid-procursus sshpass keystone autoconf automake pkg-config libtool git-lfs
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
  if [[ -n "${SUDO_PASSWORD:-}" ]]; then
    sudo -A -v >/dev/null 2>&1 || true
  fi
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
    stop_process_tree "$DFU_PID"
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
  local -a query_args
  [[ -x "$irecovery" ]] || die "irecovery not found at $irecovery"

  if [[ -n "$DEVICE_ECID" ]]; then
    query_args=(-i "0x${DEVICE_ECID}")
  else
    query_args=()
  fi

  echo "[*] Waiting for recovery/DFU endpoint..."
  local i
  for i in {1..90}; do
    if "$irecovery" "${query_args[@]}" -q >/dev/null 2>&1; then
      echo "[+] Device endpoint is reachable"
      return
    fi
    sleep 2
  done

  echo "[-] Timed out waiting for device endpoint. Last DFU log lines:"
  tail -n 60 "$DFU_LOG" || true
  exit 1
}

start_iproxy() {
  local iproxy_bin
  iproxy_bin="${PROJECT_ROOT}/.limd/bin/iproxy"
  [[ -x "$iproxy_bin" ]] || die "iproxy not found at $iproxy_bin (run: make setup_libimobiledevice)"
  [[ -n "$DEVICE_UDID" ]] || die "Device UDID is empty; cannot resolve iproxy target"

  choose_ramdisk_ssh_port
  wait_for_iproxy_target_udid

  if port_is_listening "$RAMDISK_SSH_PORT"; then
    if [[ "$RAMDISK_SSH_PORT_EXPLICIT" == "1" ]]; then
      die "RAMDISK_SSH_PORT ${RAMDISK_SSH_PORT} is already in use"
    fi
    RAMDISK_SSH_PORT="$(pick_random_ssh_port)" \
      || die "Failed to allocate a free random local SSH forward port"
  fi

  IPROXY_LOG="${LOG_DIR}/iproxy_${RAMDISK_SSH_PORT}.log"
  mkdir -p "$LOG_DIR"
  : > "$IPROXY_LOG"

  echo "[*] Starting iproxy ${RAMDISK_SSH_PORT} -> 22 (target_udid=${IPROXY_TARGET_UDID}, restore_udid=${DEVICE_UDID}, ecid=0x${DEVICE_ECID})..."
  ("$iproxy_bin" -u "$IPROXY_TARGET_UDID" "$RAMDISK_SSH_PORT" 22 >"$IPROXY_LOG" 2>&1) &
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
    if [[ -n "$IPROXY_PID" ]] && ! kill -0 "$IPROXY_PID" 2>/dev/null; then
      echo "[-] iproxy process exited while waiting for ramdisk SSH."
      if [[ -n "$IPROXY_LOG" ]]; then
        echo "[-] iproxy log tail:"
        tail -n 40 "$IPROXY_LOG" 2>/dev/null || true
      fi
      die "iproxy exited before ramdisk SSH became ready."
    fi

    if [[ -f "$DFU_LOG" ]] && grep -Eiq 'panic|kernel panic|stackshot succeeded|panic\.apple\.com' "$DFU_LOG"; then
      echo "[-] Detected panic markers in boot_dfu log while waiting for ramdisk SSH."
      echo "[-] boot_dfu log tail:"
      tail -n 80 "$DFU_LOG" 2>/dev/null || true
      die "Ramdisk boot appears to have panicked before SSH became ready."
    fi

    if [[ -n "$DFU_PID" ]] && ! kill -0 "$DFU_PID" 2>/dev/null; then
      echo "[-] boot_dfu process exited while waiting for ramdisk SSH."
      echo "[-] boot_dfu log tail:"
      tail -n 80 "$DFU_LOG" 2>/dev/null || true
      die "DFU boot exited before ramdisk SSH became ready."
    fi

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
  echo "[-] Identity context: restore_udid=${DEVICE_UDID}, ecid=0x${DEVICE_ECID}, iproxy_target_udid=${IPROXY_TARGET_UDID}"
  echo "[-] USBMux IDs at timeout:"
  print_usbmux_udids
  if [[ -n "$IPROXY_LOG" ]]; then
    echo "[-] iproxy log tail:"
    tail -n 40 "$IPROXY_LOG" 2>/dev/null || true
  fi
  echo "[-] boot_dfu log tail:"
  tail -n 60 "$DFU_LOG" 2>/dev/null || true
  die "Ramdisk SSH did not become ready in ${RAMDISK_SSH_TIMEOUT}s."
}

stop_iproxy() {
  if [[ -n "$IPROXY_PID" ]] && kill -0 "$IPROXY_PID" 2>/dev/null; then
    echo "[*] Stopping iproxy (pid=$IPROXY_PID)..."
    stop_process_tree "$IPROXY_PID"
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
      --dev)
        DEV_MODE=1
        ;;
      --skip-project-setup)
        SKIP_PROJECT_SETUP=1
        ;;
      -h|--help)
        cat <<'EOF'
Usage: setup_machine.sh [--jb] [--dev] [--skip-project-setup]

Options:
  --jb                    Use jailbreak firmware patching + jailbreak CFW install.
  --dev                   Use dev firmware patching + dev CFW install.
  --skip-project-setup    Skip setup_tools/build stage.

Environment:
  NONE_INTERACTIVE=1      Auto-continue first-boot prompts + run final boot analysis.
  SUDO_PASSWORD=...       Preload sudo credential via askpass.
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
  if parse_bool "$NONE_INTERACTIVE_RAW"; then
    NONE_INTERACTIVE=1
  fi
  setup_sudo_noninteractive

  local fw_patch_target="fw_patch"
  local cfw_install_target="cfw_install"
  local mode_label="base"

  if [[ "$JB_MODE" -eq 1 && "$DEV_MODE" -eq 1 ]]; then
    die "--jb and --dev are mutually exclusive"
  fi

  if [[ "$JB_MODE" -eq 1 ]]; then
    fw_patch_target="fw_patch_jb"
    cfw_install_target="cfw_install_jb"
    mode_label="jailbreak"
  elif [[ "$DEV_MODE" -eq 1 ]]; then
    fw_patch_target="fw_patch_dev"
    cfw_install_target="cfw_install_dev"
    mode_label="dev"
  fi

  echo "[*] setup_machine mode: ${mode_label}, project_setup=$([[ "$SKIP_PROJECT_SETUP" -eq 1 ]] && echo "skip" || echo "run"), non_interactive=${NONE_INTERACTIVE}"

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
  load_device_identity
  wait_for_recovery
  run_make "Restore" restore_get_shsh RESTORE_UDID="$DEVICE_UDID" RESTORE_ECID="0x$DEVICE_ECID"
  run_make "Restore" restore RESTORE_UDID="$DEVICE_UDID" RESTORE_ECID="0x$DEVICE_ECID"
  wait_for_post_restore_reboot
  stop_boot_dfu
  echo "[*] Waiting ${POST_KILL_SETTLE_DELAY}s for cleanup before ramdisk stage..."
  sleep "$POST_KILL_SETTLE_DELAY"

  echo ""
  echo "=== Ramdisk + CFW phase ==="
  start_boot_dfu
  load_device_identity
  wait_for_recovery
  run_make "Ramdisk" ramdisk_build RAMDISK_UDID="$DEVICE_UDID"
  echo "[*] Ramdisk identity context: restore_udid=${DEVICE_UDID} ecid=0x${DEVICE_ECID}"
  run_make "Ramdisk" ramdisk_send IRECOVERY_ECID="0x$DEVICE_ECID" RAMDISK_UDID="$DEVICE_UDID"
  start_iproxy

  wait_for_ramdisk_ssh

  run_make "CFW install" "$cfw_install_target" SSH_PORT="$RAMDISK_SSH_PORT"
  stop_boot_dfu
  stop_iproxy

  echo ""
  echo "=== First boot ==="
  if [[ "$NONE_INTERACTIVE" -eq 0 ]]; then
    read -r "?[*] press Enter to start VM, after the VM has finished booting, press Enter again to finish last stage"
  else
    echo "[*] NONE_INTERACTIVE=1: auto-starting first boot"
  fi

  start_first_boot

  if [[ "$NONE_INTERACTIVE" -eq 0 ]]; then
    read -r "?[*] Press Enter once the VM is fully booted"
  else
    wait_for_first_boot_prompt_auto
  fi
  send_first_boot_commands

  echo "[*] Commands sent. Waiting for VM shutdown..."
  wait "$BOOT_PID"
  BOOT_PID=""

  exec {BOOT_FIFO_FD}>&- || true
  BOOT_FIFO_FD=""
  rm -f "$BOOT_FIFO" || true
  BOOT_FIFO=""

  if [[ "$JB_MODE" -eq 1 ]]; then
    echo ""
    echo "=== JB Finalize ==="
    echo "[*] JB finalization will run automatically on first normal boot"
    echo "    via /cores/vphone_jb_setup.sh (LaunchDaemon)."
    echo "    Monitor progress via vphoned file browser: /var/log/vphone_jb_setup.log"
  fi

  echo ""
  echo "=== Done ==="
  echo "Setup completed."

  echo "=== Boot analysis ==="
  run_boot_analysis
}

main "$@"
