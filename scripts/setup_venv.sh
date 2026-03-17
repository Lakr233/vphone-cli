#!/bin/zsh
# setup_venv.sh — Create a self-contained Python venv at project root.
#
# Installs all dependencies including the keystone native library.
# Requires: python3, clang, Homebrew keystone (brew install keystone)
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
PYTHON="$(command -v python3)"
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

# --- Build keystone native library ---
# The keystone-engine pip package is Python bindings only.
# It needs libkeystone.dylib at runtime. Homebrew ships only the static .a,
# so we build a dylib from it and place it inside the venv.
echo ""
echo "=== Building keystone dylib ==="
KEYSTONE_DIR="/opt/homebrew/Cellar/keystone"
if [[ ! -d "${KEYSTONE_DIR}" ]]; then
    echo "Error: keystone not found. Install with: brew install keystone"
    exit 1
fi
KEYSTONE_STATIC="$(find "${KEYSTONE_DIR}" -name 'libkeystone.a' -type f 2>/dev/null | head -1)"
if [[ -z "${KEYSTONE_STATIC}" ]]; then
    echo "Error: libkeystone.a not found. Install with: brew install keystone"
    exit 1
fi

PYVER="$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
KS_PKG_DIR="${VENV_DIR}/lib/python${PYVER}/site-packages/keystone"
KS_DYLIB="${KS_PKG_DIR}/libkeystone.dylib"

echo "  static lib: ${KEYSTONE_STATIC}"
echo "  dylib dest: ${KS_DYLIB}"

clang -shared -o "${KS_DYLIB}" \
    -Wl,-all_load "${KEYSTONE_STATIC}" \
    -lc++ \
    -install_name @rpath/libkeystone.dylib

echo "  dylib built OK"

# --- Verify ---
echo ""
echo "=== Verifying imports ==="
python3 -c "
from capstone import Cs, CS_ARCH_ARM64, CS_MODE_LITTLE_ENDIAN
from keystone import Ks, KS_ARCH_ARM64, KS_MODE_LITTLE_ENDIAN
from pyimg4 import IM4P
import pymobiledevice3
print('  capstone  OK')
print('  keystone  OK')
print('  pyimg4    OK')
print('  pmd3      OK')
"

echo ""
echo "=== venv ready ==="
echo "  Activate:   source ${VENV_DIR}/bin/activate"
echo "  Deactivate: deactivate"
