#!/bin/zsh
# vphone-tier: dist
# patch_hv_vmm_userland.sh — Apply the user-mode hv_vmm_present patch.
#
# Two operations, chosen by the first arg:
#
#   dsc <chunks_dir>
#       Patch the canonical sysctlbyname("kern.hv_vmm_present", ...) sites
#       inside the DSC chunks at <chunks_dir>. <chunks_dir> is the directory
#       holding `dyld_shared_cache_arm64e[.NN]` files, typically the
#       mounted SystemOS Cryptex's `System/Library/Caches/com.apple.dyld/`.
#       Skips the compute/accel dylibs (CoreML, Espresso, ANE, CoreRE,
#       RenderBox, WebGPU, caulk, IOSurfaceAccelerator).
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
# This script is a thin wrapper around `vphone-cli cfw`. It exists so
# cfw_install_dev.sh and cfw_install_jb.sh can call a single entry point
# without duplicating the binary-resolution logic.
#
# Used by: cfw_install_dev.sh, cfw_install_jb.sh

set -euo pipefail

SCRIPT_DIR="${0:a:h}"

[[ -n "${_VPHONE_PATH:-}" ]] && export PATH="$_VPHONE_PATH"

# ── vphone-cli resolver — both patchers live in it ─
# Same order as scripts/cfw_install_host.sh: VPHONE_CLI_BIN when a vphone-cli
# subcommand invoked us, otherwise a dev tree or the .app, where scripts/ sits
# in Contents/Resources and the binaries are one level up in MacOS.
VPHONE_CLI="${VPHONE_CLI_BIN:-}"
if [[ -z "$VPHONE_CLI" ]]; then
    for candidate in "${SCRIPT_DIR:h}/.build/release/vphone-cli" "${SCRIPT_DIR:h:h}/MacOS/vphone-cli"; do
        [[ -x "$candidate" ]] && { VPHONE_CLI="$candidate"; break }
    done
fi
[[ -x "$VPHONE_CLI" ]] || {
    echo "[-] cannot find vphone-cli (the hv_vmm patchers live in it) — run 'make build'" >&2
    exit 1
}

usage() {
    cat <<EOF >&2
Usage:
  $0 dsc <chunks_dir>
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
        "$VPHONE_CLI" cfw patch-hv-vmm-dsc "$1"
        ;;
    # `standalone <binary>` used to live here and called
    # `patch-hv-vmm`, which no longer exists: that subcommand and its backing
    # patcher (cfw_patch_hv_vmm_rootfs.py) were removed, so the op had been
    # falling through the unknown-command branch and exiting 1. It is
    # deleted rather than retargeted because nothing in the repo invokes it and
    # there is no honest substitute — `patch-hv-vmm-dsc` takes a directory of
    # DSC chunks, not a Mach-O, and `patch-watchdogd` is specific to
    # watchdogd's cached byte. EXP now covers user-mode hv_vmm_present with
    # `dsc` (every consumer inside the shared cache) plus `watchdogd` (the one
    # standalone binary still holding its own copy).
    watchdogd)
        (( $# >= 1 )) || usage
        echo "[*] Patching watchdogd hv_vmm_present cache in: $1"
        "$VPHONE_CLI" cfw patch-watchdogd "$1"
        ;;
    *)
        usage
        ;;
esac
