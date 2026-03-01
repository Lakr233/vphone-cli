#!/bin/bash
# setup_venv_linux.sh — Create Python venv on Linux (Debian/Ubuntu).
#
# On Linux, keystone-engine pip package ships prebuilt .so — no manual build needed.
#
# Usage:
#   bash scripts/setup_venv_linux.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
VENV_DIR="${PROJECT_ROOT}/.venv"
REQUIREMENTS="${PROJECT_ROOT}/requirements.txt"

echo "=== Installing system deps ==="
if command -v apt-get &>/dev/null; then
  apt-get update -qq
  apt-get install -y -qq python3 python3-venv python3-pip cmake gcc g++ pkg-config 2>/dev/null
elif command -v dnf &>/dev/null; then
  dnf install -y python3 python3-pip cmake gcc gcc-c++ 2>/dev/null
fi

PYTHON="$(command -v python3)"
if [[ -z "${PYTHON}" ]]; then
  echo "Error: python3 not found in PATH"
  exit 1
fi

echo ""
echo "=== Creating venv ==="
echo "  Python:  ${PYTHON} ($(${PYTHON} --version 2>&1))"
echo "  venv:    ${VENV_DIR}"
echo "  deps:    ${REQUIREMENTS}"
echo ""

"${PYTHON}" -m venv "${VENV_DIR}"

source "${VENV_DIR}/bin/activate"
pip install --upgrade pip > /dev/null
pip install -r "${REQUIREMENTS}"

# --- Verify ---
echo ""
echo "=== Verifying imports ==="
python3 -c "
from capstone import Cs, CS_ARCH_ARM64, CS_MODE_LITTLE_ENDIAN
from keystone import Ks, KS_ARCH_ARM64, KS_MODE_LITTLE_ENDIAN
from pyimg4 import IM4P
print('  capstone  OK')
print('  keystone  OK')
print('  pyimg4    OK')
"

echo ""
echo "=== venv ready ==="
echo "  Activate:   source ${VENV_DIR}/bin/activate"
echo "  Deactivate: deactivate"
