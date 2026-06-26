#!/bin/zsh
# vm_switch.sh — Switch the active VM to a different named backup.
#
# Saves the current VM under its name (from vm/.vm_name), then restores
# the target backup. If the current VM has no name yet, prompts for one.
#
# Usage:
#   make vm_switch NAME=ios18
#   make vm_switch NAME=ios18 BACKUP_INCLUDE_IPSW=1

set -euo pipefail

# Try cp -c for APFS clone/COW first; fall back to cp -a where -c is unsupported.
_vphone_cp() {
    cp -a -c "$@" 2>/dev/null || cp -a "$@"
}

VM_DIR="${VM_DIR:-vm}"
BACKUPS_DIR="${BACKUPS_DIR:-vm.backups}"
NAME="${NAME:-}"
BACKUP_INCLUDE_IPSW="${BACKUP_INCLUDE_IPSW:-0}"

validate_backup_name() {
    local name="$1"
    local label="${2:-NAME}"

    if [[ -z "${name}" ]]; then
        echo "ERROR: ${label} is required."
        exit 1
    fi

    if [[ "${name}" == */* || "${name}" == .* ]]; then
        echo "ERROR: ${label} must be a simple identifier (no slashes or leading dots)."
        exit 1
    fi
}

validate_safe_path() {
    local path="$1"
    local label="$2"

    if [[ -z "${path}" || "${path}" == "/" || "${path}" == "." || "${path}" == ".." ]]; then
        echo "ERROR: Refusing unsafe ${label}: '${path}'"
        exit 1
    fi
}

list_backups() {
    if [[ ! -d "${BACKUPS_DIR}" ]]; then
        echo "  (none)"
        return
    fi

    local found=0

    while IFS= read -r -d '' d; do
        if [[ -f "${d}/config.plist" ]]; then
            echo "  - $(basename "${d}")"
            found=1
        fi
    done < <(find "${BACKUPS_DIR}" -mindepth 1 -maxdepth 1 -type d -print0)

    if [[ "${found}" != "1" ]]; then
        echo "  (none)"
    fi
}

copy_children() {
    local src="$1"
    local dst="$2"
    local include_ipsw="${3:-1}"

    mkdir -p "${dst}"

    while IFS= read -r -d '' item; do
        base="$(basename "${item}")"

        if [[ "${include_ipsw}" != "1" && "${base}" == *_Restore* ]]; then
            continue
        fi

        _vphone_cp "${item}" "${dst}/"
    done < <(find "${src}" -mindepth 1 -maxdepth 1 \( -type f -o -type d -o -type l \) -print0)
}

replace_dir_with_tmp() {
    local tmp="$1"
    local dest="$2"
    local old="${dest}.old.$$"

    rm -rf -- "${old}"

    if [[ -e "${dest}" || -L "${dest}" ]]; then
        mv -- "${dest}" "${old}"
    fi

    if ! mv -- "${tmp}" "${dest}"; then
        if [[ -e "${old}" || -L "${old}" ]]; then
            mv -- "${old}" "${dest}"
        fi
        echo "ERROR: Failed to replace ${dest}"
        exit 1
    fi

    rm -rf -- "${old}"
}

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
    list_backups
    exit 1
fi

validate_backup_name "${NAME}"
validate_safe_path "${VM_DIR}" "VM_DIR"
validate_safe_path "${BACKUPS_DIR}" "BACKUPS_DIR"

TARGET="${BACKUPS_DIR}/${NAME}"

if [[ ! -d "${TARGET}" || ! -f "${TARGET}/config.plist" ]]; then
    echo "ERROR: Backup '${NAME}' not found."
    echo ""
    echo "Available backups:"
    list_backups
    exit 1
fi

# --- Check for running VM ---
if pgrep -f "vphone-cli.*--config.*${VM_DIR}" >/dev/null 2>&1; then
    echo "ERROR: vphone-cli appears to be running against ${VM_DIR}."
    echo "  Stop the VM before switching."
    exit 1
fi

mkdir -p "${BACKUPS_DIR}"

# --- Determine current VM name ---
CURRENT=""
if [[ -d "${VM_DIR}" && -f "${VM_DIR}/config.plist" ]]; then
    if [[ -f "${VM_DIR}/.vm_name" ]]; then
        CURRENT="$(< "${VM_DIR}/.vm_name")"
    fi

    if [[ -z "${CURRENT}" ]]; then
        echo "Current VM has no name. Give it one to save before switching."
        printf "Name for current VM: "
        read -r CURRENT || CURRENT=""

        if [[ -z "${CURRENT}" ]]; then
            echo "ERROR: Cannot switch without saving the current VM."
            exit 1
        fi
    fi

    validate_backup_name "${CURRENT}" "Current VM name"

    if [[ "${CURRENT}" == "${NAME}" ]]; then
        echo "'${NAME}' is already the active VM."
        exit 0
    fi

    echo "=== Saving current VM as '${CURRENT}' ==="

    CURRENT_DEST="${BACKUPS_DIR}/${CURRENT}"
    TMP_CURRENT_DEST="${BACKUPS_DIR}/.${CURRENT}.tmp.$$"

    rm -rf -- "${TMP_CURRENT_DEST}"
    mkdir -p "${TMP_CURRENT_DEST}"

    copy_children "${VM_DIR}" "${TMP_CURRENT_DEST}" "${BACKUP_INCLUDE_IPSW}"
    echo "${CURRENT}" > "${TMP_CURRENT_DEST}/.vm_name"

    replace_dir_with_tmp "${TMP_CURRENT_DEST}" "${CURRENT_DEST}"

    echo ""
fi

# --- Restore target ---
echo "=== Restoring '${NAME}' ==="

TMP_VM_DIR="${VM_DIR}.restore.$$"

rm -rf -- "${TMP_VM_DIR}"
mkdir -p "${TMP_VM_DIR}"

copy_children "${TARGET}" "${TMP_VM_DIR}" "1"
echo "${NAME}" > "${TMP_VM_DIR}/.vm_name"

replace_dir_with_tmp "${TMP_VM_DIR}" "${VM_DIR}"

echo ""
echo "=== Switched: ${CURRENT:+${CURRENT} → }${NAME} ==="
echo "Next: make boot"
