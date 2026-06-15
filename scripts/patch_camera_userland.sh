#!/bin/zsh
# patch_camera_userland.sh — Apply the Camera.app accessibility DSC patches.
#
# Mirrors patch_hv_vmm_userland.sh's shape so the EXP install pipeline can
# call into both via a single entry-point style. The actual work happens
# in scripts/patchers/cfw_patch_camera_dsc.py::apply_all_camera_patches,
# invoked through cfw.py's `patch-camera-dsc` subcommand.
#
# Usage:
#   patch_camera_userland.sh dsc <chunks_dir> <dsc_header>
#
# <chunks_dir> is the directory containing dyld_shared_cache_arm64e[.NN]
# files (the mounted SystemOS Cryptex's System/Library/Caches/com.apple.dyld).
# <dsc_header> is the dyld_shared_cache_arm64e file itself (sans suffix),
# used by `ipsw dyld symaddr` for per-build symbol resolution.
#
# Used by: cfw_install_exp.sh

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
  $0 dsc <chunks_dir> <dsc_header>
EOF
    exit 2
}

(( $# >= 1 )) || usage
op="$1"; shift

case "$op" in
    dsc)
        (( $# >= 2 )) || usage
        echo "[*] Patching camera consumers in DSC chunks under: $1"
        echo "[*]   (symbol resolution against: $2)"
        "$PYTHON3" "$SCRIPT_DIR/patchers/cfw.py" patch-camera-dsc "$1" "$2"
        ;;
    *)
        usage
        ;;
esac
