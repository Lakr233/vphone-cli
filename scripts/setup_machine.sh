#!/bin/zsh
# setup_machine.sh — Full vphone machine bootstrap through "First Boot".
#
# Runs README flow up to (but not including) "Subsequent Boots":
# 1) Host deps + project setup/build
# 2) vm_new + fw_prepare + fw_patch (or fw_patch_dev/ fw_patch_jb with --dev/--jb)
# 3) DFU restore (boot_dfu + restore_get_shsh + restore)
# 4) CFW install — host-mount install + offline snapshot flip
#    (cfw_install_host, VM off)
# 5) First boot launch (`make boot`) with printed in-guest commands

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "$PROJECT_ROOT"

LOG_DIR="${PROJECT_ROOT}/setup_logs"
DFU_LOG="${LOG_DIR}/boot_dfu.log"
BOOT_LOG="${LOG_DIR}/boot.log"

DFU_PID=""
BOOT_PID=""
BOOT_FIFO=""
BOOT_FIFO_FD=""
SUDO_ASKPASS_SCRIPT=""

VM_DIR="${VM_DIR:-vm}"
VM_DIR_ABS="${VM_DIR:A}"
AUTO_KILL_VM_LOCKS="${AUTO_KILL_VM_LOCKS:-1}"
POST_RESTORE_KILL_DELAY="${POST_RESTORE_KILL_DELAY:-30}"
POST_KILL_SETTLE_DELAY="${POST_KILL_SETTLE_DELAY:-5}"

DEVICE_UDID=""
DEVICE_ECID=""
BOOT_ANALYSIS_TIMEOUT="${BOOT_ANALYSIS_TIMEOUT:-300}"
BOOT_PROMPT_FALLBACK_TIMEOUT="${BOOT_PROMPT_FALLBACK_TIMEOUT:-60}"
BOOT_BASH_PROMPT_REGEX="${BOOT_BASH_PROMPT_REGEX:-bash-[0-9]+(\.[0-9]+)+#|:/[^ ]* root#}"
BOOT_PANIC_REGEX="${BOOT_PANIC_REGEX:-(^|[^p])(panic|kernel panic|panic\\.apple\\.com|stackshot succeeded)}"
PMD3_BRIDGE="${PMD3_BRIDGE:-${PROJECT_ROOT}/scripts/pymobiledevice3_bridge.py}"
INTERACTIVE_RAW="${INTERACTIVE:-0}"
NON_INTERACTIVE=1
NO_BINPACK_RAW="${NO_BINPACK:-0}"
NO_BINPACK=0
NO_VPHONED_RAW="${NO_VPHONED:-0}"
NO_VPHONED=0
JB_MODE=0
DEV_MODE=0
EXP_MODE=0
LESS_MODE=0
SKIP_PROJECT_SETUP=0

die() {
  echo "[-] $*" >&2
  exit 1
}

require_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || die "Missing required command: $cmd"
}

