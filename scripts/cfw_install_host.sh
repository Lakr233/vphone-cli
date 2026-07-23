#!/bin/zsh
# cfw_install_host.sh — CFW install by host-mounting the VM's Disk.img.
#
# Attaches the VM's Disk.img on the host and hands the container to the variant
# installer (cfw_install*.sh), which mounts the APFS volumes and places every
# CFW file directly. Then flips the boot snapshot offline
# (tools/apfs_snap_rename.py) so the VM boots the live volume.
#
# Prereqs: VM restored (make restore) and powered off; host has gnu-tar, ipsw,
# aea, ldid, zstd, project venv (make setup_tools). SIP disabled (project
# baseline); NO authenticated-root/ARV change needed.
#
# Usage: cfw_install_host.sh [--variant regular|dev|jb|exp] [vm_dir]
# Runs as root (mount_apfs/chown/cp to owners-honored mounts); re-execs under
# sudo automatically (honors SUDO_ASKPASS for non-interactive use).
set -euo pipefail
SCRIPT_DIR="${0:a:h}"
PROJ="${SCRIPT_DIR:h}"

VARIANT=exp
VM_DIR="$PROJ/vm"
while (( $# )); do
  case "$1" in
    --variant) VARIANT="$2"; shift 2 ;;
    *)         VM_DIR="$1";  shift ;;
  esac
done

case "$VARIANT" in
  regular) INSTALLER=cfw_install.sh ;;
  dev)     INSTALLER=cfw_install_dev.sh ;;
  jb)      INSTALLER=cfw_install_jb.sh ;;
  exp)     INSTALLER=cfw_install_exp.sh ;;
  *) echo "[-] unknown variant: $VARIANT (regular|dev|jb|exp)" >&2; exit 1 ;;
esac

# Re-exec as root; owners-honored mounts + chown/cp require it.
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  exec sudo ${SUDO_ASKPASS:+-A} -E /bin/zsh "$0" --variant "$VARIANT" "$VM_DIR"
fi
unset SUDO_ASKPASS   # already root: host_hdiutil/pre-step use plain sudo/hdiutil

VM_DIR="${VM_DIR:a}"
IMG="$VM_DIR/Disk.img"
[[ -f "$IMG" ]] || { echo "[-] no Disk.img at $IMG" >&2; exit 1; }

# Host-side install toolchain (gnu-tar/ipsw/aea/ldid/zstd + venv python).
P="$PROJ/.tools/bin:$PROJ/.venv/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export PATH="$P"
PY="$PROJ/.venv/bin/python3"

if lsof "$IMG" >/dev/null 2>&1; then
  echo "[-] $IMG is in use — stop the VM first." >&2; exit 1
fi

echo "[*] host-mode CFW install: variant=$VARIANT vm=$VM_DIR"
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

echo "[*] running $INSTALLER (files placed on host mounts)..."
# via env: an expansion-produced ${VAR:+NAME=val} isn't parsed as a shell assignment.
( cd "$VM_DIR" && env CFW_HOST_CONTAINER="$CONT" _VPHONE_PATH="$P" \
    ${SPOOF_BUILD:+SPOOF_BUILD="$SPOOF_BUILD"} \
    ${FORCE_DSC_MAXSLIDE:+FORCE_DSC_MAXSLIDE="$FORCE_DSC_MAXSLIDE"} \
    zsh "$SCRIPT_DIR/$INSTALLER" . )

cleanup
trap - EXIT

echo "[*] flipping boot snapshot offline (com.apple.os.update -> live volume)..."
"$PY" "$PROJ/tools/apfs_snap_rename.py" "$IMG"

# The whole install ran as root (owners-honored mounts / chown / cp). Hand the
# host-side artifacts it created (vm/.vphoned.signed, vm/.cfw_temp, extracted
# cfw_input/cfw_jb_input, the vphoned build) back to the invoking user, so the
# subsequent user-run steps (make boot / setup_machine first boot, which rewrite
# vm/.vphoned.signed) don't hit "Permission denied".
if [[ -n "${SUDO_USER:-}" ]]; then
  chown -R "$SUDO_USER" "$VM_DIR" 2>/dev/null || true
  [[ -e "$PROJ/scripts/vphoned/vphoned" ]] && chown "$SUDO_USER" "$PROJ/scripts/vphoned/vphoned" 2>/dev/null || true
  echo "[*] restored ownership of host-side artifacts to $SUDO_USER"
fi

echo "[+] host-mode CFW install complete. Boot with: make boot"
