#!/bin/zsh
# jb_patch_autotest.sh — run full setup_machine flow for each JB kernel patch method.
# Strategy: apply each single JB kernel method on top of the dev baseline, one case at a time.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "$PROJECT_ROOT"

LOG_ROOT="${PROJECT_ROOT}/setup_logs/jb_patch_tests_$(date +%Y%m%d_%H%M%S)"
SUMMARY_CSV="${LOG_ROOT}/summary.csv"
MASTER_LOG="${LOG_ROOT}/run.log"

mkdir -p "$LOG_ROOT"
touch "$MASTER_LOG"

if [[ -x "${PROJECT_ROOT}/.venv/bin/python3" ]]; then
  PYTHON_BIN="${PROJECT_ROOT}/.venv/bin/python3"
else
  PYTHON_BIN="$(command -v python3)"
fi

PATCH_METHODS=("${(@f)$(
  cd "${PROJECT_ROOT}/scripts" && "$PYTHON_BIN" - <<'PY'
from patchers.kernel_jb import KernelJBPatcher
for method in KernelJBPatcher._PATCH_METHODS:
    print(method)
PY
)}")

if (( ${#PATCH_METHODS[@]} == 0 )); then
  echo "[-] No JB patch methods found" | tee -a "$MASTER_LOG"
  exit 1
fi

echo "index,patch,status,exit_code,log_file" >"$SUMMARY_CSV"
echo "[*] JB patch single-method automation started" | tee -a "$MASTER_LOG"
echo "[*] Logs: $LOG_ROOT" | tee -a "$MASTER_LOG"
echo "[*] Total methods: ${#PATCH_METHODS[@]}" | tee -a "$MASTER_LOG"

idx=0
for patch_method in "${PATCH_METHODS[@]}"; do
  ((idx++))
  case_log="${LOG_ROOT}/$(printf '%02d' "$idx")_${patch_method}.log"

  {
    echo ""
    echo "============================================================"
    echo "[*] [$idx/${#PATCH_METHODS[@]}] Testing PATCH=${patch_method}"
    echo "============================================================"
  } | tee -a "$MASTER_LOG"

  set +e
  # Test matrix assumption: each JB kernel method is validated on top of dev patch baseline.
  SUDO_PASSWORD="${SUDO_PASSWORD:-}" \
  NONE_INTERACTIVE=1 \
  DEV=1 \
  # Default to skipping host setup for long patch sweeps; override SKIP_PROJECT_SETUP=0 if needed.
  SKIP_PROJECT_SETUP="${SKIP_PROJECT_SETUP:-1}" \
  PATCH="$patch_method" \
  make setup_machine >"$case_log" 2>&1
  rc=$?
  set -e

  if (( rc == 0 )); then
    status="PASS"
  else
    status="FAIL"
  fi

  echo "${idx},${patch_method},${status},${rc},${case_log}" >>"$SUMMARY_CSV"
  echo "[*] Result: ${status} (rc=${rc}) log=${case_log}" | tee -a "$MASTER_LOG"
done

echo ""
echo "[*] Completed JB patch automation. Summary: $SUMMARY_CSV" | tee -a "$MASTER_LOG"
