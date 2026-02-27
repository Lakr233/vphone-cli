#!/bin/zsh
# create_vm.sh — Create a new vphone VM directory with all required files.
#
# Mirrors the vrevm VM creation process:
#   1. Create VM directory structure
#   2. Create sparse disk image (default 64 GB)
#   3. Create SEP storage (512 KB flat file)
#   4. Copy AVPBooter and AVPSEPBooter ROMs
#
# machineIdentifier and NVRAM are auto-created on first boot by vphone-cli.
#
# Usage:
#   ./create_vm.sh                          # Create VM/ with framework ROMs
#   ./create_vm.sh --dir MyVM               # Custom directory name
#   ./create_vm.sh --disk-size 32           # 32 GB disk
#   ./create_vm.sh --rom /path/to/avpboot   # Custom AVPBooter ROM
#   ./create_vm.sh --seprom /path/to/sepboot # Custom AVPSEPBooter ROM
set -euo pipefail

# --- Defaults ---
VM_DIR="VM"
DISK_SIZE_GB=64
SEP_STORAGE_SIZE=$((512 * 1024))  # 512 KB (same as vrevm)

# Framework-bundled ROMs (vresearch1 / research1 chip)
FW_ROM_DIR="/System/Library/Frameworks/Virtualization.framework/Versions/A/Resources"
ROM_SRC="${FW_ROM_DIR}/AVPBooter.vresearch1.bin"
SEPROM_SRC="${FW_ROM_DIR}/AVPSEPBooter.vresearch1.bin"

# --- Parse args ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dir)      VM_DIR="$2";        shift 2 ;;
        --disk-size) DISK_SIZE_GB="$2"; shift 2 ;;
        --rom)      ROM_SRC="$2";       shift 2 ;;
        --seprom)   SEPROM_SRC="$2";    shift 2 ;;
        -h|--help)
            echo "Usage: $0 [--dir VM] [--disk-size 64] [--rom path] [--seprom path]"
            echo ""
            echo "Options:"
            echo "  --dir       VM directory name (default: VM)"
            echo "  --disk-size Disk image size in GB (default: 64)"
            echo "  --rom       Path to AVPBooter ROM (default: framework built-in)"
            echo "  --seprom    Path to AVPSEPBooter ROM (default: framework built-in)"
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

DISK_SIZE_BYTES=$((DISK_SIZE_GB * 1024 * 1024 * 1024))

echo "=== vphone create_vm ==="
echo "Directory : ${VM_DIR}"
echo "Disk size : ${DISK_SIZE_GB} GB"
echo "AVPBooter : ${ROM_SRC}"
echo "AVPSEPBooter: ${SEPROM_SRC}"
echo ""

# --- Validate ROM sources ---
if [[ ! -f "${ROM_SRC}" ]]; then
    echo "ERROR: AVPBooter ROM not found: ${ROM_SRC}"
    echo "  On Apple Internal macOS, this should be at:"
    echo "  ${FW_ROM_DIR}/AVPBooter.vresearch1.bin"
    exit 1
fi

if [[ ! -f "${SEPROM_SRC}" ]]; then
    echo "ERROR: AVPSEPBooter ROM not found: ${SEPROM_SRC}"
    echo "  On Apple Internal macOS, this should be at:"
    echo "  ${FW_ROM_DIR}/AVPSEPBooter.vresearch1.bin"
    exit 1
fi

# --- Create VM directory ---
if [[ -d "${VM_DIR}" ]]; then
    echo "WARNING: ${VM_DIR}/ already exists"
    # Check for existing disk to avoid accidental overwrite
    if [[ -f "${VM_DIR}/Disk.img" ]]; then
        echo "  Disk.img already exists — skipping disk creation"
        echo "  Delete ${VM_DIR}/Disk.img manually to recreate"
    fi
else
    echo "[1/4] Creating ${VM_DIR}/"
    mkdir -p "${VM_DIR}"
fi

# --- Create sparse disk image ---
if [[ ! -f "${VM_DIR}/Disk.img" ]]; then
    echo "[2/4] Creating sparse disk image (${DISK_SIZE_GB} GB)"
    # Use dd with seek to create a sparse file (same approach as vrevm)
    dd if=/dev/zero of="${VM_DIR}/Disk.img" bs=1 count=0 seek="${DISK_SIZE_BYTES}" 2>/dev/null
    echo "  -> ${VM_DIR}/Disk.img ($(du -h "${VM_DIR}/Disk.img" | cut -f1) on disk)"
else
    echo "[2/4] Disk.img exists — skipping"
fi

# --- Create SEP storage ---
if [[ ! -f "${VM_DIR}/SEPStorage" ]]; then
    echo "[3/4] Creating SEP storage (512 KB)"
    dd if=/dev/zero of="${VM_DIR}/SEPStorage" bs=1 count="${SEP_STORAGE_SIZE}" 2>/dev/null
else
    echo "[3/4] SEPStorage exists — skipping"
fi

# --- Copy ROMs ---
echo "[4/4] Copying ROMs"

ROM_DST="${VM_DIR}/AVPBooter.vresearch1.bin"
SEPROM_DST="${VM_DIR}/AVPSEPBooter.vresearch1.bin"

if [[ -f "${ROM_DST}" ]] && cmp -s "${ROM_SRC}" "${ROM_DST}"; then
    echo "  AVPBooter.vresearch1.bin — up to date"
else
    cp "${ROM_SRC}" "${ROM_DST}"
    echo "  AVPBooter.vresearch1.bin — copied ($(wc -c < "${ROM_DST}" | tr -d ' ') bytes)"
fi

if [[ -f "${SEPROM_DST}" ]] && cmp -s "${SEPROM_SRC}" "${SEPROM_DST}"; then
    echo "  AVPSEPBooter.vresearch1.bin — up to date"
else
    cp "${SEPROM_SRC}" "${SEPROM_DST}"
    echo "  AVPSEPBooter.vresearch1.bin — copied ($(wc -c < "${SEPROM_DST}" | tr -d ' ') bytes)"
fi

# --- Create .gitkeep ---
touch "${VM_DIR}/.gitkeep"

echo ""
echo "=== VM created at ${VM_DIR}/ ==="
echo ""
echo "Contents:"
ls -lh "${VM_DIR}/"
echo ""
echo "Next steps:"
echo "  1. Prepare firmware:  cd ${VM_DIR} && ../Scripts/prepare_firmware.sh"
echo "  2. Patch firmware:    source ../.venv/bin/activate && python ../Scripts/patch_firmware.py"
echo "  3. Boot DFU:          cd ${VM_DIR} && ../boot_dfu.sh"
echo "  4. Boot normal:       cd ${VM_DIR} && ../boot.sh"
