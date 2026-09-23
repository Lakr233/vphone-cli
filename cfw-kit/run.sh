#!/bin/zsh
# vphone-tier: build
#
# BUILD, not dist, and that is a decision rather than an oversight: cfw-kit is
# vendored as-is from an external tree and still reaches for ldid, gnu-tar, zstd
# and ipsw the way scripts/cfw_install*.sh did before they were cleaned out. It
# does not ship in the .app, so none of that reaches a user — but it also means
# a dist user cannot run this variant installer. Whether cfw-kit becomes a dist
# path (by getting the same treatment the cfw_install*.sh family got) or stays a
# development tool is a P3 question, deliberately left open. Until it is
# answered, do not add it to scripts/dist_manifest.sh.
#
# run.sh — host driver for the custom-firmware-kit variant installers.
#
# Attaches the VM's Disk.img on the host, hands the APFS container to the
# variant installer (vanilla/ or jb/), then flips the boot snapshot offline so
# the VM boots the live volume.
#
# Derived from vphone-cli's scripts/cfw_install_host.sh. Everything to do with
# root, attach and the snapshot flip is kept verbatim — those are the parts
# that are easy to get subtly wrong and impossible to notice until a guest
# fails to boot. Upstream at the time of derivation:
#   scripts/cfw_install_host.sh
#     sha256 6c84d50b65c37404ca6ab423b6d22b5a69aba27d063da37d7ae0fc682175aa78
#   vphone-cli HEAD 6d5ce7d49b4574859c57c66dff26c5c02bcae6ba (2026-09-23)
# If upstream's hash has moved, diff it before trusting this script.
#
# Prereqs: VM restored and POWERED OFF; for the jb variant the boot chain must
# already carry the 127 JB patches (`make fw_patch_jb`). Host needs gnu-tar,
# zstd, ipsw, aea, ldid (`make setup_tools`) and a built vphone-cli
# (`make build`) — every CFW patcher the kit calls lives in that binary.
#
# Usage:
#   ./run.sh --variant vanilla|jb [--repo <vphone-cli>] [vm_dir]
#
#   JB_USERLAND=rootless|roothide|none   jb only; default none (empty slot)
#   VANILLA_LSD_EMBEDDED_REG=1           vanilla only; opens lsd's JB app
#                                        registration path on a 27 base
#   FORCE_DSC_MAXSLIDE=1                 force maxSlide=0 on non-27 bases
#   KIT_CHECK_ONLY=1                     preflight only; never attaches the image
#   VPHONE_KEEP_ARTIFACTS=1              keep the extracted cfw_input/ (default: kept)
set -euo pipefail

KIT_DIR="${0:a:h}"

VARIANT=""
VM_DIR=""
REPO_ARG="${VPHONE_REPO:-}"

usage() {
    /bin/cat >&2 <<'USAGE'
usage: run.sh --variant vanilla|jb [--repo <vphone-cli checkout>] [vm_dir]

  vanilla   minimal boot: Cryptex, dyld links, display/boot fixes, seputil,
            GPU bundle, activation bypass. No daemons, no SSH, no jailbreak.
  jb        the above plus the filesystem-layer jailbreak work. Userland slot
            is empty unless JB_USERLAND names a flavour.
USAGE
    exit 2
}

while (( $# )); do
  case "$1" in
    --variant) [[ $# -ge 2 ]] || usage; VARIANT="$2"; shift 2 ;;
    --repo)    [[ $# -ge 2 ]] || usage; REPO_ARG="$2";  shift 2 ;;
    -h|--help) usage ;;
    -*)        echo "[-] unknown option: $1" >&2; usage ;;
    *)         VM_DIR="$1"; shift ;;
  esac
done

# No default variant. Upstream defaults to `exp`; defaulting to either of ours
# would silently give someone a firmware they did not ask for.
[[ -n "$VARIANT" ]] || { echo "[-] --variant is required (vanilla|jb)" >&2; usage; }
case "$VARIANT" in
  vanilla|jb) ;;
  *) echo "[-] unknown variant: $VARIANT (vanilla|jb)" >&2; exit 1 ;;
esac

INSTALLER="$KIT_DIR/$VARIANT/install.sh"
[[ -f "$INSTALLER" ]] || { echo "[-] missing installer: $INSTALLER" >&2; exit 1; }

# resolve_repo/die live in the shared lib; don't duplicate the search order.
source "$KIT_DIR/lib/common.sh"
export VPHONE_REPO="$REPO_ARG"
REPO_DIR="$(resolve_repo)"      # die() inside -> non-zero -> errexit aborts here
PROJ="$REPO_DIR"

[[ -n "$VM_DIR" ]] || VM_DIR="$PROJ/vm"
VM_DIR="${VM_DIR:a}"

# Host-side install toolchain (gnu-tar/ipsw/aea/ldid/zstd). No python entry:
# the installers call `vphone-cli cfw <verb>` for every patch, and nothing they
# run comes out of the venv.
P="$PROJ/.tools/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export PATH="$P"

