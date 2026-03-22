#!/bin/zsh
# ramdisk_send.sh — Send signed ramdisk components to device via pymobiledevice3.
#
# Usage: ./ramdisk_send.sh [ramdisk_dir]
#
# Expects device in DFU mode. Loads iBSS/iBEC, then boots with
# SPTM, TXM, trustcache, ramdisk, device tree, SEP, and kernel.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PMD3_BRIDGE="${PMD3_BRIDGE:-${SCRIPT_DIR}/pymobiledevice3_bridge.py}"
PYTHON="${PYTHON:-python3}"
IRECOVERY_ECID="${IRECOVERY_ECID:-}"
RAMDISK_UDID="${RAMDISK_UDID:-${RESTORE_UDID:-}}"
RAMDISK_DIR="${1:-Ramdisk}"

if [[ -n "$IRECOVERY_ECID" ]]; then
    IRECOVERY_ECID="${IRECOVERY_ECID#0x}"
    IRECOVERY_ECID="${IRECOVERY_ECID#0X}"
    [[ "$IRECOVERY_ECID" =~ ^[0-9A-Fa-f]{1,16}$ ]] || {
        echo "[-] Invalid IRECOVERY_ECID: ${IRECOVERY_ECID}"
        exit 1
    }
    IRECOVERY_ECID="0x${IRECOVERY_ECID:u}"
    echo "[*] Using ECID selector for ramdisk send: ${IRECOVERY_ECID}"
fi

echo "[*] Identity context for ramdisk_send:"
if [[ -n "$RAMDISK_UDID" ]]; then
    echo "    UDID: ${RAMDISK_UDID}"
else
    echo "    UDID: <unset>"
fi
if [[ -n "$IRECOVERY_ECID" ]]; then
    echo "    ECID: ${IRECOVERY_ECID}"
else
    echo "    ECID: <unset>"
fi

if [[ ! -d "$RAMDISK_DIR" ]]; then
    echo "[-] Ramdisk directory not found: $RAMDISK_DIR"
    echo "    Run 'make ramdisk_build' first."
    exit 1
fi

if [[ ! -f "$PMD3_BRIDGE" ]]; then
    echo "[-] pymobiledevice3 bridge script not found: $PMD3_BRIDGE"
    exit 1
fi
echo "[*] Using pymobiledevice3 backend for ramdisk send"
cmd=("$PYTHON" "$PMD3_BRIDGE" ramdisk-send --ramdisk-dir "$RAMDISK_DIR")
if [[ -n "$IRECOVERY_ECID" ]]; then
    cmd+=(--ecid "$IRECOVERY_ECID")
fi
"${cmd[@]}"
