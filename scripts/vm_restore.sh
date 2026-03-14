#!/bin/zsh
# vm_restore.sh — Restore a named backup into the active VM directory.
#
# Usage:
#   make vm_restore NAME=ios17
#   make vm_restore NAME=ios17 FORCE=1
set -euo pipefail

VM_DIR="${VM_DIR:-vm}"
BACKUPS_DIR="${BACKUPS_DIR:-vm.backups}"
NAME="${NAME:-}"
FORCE="${FORCE:-0}"

# --- Parse args ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --name)  NAME="$2"; shift 2 ;;
        --force) FORCE=1; shift ;;
        -h|--help)
            echo "Usage: $0 --name <name> [--force]"
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

if [[ -z "${NAME}" ]]; then
    echo "ERROR: NAME is required."
    echo "  Usage: make vm_restore NAME=ios17"
    echo ""
    echo "Available backups:"
    if [[ -d "${BACKUPS_DIR}" ]]; then
        for d in "${BACKUPS_DIR}"/*/; do
            [[ -f "${d}config.plist" ]] && echo "  - $(basename "${d}")"
        done
    else
        echo "  (none)"
    fi
    exit 1
fi

SRC="${BACKUPS_DIR}/${NAME}"

# --- Validate backup ---
if [[ ! -d "${SRC}" ]]; then
    echo "ERROR: Backup '${NAME}' not found at ${SRC}/"
    echo ""
    echo "Available backups:"
    if [[ -d "${BACKUPS_DIR}" ]]; then
        for d in "${BACKUPS_DIR}"/*/; do
            [[ -f "${d}config.plist" ]] && echo "  - $(basename "${d}")"
        done
    else
        echo "  (none)"
    fi
    exit 1
fi

if [[ ! -f "${SRC}/config.plist" ]]; then
    echo "ERROR: ${SRC}/config.plist not found — backup appears invalid."
    exit 1
fi

# --- Check for running VM ---
if pgrep -f "vphone-cli.*--config.*${VM_DIR}" >/dev/null 2>&1; then
    echo "ERROR: vphone-cli appears to be running against ${VM_DIR}."
    echo "  Stop the VM before restoring."
    exit 1
fi

# --- Confirm overwrite ---
if [[ -d "${VM_DIR}" && -f "${VM_DIR}/Disk.img" && "${FORCE}" != "1" ]]; then
    current=""
    [[ -f "${VM_DIR}/.vm_name" ]] && current="$(< "${VM_DIR}/.vm_name")"
    echo "WARNING: ${VM_DIR}/ already exists${current:+ (current: '${current}')}."
    echo "  This will overwrite it with backup '${NAME}'."
    echo "  Back up first with: make vm_backup NAME=<name>"
    printf "Continue? [y/N] "
    read -r answer
    [[ "${answer}" =~ ^[Yy]$ ]] || exit 1
fi

echo "=== vphone vm_restore ==="
echo "Name   : ${NAME}"
echo "Source : ${SRC}/"
echo "Dest   : ${VM_DIR}/"
backup_size="$(du -sh "${SRC}" 2>/dev/null | cut -f1)"
echo "Size   : ${backup_size} (on disk)"
echo ""

# --- Sync ---
mkdir -p "${VM_DIR}"

rsync -aH --sparse --progress --delete \
    "${SRC}/" "${VM_DIR}/"

# Tag the active VM
echo "${NAME}" > "${VM_DIR}/.vm_name"

echo ""
echo "=== Restored '${NAME}' ==="
echo "Next: make boot"
