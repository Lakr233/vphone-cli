#!/bin/zsh
# vphone-tier: build
# tail_jb_patch_logs.sh — follow the guest's first-boot JB setup log.
set -euo pipefail
unsetopt BG_NICE 2>/dev/null || true

TARGET_DIR="${1:-}"
TAIL_LINES="${2:-20}"
SCAN_INTERVAL="${SCAN_INTERVAL:-1}"

if [[ -z "$TARGET_DIR" ]]; then
  echo "Usage: $0 <log_dir> [tail_lines]" >&2
  exit 1
fi

if [[ ! -d "$TARGET_DIR" ]]; then
  echo "Error: log directory not found: $TARGET_DIR" >&2
  echo "Usage: $0 <log_dir> [tail_lines]" >&2
  exit 1
fi

typeset -A seen_files
typeset -a tail_pids

cleanup() {
  local pid
  for pid in "${tail_pids[@]-}"; do
    kill "$pid" 2>/dev/null || true
  done
}
trap cleanup EXIT INT TERM

start_tail_for_file() {
  local file="$1"
  local label="${file:t}"

  [[ -n "${seen_files[$file]-}" ]] && return 0
  seen_files["$file"]=1

  echo "[watch] $file"
  (
    tail -n "$TAIL_LINES" -F -- "$file" 2>&1 \
      | awk -v p="$label" '{ print "[" p "] " $0; fflush(); }'
  ) &
  tail_pids+=("$!")
}

discover_files() {
  local file
  for file in "$TARGET_DIR"/**/*(.N); do
    start_tail_for_file "$file"
  done
}

echo "Following logs in: $TARGET_DIR"
echo "Tail lines per file: $TAIL_LINES"
echo "Scan interval: ${SCAN_INTERVAL}s"

discover_files

while true; do
  sleep "$SCAN_INTERVAL"
  discover_files
done
