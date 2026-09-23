#!/bin/zsh
# setup_venv.sh — Create a self-contained Python venv at project root.
#
# Creates the venv for scripts/pymobiledevice3_bridge.py, the restore backend.
# Requires: python3.
#
# Usage:
#   make setup_venv
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
VENV_DIR="${PROJECT_ROOT}/.venv"
REQUIREMENTS="${PROJECT_ROOT}/requirements.txt"

# Use system Python3
PYTHON="$(readlink -f "$(which python3)")"
if [[ -z "${PYTHON}" ]]; then
    echo "Error: python3 not found in PATH"
    exit 1
fi

echo "=== Creating venv ==="
echo "  Python:  ${PYTHON} ($(${PYTHON} --version 2>&1))"
echo "  venv:    ${VENV_DIR}"
echo "  deps:    ${REQUIREMENTS}"
echo ""

# Create venv from system Python
"${PYTHON}" -m venv "${VENV_DIR}"

# Activate and install pip packages
source "${VENV_DIR}/bin/activate"
pip install --upgrade pip >/dev/null
pip install -r "${REQUIREMENTS}"

# --- Verify ---
echo ""
echo "=== Verifying imports ==="
python3 -c "
import pymobiledevice3
print('  pmd3      OK')
"

echo ""
echo "=== venv ready ==="
echo "  Activate:   source ${VENV_DIR}/bin/activate"
echo "  Deactivate: deactivate"