# Variables the installers read, forwarded explicitly. An expansion-produced
# ${VAR:+NAME=val} is not parsed as a shell assignment, hence `env`.
kit_env=(
    CFW_HOST_CONTAINER="__unset__"
    _VPHONE_PATH="$P"
    VPHONE_REPO="$PROJ"
    ${VPHONE_CLI_BIN:+VPHONE_CLI_BIN="$VPHONE_CLI_BIN"}
    ${JB_USERLAND:+JB_USERLAND="$JB_USERLAND"}
    ${VANILLA_LSD_EMBEDDED_REG:+VANILLA_LSD_EMBEDDED_REG="$VANILLA_LSD_EMBEDDED_REG"}
    ${FORCE_DSC_MAXSLIDE:+FORCE_DSC_MAXSLIDE="$FORCE_DSC_MAXSLIDE"}
)

# ── check-only: never touch the image, never ask for root ───────
# Deliberately placed BEFORE the sudo re-exec. The installers stop right after
# preflight — before find_restore_dir and before the first mount — so nothing
# here needs privileges, and a preflight that prompts for a password is a
# preflight nobody runs. The container sentinel only has to satisfy
# init_paths' :? guard; nothing dereferences it on this path.
if [[ "${KIT_CHECK_ONLY:-0}" == "1" ]]; then
  echo "[*] check-only: $VARIANT preflight only — no root, no attach, no writes"
  [[ -d "$VM_DIR" ]] || { echo "[!] $VM_DIR does not exist; using it as a label only" >&2; VM_DIR="$PWD"; }
  ( cd "$VM_DIR" && env "${kit_env[@]}" KIT_CHECK_ONLY=1 zsh "$INSTALLER" . )
  echo "[+] check-only passed for variant=$VARIANT"
  exit 0
fi

# Re-exec as root; owners-honored mounts + chown/cp require it.
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  exec sudo ${SUDO_ASKPASS:+-A} -E /bin/zsh "$0" \
      --variant "$VARIANT" --repo "$PROJ" "$VM_DIR"
fi
unset SUDO_ASKPASS   # already root: host_hdiutil/pre-step use plain sudo/hdiutil

IMG="$VM_DIR/Disk.img"
[[ -f "$IMG" ]] || { echo "[-] no Disk.img at $IMG" >&2; exit 1; }

if lsof "$IMG" >/dev/null 2>&1; then
  echo "[-] $IMG is in use — stop the VM first." >&2; exit 1
fi

echo "[*] custom-firmware-kit: variant=$VARIANT vm=$VM_DIR"
echo "[*] repo=$PROJ"
AO=$(hdiutil attach -nomount -imagekey diskimage-class=CRawDiskImage "$IMG" 2>/dev/null)
BASEDISK=$(awk 'NR == 1 { print $1; exit }' <<< "$AO")
CONT=$(diskutil info -plist "${BASEDISK}s1" | /usr/bin/plutil -extract APFSContainerReference raw -o - - 2>/dev/null || true)
SYS=$(diskutil apfs list "$CONT" 2>/dev/null | awk '/APFS Volume Disk \(Role\):/{for(i=1;i<=NF;i++) if($i ~ /^disk[0-9]+s[0-9]+$/) dev=$i} /Name:.*System \(Case-sensitive\)/{print dev; exit}')
[[ -n "$CONT" && -n "$SYS" ]] || { echo "[-] System volume not found in $IMG" >&2; hdiutil detach "$BASEDISK" 2>/dev/null; exit 1; }
echo "[*] attached: container=$CONT system=$SYS"

cleanup() {
  for m in /private/tmp/cfwhost/mnt1 /private/tmp/cfwhost/mnt3 /private/tmp/cfwhost/mnt5; do
    umount "$m" 2>/dev/null || true
  done
  hdiutil detach "$BASEDISK" 2>/dev/null || diskutil eject "$BASEDISK" 2>/dev/null || true
}
trap cleanup EXIT

kit_env[1]="CFW_HOST_CONTAINER=$CONT"

echo "[*] running $VARIANT/install.sh (files placed on host mounts)..."
( cd "$VM_DIR" && env "${kit_env[@]}" zsh "$INSTALLER" . )

cleanup
trap - EXIT

echo "[*] flipping boot snapshot offline (com.apple.os.update -> live volume)..."
# Was `python3 tools/apfs_snap_rename.py`. Same resolver the installers use for
# the CFW patchers (lib/common.sh), so there is one search order in the kit.
VPHONE_CLI="$(resolve_vphone_cli)"
[[ -x "$VPHONE_CLI" ]] || { echo "[-] cannot find vphone-cli — snapshot NOT flipped; the VM will boot the stock snapshot." >&2; exit 1; }
"$VPHONE_CLI" cfw flip-snapshot "$IMG"

# Upstream removes the extracted cfw_input/ here for `make` idempotence. The kit
# keeps it: re-running a variant is the normal case while designing a userland,
# and re-extracting 7 MB every time is pure waste. Opt in to the cleanup.
if [[ "${VPHONE_DROP_ARTIFACTS:-0}" == "1" ]]; then
  rm -rf "${VM_DIR:?}/cfw_input"
fi

# The whole install ran as root. Hand the host-side artifacts back to the
# invoking user so subsequent user-run steps (make boot) don't hit EPERM.
if [[ -n "${SUDO_USER:-}" ]]; then
  chown -R "$SUDO_USER" "$VM_DIR" 2>/dev/null || true
  echo "[*] restored ownership of host-side artifacts to $SUDO_USER"
fi

echo "[+] $VARIANT install complete. Boot with: make boot"
