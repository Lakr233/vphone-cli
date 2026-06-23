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

# --- Install keystone native library ---
# The keystone-engine pip package is Python bindings only.
# It needs libkeystone.dylib at runtime. Homebrew may ship either a dylib
# or an older static archive, so place a loadable dylib inside the venv.
echo ""
echo "=== Installing keystone dylib ==="
KEYSTONE_PREFIX="$(brew --prefix keystone 2>/dev/null || true)"
if [[ -z "${KEYSTONE_PREFIX}" || ! -d "${KEYSTONE_PREFIX}" ]]; then
    echo "Error: keystone not found. Install with: brew install keystone"
    exit 1
fi

KEYSTONE_DYLIB="$(find -L "${KEYSTONE_PREFIX}/lib" -name 'libkeystone*.dylib' -type f 2>/dev/null | head -1)"
KEYSTONE_STATIC="$(find -L "${KEYSTONE_PREFIX}" -name 'libkeystone.a' -type f 2>/dev/null | head -1)"

PYVER="$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
KS_PKG_DIR="${VENV_DIR}/lib/python${PYVER}/site-packages/keystone"
KS_DYLIB="${KS_PKG_DIR}/libkeystone.dylib"

mkdir -p "${KS_PKG_DIR}"
echo "  dylib dest: ${KS_DYLIB}"

if [[ -n "${KEYSTONE_DYLIB}" ]]; then
    echo "  source dylib: ${KEYSTONE_DYLIB}"
    cp "${KEYSTONE_DYLIB}" "${KS_DYLIB}"
    chmod u+w "${KS_DYLIB}"
elif [[ -n "${KEYSTONE_STATIC}" ]]; then
    echo "  static lib: ${KEYSTONE_STATIC}"
    clang -shared -o "${KS_DYLIB}" \
        -Wl,-all_load "${KEYSTONE_STATIC}" \
        -lc++ \
        -install_name @rpath/libkeystone.dylib
else
    echo "Error: libkeystone.dylib or libkeystone.a not found under ${KEYSTONE_PREFIX}"
    echo "Install or repair with: brew reinstall keystone"
    exit 1
fi

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
