#!/bin/zsh
# vanilla/install.sh — the smallest CFW that boots.
#
# Installs nothing you did not ask for: no SSH, no VNC, no RPC server, no
# iosbinpack64, no vphoned, no LaunchDaemon injection, no jailbreak. The guest
# boots to SpringBoard with working graphics, and that is the whole contract.
# Everything else is yours to design.
#
# Installed, and why none of it is optional:
#   Cryptex SystemOS + AppOS    the hybrid firmware has no userland without it
#   dyld symlinks               dyld cannot find the shared cache otherwise
#   version-gated display fixes black screen (IOMFB) / pid-1 panic (27.x) without
#   seputil gigalocker UUID     SEP rejects the volume otherwise
#   diskimagesiod (27 only)     MobileStorageMounter hangs forever otherwise
#   AppleParavirtGPU bundle     backboardd crash loop / black SpringBoard without
#   mobileactivationd bypass    stuck on the activation screen otherwise
#
# Deliberately NOT installed (upstream cfw_install.sh does all of these):
#   iosbinpack64                 jailbreak tool pack — bash/dropbear/SSH live here
#   launchd_cache_loader patch   its ONLY purpose is to allow a MODIFIED
#                                launchd.plist. We never modify it, so stock cache
#                                validation passes untouched and the patch is moot.
#   launchd.plist injection      no daemons -> nothing to inject
#   vphoned                      host<->guest control daemon; not needed to boot
#   bash / dropbear / trollvnc / rpcserver_ios plists
#
# Usage: ../run.sh --variant vanilla [vm_dir]
# Contract: root, VM off, CFW_HOST_CONTAINER set, $1 = VM dir.
set -euo pipefail

KIT_DIR="${0:a:h:h}"
source "$KIT_DIR/lib/common.sh"
source "$KIT_DIR/lib/base_stages.sh"

VM_DIR="$(cd "${1:-.}" && pwd)"
CFW_INPUT="cfw_input"
CFW_ARCHIVE="cfw_input.tar.zst"
TEMP_DIR="$VM_DIR/.cfw_temp"

# The lsd embedded-registration gate is the one iOS-27 DSC patch upstream
# applies that has no effect without a jailbreak tool to use it (see
# lib/base_stages.sh). Off here. Turn it on only if you add your own app
# registration tool to a 27 guest.
#
# Note this is NOT the diskimagesiod DDI patch — that one is applied
# unconditionally on 27, because upstream's regular variant applies it too and
# without it MobileStorageMounter hangs.
VANILLA_LSD_EMBEDDED_REG="${VANILLA_LSD_EMBEDDED_REG:-0}"
FORCE_DSC_MAXSLIDE="${FORCE_DSC_MAXSLIDE:-0}"

REQUIRED_CFW_SUBCOMMANDS=(
    cryptex-paths
    patch-seputil
    patch-mobileactivationd
    patch-iomfb-swapend
    patch-iomfb-force-kern
    patch-dsc-maxslide
    patch-xpc-lwcr
    patch-lockdown-mode
    patch-diskimagesiod
)
[[ "$VANILLA_LSD_EMBEDDED_REG" == "1" ]] && REQUIRED_CFW_SUBCOMMANDS+=(patch-lsd-embedded-reg)

REPO_DIR="$(resolve_repo)"
PYTHON3="$(resolve_python3)"
init_paths

cleanup_on_exit() {
    safe_detach "$TEMP_DIR/mnt_sysos" 2>/dev/null || true
    safe_detach "$TEMP_DIR/mnt_appos" 2>/dev/null || true
}
trap cleanup_on_exit EXIT

echo "[*] custom-firmware-kit — variant: vanilla (minimal boot)"
echo "[+] repo: $REPO_DIR"
echo "[+] vm:   $VM_DIR"

preflight
[[ "${KIT_CHECK_ONLY:-0}" == "1" ]] && { echo "[+] check-only: stopping before any write"; exit 0; }

RESTORE_DIR=$(find_restore_dir)
echo "[+] Restore directory: $RESTORE_DIR"

setup_cfw_input
INPUT_DIR="$VM_DIR/$CFW_INPUT"
echo "[+] Input resources: $INPUT_DIR"
require_signing_tools

mkdir -p "$TEMP_DIR"

echo ""
echo "[*] Parsing iPhone BuildManifest for Cryptex paths..."
CRYPTEX_PATHS=$(cfw_py cryptex-paths "$RESTORE_DIR/iPhone-BuildManifest.plist")
CRYPTEX_SYSOS=$(echo "$CRYPTEX_PATHS" | head -1)
CRYPTEX_APPOS=$(echo "$CRYPTEX_PATHS" | tail -1)
echo "  SystemOS: $CRYPTEX_SYSOS"
echo "  AppOS:    $CRYPTEX_APPOS"

stage_cryptex
detect_ios_version
stage_display_and_boot_fixes "$VANILLA_LSD_EMBEDDED_REG"
stage_seputil
stage_gpu
stage_mobileactivationd
stage_unmount

echo ""
echo "[+] vanilla CFW installation complete."
echo "    No daemons, no SSH, no jailbreak were installed — by design."
