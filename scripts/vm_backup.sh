#!/bin/zsh
# vm_backup.sh — Save the current VM as a named backup.
#
# Backups are stored under vm.backups/<name>/ using rsync --sparse.
# The active VM remembers its name in vm/.vm_name for use by vm_switch.
#
# Usage:
#   make vm_backup NAME=ios17
#   make vm_backup NAME=ios18-jb BACKUP_INCLUDE_IPSW=1
set -euo pipefail

VM_DIR="${VM_DIR:-vm}"
BACKUPS_DIR="${BACKUPS_DIR:-vm.backups}"
NAME="${NAME:-}"
BACKUP_INCLUDE_IPSW="${BACKUP_INCLUDE_IPSW:-0}"

# --- Parse args ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --name)          NAME="$2"; shift 2 ;;
        --include-ipsw)  BACKUP_INCLUDE_IPSW=1; shift ;;
        -h|--help)
            echo "Usage: $0 --name <name> [--include-ipsw]"
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

if [[ -z "${NAME}" ]]; then
    echo "ERROR: NAME is required."
    echo "  Usage: make vm_backup NAME=ios17"
    exit 1
fi

# Reject names with slashes or dots to keep the backups dir clean
if [[ "${NAME}" == */* || "${NAME}" == .* ]]; then
    echo "ERROR: NAME must be a simple identifier (no slashes or leading dots)."
    exit 1
fi

# --- Validate source ---
if [[ ! -d "${VM_DIR}" ]]; then
    echo "ERROR: VM directory not found: ${VM_DIR}"
    exit 1
fi

if [[ ! -f "${VM_DIR}/config.plist" ]]; then
    echo "ERROR: ${VM_DIR}/config.plist not found — is this a valid VM directory?"
    exit 1
fi

# --- Check for running VM ---
if pgrep -f "vphone-cli.*--config.*${VM_DIR}" >/dev/null 2>&1; then
    echo "WARNING: vphone-cli appears to be running against ${VM_DIR}."
    echo "  Backing up a live VM may produce an inconsistent snapshot."
    printf "Continue anyway? [y/N] "
    read -r answer
    [[ "${answer}" =~ ^[Yy]$ ]] || exit 1
fi

DEST="${BACKUPS_DIR}/${NAME}"

echo "=== vphone vm_backup ==="
echo "Name   : ${NAME}"
echo "Source : ${VM_DIR}/"
echo "Dest   : ${DEST}/"
src_size="$(du -sh "${VM_DIR}" 2>/dev/null | cut -f1)"
echo "Size   : ${src_size} (on disk)"

RSYNC_EXCLUDES=()
if [[ "${BACKUP_INCLUDE_IPSW}" != "1" ]]; then
    RSYNC_EXCLUDES+=(--exclude '*_Restore*/')
    echo "IPSW   : excluded (use BACKUP_INCLUDE_IPSW=1 to include)"
fi
echo ""

# --- Sync ---
mkdir -p "${DEST}"

rsync -aH --sparse --progress --delete \
    "${RSYNC_EXCLUDES[@]}" \
    "${VM_DIR}/" "${DEST}/"

# Tag the active VM with this name
echo "${NAME}" > "${VM_DIR}/.vm_name"

echo ""
echo "=== Saved as '${NAME}' ==="
backup_size="$(du -sh "${DEST}" 2>/dev/null | cut -f1)"
echo "Backup size : ${backup_size}"
echo ""
echo "To restore : make vm_restore NAME=${NAME}"
echo "To switch  : make vm_switch NAME=${NAME}"
echo "List all   : make vm_list"