find_python_for_pmd3() {
  local candidate
  for candidate in \
    "${PROJECT_ROOT}/.venv/bin/python3" \
    "$(command -v python3 2>/dev/null || true)"
  do
    [[ -n "$candidate" ]] || continue
    [[ -x "$candidate" ]] || continue
    if "$candidate" -c "import pymobiledevice3" >/dev/null 2>&1; then
      echo "$candidate"
      return 0
    fi
  done
  return 1
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
    waited=$(( waited + 1 ))
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

kill_stale_vphone_procs() {
  local vphone_bin="${PROJECT_ROOT}/.build/release/vphone-cli"
  local -a stale_pids
  stale_pids=(${(@f)$(pgrep -f "$vphone_bin" 2>/dev/null || true)})
  (( ${#stale_pids[@]} == 0 )) && return

  echo "[*] Found stale vphone-cli process(es) (pids: ${stale_pids[*]}); terminating..."
  for pid in "${stale_pids[@]}"; do
    [[ "$pid" == "$$" ]] && continue
    stop_process_tree "$pid"
  done

  # Wait up to 8s for VZ file locks to clear (flock/fcntl locks may lag behind process exit)
  local waited=0
  while (( waited < 8 )); do
    local -a remaining
    remaining=(${(@f)$(collect_vm_lock_pids)})
    (( ${#remaining[@]} == 0 )) && break
    sleep 1
    waited=$(( waited + 1 ))
  done
  echo "[+] Stale vphone-cli processes cleared"
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

  local target="boot"
  if [ "$1" -eq 1 ]; then
    target="boot_less"
  fi

  BOOT_FIFO="$(mktemp -u "${TMPDIR:-/tmp}/vphone-first-boot.XXXXXX")"
  mkfifo "$BOOT_FIFO"

  (make "$target" <"$BOOT_FIFO" >"$BOOT_LOG" 2>&1) &
  BOOT_PID=$!

  exec {BOOT_FIFO_FD}>"$BOOT_FIFO"

  sleep 2
  if ! kill -0 "$BOOT_PID" 2>/dev/null; then
    die "make $target exited early during first boot stage"
  fi
}

send_first_boot_commands() {
  [[ -n "$BOOT_FIFO_FD" ]] || die "First boot command channel is not open"

  local commands=(
    "export PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/bin/X11:/usr/games:/iosbinpack64/usr/local/sbin:/iosbinpack64/usr/local/bin:/iosbinpack64/usr/sbin:/iosbinpack64/usr/bin:/iosbinpack64/sbin:/iosbinpack64/bin'"
    "cp /iosbinpack64/etc/profile /var/profile"
    "cp /iosbinpack64/etc/motd /var/motd"
    "mkdir -p /var/dropbear"
    "dropbearkey -t rsa -f /var/dropbear/dropbear_rsa_host_key"
    "dropbearkey -t ecdsa -f /var/dropbear/dropbear_ecdsa_host_key"
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
    waited=$(( waited + 1 ))
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
    wget gnu-tar openssl@3 ldid-procursus sshpass keystone git-lfs
    python@3.13 libusb ipsw
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

run_make_sudo() {
  local label="$1"
  shift

  echo ""
  echo "=== ${label} ==="
  if [[ -n "${SUDO_PASSWORD:-}" ]]; then
    sudo -A -E -- make "$@"
  else
    sudo -E -- make "$@"
  fi
}

start_boot_dfu() {
  mkdir -p "$LOG_DIR"

  if [[ -n "$DFU_PID" ]] && kill -0 "$DFU_PID" 2>/dev/null; then
    return
  fi

  kill_stale_vphone_procs
  check_vm_storage_locks

  # Remove stale prediction file so load_device_identity waits for the fresh
  # one written by this boot, avoiding an ECID mismatch race.
  rm -f "${VM_DIR_ABS}/udid-prediction.txt"

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
    remaining=$(( remaining - 1 ))
  done

  if (( panic_seen == 1 )); then
    echo "[+] Panic marker observed; stopping DFU now."
  else
    echo "[*] No panic marker observed in ${POST_RESTORE_KILL_DELAY}s; stopping DFU anyway."
  fi
}

wait_for_recovery() {
  local pmd3_python
  pmd3_python="$(find_python_for_pmd3 || true)"
  [[ -x "$pmd3_python" ]] || die "pymobiledevice3 python runtime not found (run: make setup_tools)"
  [[ -f "$PMD3_BRIDGE" ]] || die "Missing bridge script: $PMD3_BRIDGE"

  echo "[*] Waiting for recovery/DFU endpoint..."
  local i
  for i in {1..90}; do
    if "$pmd3_python" "$PMD3_BRIDGE" recovery-probe --ecid "0x${DEVICE_ECID}" --timeout 2 >/dev/null 2>&1; then
      echo "[+] Device endpoint is reachable"
      return
    fi
    sleep 2
  done

  echo "[-] Timed out waiting for device endpoint. Last DFU log lines:"
  tail -n 60 "$DFU_LOG" || true
  exit 1
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
      --exp)
        EXP_MODE=1
        ;;
      --less)
        LESS_MODE=1
        ;;
      --skip-project-setup)
        SKIP_PROJECT_SETUP=1
        ;;
      -h|--help)
        cat <<'EOF'
Usage: setup_machine.sh [--jb] [--dev] [--exp] [--less] [--skip-project-setup]

Options:
  --jb                    Use jailbreak firmware patching + jailbreak CFW install.
  --dev                   Use dev firmware patching + dev CFW install.
  --exp                   Use experimental firmware patching + EXP CFW install
                          (JB + kernel hv_vmm rename, DSC byte-5 mangle, watchdogd
                          surgical patch, DT identity properties, post-restore DT
                          rewrite, opt-in build-version spoof via SPOOF_BUILD).
  --less                  Use patchless firmware patching + CFW install.
  --skip-project-setup    Skip setup_tools/build stage.

Environment:
  INTERACTIVE=1           Prompt at first-boot stages (default: non-interactive — auto-continue + boot analysis).
  SUDO_PASSWORD=...       Preload sudo credential via askpass.
  NO_BINPACK=1            Excludes the SSH, VNC, ... binaries from being installed (patchless-only, currently)
  NO_VPHONED=1            Excludes vphoned from being installed (patchless-only, currently)
  SPOOF_BUILD=<id>        (EXP only) Rewrite SystemVersion.plist ProductBuildVersion
                          to <id> (e.g. 23F77). Omitted/empty -> skipped.
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
  if parse_bool "$INTERACTIVE_RAW"; then
    NON_INTERACTIVE=0
  fi
  if parse_bool "$NO_BINPACK_RAW"; then
    NO_BINPACK=1
  fi
  if parse_bool "$NO_VPHONED_RAW"; then
    NO_VPHONED=1
  fi
  setup_sudo_noninteractive

  local fw_patch_target="fw_patch"
  local cfw_variant="regular"      # variant for `cfw_install_host`
  local mode_label="base"

  if (( JB_MODE + DEV_MODE + EXP_MODE + LESS_MODE > 1 )); then
    die "--jb, --dev, --exp, and --less are mutually exclusive"
  fi

  if [[ "$JB_MODE" -eq 1 ]]; then
    fw_patch_target="fw_patch_jb"
    cfw_variant="jb"
    mode_label="jailbreak"
  elif [[ "$DEV_MODE" -eq 1 ]]; then
    fw_patch_target="fw_patch_dev"
    cfw_variant="dev"
    mode_label="dev"
  elif [[ "$EXP_MODE" -eq 1 ]]; then
    fw_patch_target="fw_patch_exp"
    cfw_variant="exp"
    mode_label="experimental"
  elif [[ "$LESS_MODE" -eq 1 ]]; then
    fw_patch_target="fw_patch_less"
    cfw_variant=""
    mode_label="less"
  fi

  echo "[*] setup_machine mode: ${mode_label}, project_setup=$([[ "$SKIP_PROJECT_SETUP" -eq 1 ]] && echo "skip" || echo "run"), non_interactive=${NON_INTERACTIVE}, no_binpack=${NO_BINPACK}, no_vphoned=${NO_VPHONED}"

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

  # Activate venv so all child scripts (cfw_install, patchers, etc.) use the
  # project Python with capstone/keystone/pyimg4 installed, not the bare system python3.
  export PATH="$PROJECT_ROOT/.venv/bin:$PATH"

  run_make "Firmware prep" vm_new
  if [[ "$LESS_MODE" -eq 0 ]]; then
    run_make "Firmware prep" fw_prepare
    run_make "Firmware patch" "$fw_patch_target"
  else
    VARIANT=less run_make "Firmware prep" fw_prepare
    run_make_sudo "Firmware patch" "$fw_patch_target"
  fi

  echo ""
  echo "=== Restore phase ==="
  start_boot_dfu
  load_device_identity
  wait_for_recovery
  run_make "Restore" restore_get_shsh RESTORE_UDID="$DEVICE_UDID" RESTORE_ECID="0x$DEVICE_ECID"
  run_make "Restore" restore RESTORE_UDID="$DEVICE_UDID" RESTORE_ECID="0x$DEVICE_ECID"
  wait_for_post_restore_reboot
  stop_boot_dfu

  if [[ "$LESS_MODE" -eq 0 ]]; then
    echo "[*] Waiting ${POST_KILL_SETTLE_DELAY}s for cleanup before CFW install..."
    sleep "$POST_KILL_SETTLE_DELAY"

    # Host-mount CFW install + offline snapshot flip. The VM is off after the
    # restore phase, so we attach Disk.img on the host, place all CFW files, and
    # rename the boot snapshot offline. cfw_install_host re-execs under sudo
    # (SUDO_ASKPASS from setup_sudo_noninteractive when SUDO_PASSWORD is set).
    echo ""
    echo "=== CFW install (host-mount) ==="
    check_vm_storage_locks
    run_make "CFW install" cfw_install_host VARIANT="$cfw_variant" SPOOF_BUILD="${SPOOF_BUILD:-}"
  fi

  if [[ "$LESS_MODE" -eq 0 || "$NO_BINPACK" -eq 0 ]]; then
    echo ""
    echo "=== First boot ==="
    if [[ "$NON_INTERACTIVE" -eq 0 ]]; then
      read -r "?[*] press Enter to start VM, after the VM has finished booting, press Enter again to finish last stage"
    else
      echo "[*] non-interactive (default): auto-starting first boot"
    fi

    start_first_boot "$LESS_MODE"

    if [[ "$NON_INTERACTIVE" -eq 0 ]]; then
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
  fi

  if [[ "$JB_MODE" -eq 1 || "$EXP_MODE" -eq 1 ]]; then
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
  if [[ "$LESS_MODE" -eq 0 ]]; then
    run_boot_analysis
  else
    run_make "Start VM" boot_less
  fi
}

main "$@"
