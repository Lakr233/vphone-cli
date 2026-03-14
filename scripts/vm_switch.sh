#!/bin/zsh
# vm_switch.sh — Switch the active VM to a different named backup.
#
# Saves the current VM under its name (from vm/.vm_name), then restores
# the target backup. If the current VM has no name yet, prompts for one.
#
# Usage:
#   make vm_switch NAME=ios18
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
            echo "Usage: $0 --name <target> [--include-ipsw]"
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

if [[ -z "${NAME}" ]]; then
    echo "ERROR: NAME is required (the backup to switch to)."
    echo "  Usage: make vm_switch NAME=ios18"
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

TARGET="${BACKUPS_DIR}/${NAME}"

if [[ ! -d "${TARGET}" || ! -f "${TARGET}/config.plist" ]]; then
    echo "ERROR: Backup '${NAME}' not found."
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

# --- Check for running VM ---
if pgrep -f "vphone-cli.*--config.*${VM_DIR}" >/dev/null 2>&1; then
    echo "ERROR: vphone-cli appears to be running against ${VM_DIR}."
    echo "  Stop the VM before switching."
    exit 1
fi

# --- Determine current VM name ---
CURRENT=""
if [[ -d "${VM_DIR}" && -f "${VM_DIR}/config.plist" ]]; then
    if [[ -f "${VM_DIR}/.vm_name" ]]; then
        CURRENT="$(< "${VM_DIR}/.vm_name")"
    fi

    if [[ -z "${CURRENT}" ]]; then
        echo "Current VM has no name. Give it one to save before switching."
        printf "Name for current VM: "
        read -r CURRENT
        if [[ -z "${CURRENT}" ]]; then
            echo "ERROR: Cannot switch without saving the current VM."
            exit 1
        fi
    fi

    if [[ "${CURRENT}" == "${NAME}" ]]; then
        echo "'${NAME}' is already the active VM."
        exit 0
    fi

    # --- Save current ---
    echo "=== Saving current VM as '${CURRENT}' ==="
    CURRENT_DEST="${BACKUPS_DIR}/${CURRENT}"
    mkdir -p "${CURRENT_DEST}"

    RSYNC_EXCLUDES=()
    if [[ "${BACKUP_INCLUDE_IPSW}" != "1" ]]; then
        RSYNC_EXCLUDES+=(--exclude '*_Restore*/')
    fi

    rsync -aH --sparse --progress --delete \
        "${RSYNC_EXCLUDES[@]}" \
        "${VM_DIR}/" "${CURRENT_DEST}/"

    echo ""
fi

# --- Restore target ---
echo "=== Restoring '${NAME}' ==="

mkdir -p "${VM_DIR}"

rsync -aH --sparse --progress --delete \
    "${TARGET}/" "${VM_DIR}/"

echo "${NAME}" > "${VM_DIR}/.vm_name"

echo ""
echo "=== Switched: ${CURRENT:+${CURRENT} → }${NAME} ==="
echo "Next: make boot"
