#!/bin/zsh
# patch_hv_vmm_userland.sh — Apply the user-mode hv_vmm_present patch.
#
# Three operations, chosen by the first arg:
#
#   dsc <chunks_dir>
#       Patch the canonical sysctlbyname("kern.hv_vmm_present", ...) sites
#       inside the DSC chunks at <chunks_dir>. <chunks_dir> is the directory
#       holding `dyld_shared_cache_arm64e[.NN]` files, typically the
#       mounted SystemOS Cryptex's `System/Library/Caches/com.apple.dyld/`.
#       Skips the compute/accel dylibs (CoreML, Espresso, ANE, CoreRE,
#       RenderBox, WebGPU, caulk, IOSurfaceAccelerator).
#
#   standalone <binary>
#       Patch a single standalone Mach-O file in place. Idempotent.
#       Caller is responsible for re-signing (ldid).
#
#   watchdogd <binary>
#       Surgical 2-instruction patch of /usr/libexec/watchdogd that
#       forces its cached "am I a VM?" byte to 1 regardless of the
#       sysctl result. Also re-attests the affected CodeDirectory slot
#       hash (the binary stays self-consistent for TXM/SHA-256). Do NOT
#       re-sign with ldid — the patcher leaves the original Apple-issued
#       code-signing identifier intact, which launchd boot-task identity
#       checks require.
#
# This script is a thin wrapper around `scripts/patchers/cfw.py`. It
# exists so cfw_install_dev.sh and cfw_install_jb.sh can call a single
# entry point without duplicating Python venv/python3 resolution logic.
#
# Used by: cfw_install_dev.sh, cfw_install_jb.sh

set -euo pipefail

SCRIPT_DIR="${0:a:h}"

[[ -n "${_VPHONE_PATH:-}" ]] && export PATH="$_VPHONE_PATH"

_resolve_python3() {
    local venv_py="${SCRIPT_DIR:h}/.venv/bin/python3"
    if [[ -x "$venv_py" ]]; then
        echo "$venv_py"
    else
        command -v python3 || true
    fi
}
PYTHON3="$(_resolve_python3)"

usage() {
    cat <<EOF >&2
Usage:
  $0 dsc <chunks_dir>
  $0 standalone <binary>
  $0 watchdogd <binary>
EOF
    exit 2
}

(( $# >= 1 )) || usage
op="$1"; shift

case "$op" in
    dsc)
        (( $# >= 1 )) || usage
        echo "[*] Patching hv_vmm_present consumers in DSC chunks under: $1"
        "$PYTHON3" "$SCRIPT_DIR/patchers/cfw.py" patch-hv-vmm-dsc "$1"
        ;;
    standalone)
        (( $# >= 1 )) || usage
        echo "[*] Patching hv_vmm_present consumers in: $1"
        "$PYTHON3" "$SCRIPT_DIR/patchers/cfw.py" patch-hv-vmm "$1"
        ;;
    watchdogd)
        (( $# >= 1 )) || usage
        echo "[*] Patching watchdogd hv_vmm_present cache in: $1"
        "$PYTHON3" "$SCRIPT_DIR/patchers/cfw.py" patch-watchdogd "$1"
        ;;
    *)
        usage
        ;;
esac
