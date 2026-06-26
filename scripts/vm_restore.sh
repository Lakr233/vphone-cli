#!/bin/zsh
# vm_restore.sh — Restore a named backup into the active VM directory.
#
# Usage:
#   make vm_restore NAME=ios17
#   make vm_restore NAME=ios17 FORCE=1

set -euo pipefail

# Try cp -c for APFS clone/COW first; fall back to cp -a where -c is unsupported.
_vphone_cp() {
    cp -a -c "$@" 2>/dev/null || cp -a "$@"
}

VM_DIR="${VM_DIR:-vm}"
BACKUPS_DIR="${BACKUPS_DIR:-vm.backups}"
NAME="${NAME:-}"
FORCE="${FORCE:-0}"

validate_backup_name() {
    local name="$1"
    local label="${2:-NAME}"

    if [[ -z "${name}" ]]; then
        echo "ERROR: ${label} is required."
        exit 1
    fi

    if [[ "$name" == */* || "$name" == .* ]]; then
        echo "ERROR: ${label} must be a simple identifier (no slashes or leading dots)."
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

safe_clear_vm_dir() {
    if [[ -z "${VM_DIR}" || "${VM_DIR}" == "/" || "${VM_DIR}" == "." ]]; then
        echo "ERROR: Refusing to clear unsafe VM_DIR: '${VM_DIR}'"
        exit 1
    fi

    mkdir -p "${VM_DIR}"

    # Delete all direct contents, including hidden files.
    find "${VM_DIR}" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
}

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
    list_backups
    exit 1
fi

validate_backup_name "${NAME}"

SRC="${BACKUPS_DIR}/${NAME}"

# --- Validate backup ---
if [[ ! -d "${SRC}" ]]; then
    echo "ERROR: Backup '${NAME}' not found at ${SRC}/"
    echo ""
    echo "Available backups:"
    list_backups
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
if [[ -d "${VM_DIR}" && "${FORCE}" != "1" ]]; then
    current=""
    [[ -f "${VM_DIR}/.vm_name" ]] && current="$(< "${VM_DIR}/.vm_name")"
    echo "WARNING: ${VM_DIR}/ already exists${current:+ (current: '${current}')}."
    echo "  This will replace it with backup '${NAME}'."
    echo "  Existing files in ${VM_DIR}/ will be deleted first."
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

# --- Restore ---
safe_clear_vm_dir

while IFS= read -r -d '' item; do
    if [[ -d "${item}" || -f "${item}" ]]; then
        _vphone_cp "${item}" "${VM_DIR}/"
    fi
done < <(find "${SRC}" -mindepth 1 -maxdepth 1 -print0)

# Tag the active VM.
echo "${NAME}" > "${VM_DIR}/.vm_name"

echo ""
echo "=== Restored '${NAME}' ==="
echo "Next: make boot"
