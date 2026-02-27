#!/bin/zsh
# ramdisk_send.sh — Send signed ramdisk components to device via irecovery.
#
# Usage: ./ramdisk_send.sh [ramdisk_dir]
#
# Expects device in DFU mode. Loads iBSS/iBEC, then boots with
# SPTM, TXM, trustcache, ramdisk, device tree, SEP, and kernel.
set -euo pipefail

IRECOVERY="${IRECOVERY:-irecovery}"
RAMDISK_DIR="${1:-Ramdisk}"

if [ ! -d "$RAMDISK_DIR" ]; then
    echo "[-] Ramdisk directory not found: $RAMDISK_DIR"
    echo "    Run 'make ramdisk_build' first."
    exit 1
fi

echo "[*] Sending ramdisk from $RAMDISK_DIR ..."

# 1. Load iBSS + iBEC (DFU → recovery)
echo "  [1/8] Loading iBSS..."
"$IRECOVERY" -f "$RAMDISK_DIR/iBSS.vresearch101.RELEASE.img4"

echo "  [2/8] Loading iBEC..."
"$IRECOVERY" -f "$RAMDISK_DIR/iBEC.vresearch101.RELEASE.img4"
"$IRECOVERY" -c go

sleep 1

# 2. Load SPTM
echo "  [3/8] Loading SPTM..."
"$IRECOVERY" -f "$RAMDISK_DIR/sptm.vresearch1.release.img4"
"$IRECOVERY" -c firmware

# 3. Load TXM
echo "  [4/8] Loading TXM..."
"$IRECOVERY" -f "$RAMDISK_DIR/txm.img4"
"$IRECOVERY" -c firmware

# 4. Load trustcache
echo "  [5/8] Loading trustcache..."
"$IRECOVERY" -f "$RAMDISK_DIR/trustcache.img4"
"$IRECOVERY" -c firmware

# 5. Load ramdisk
echo "  [6/8] Loading ramdisk..."
"$IRECOVERY" -f "$RAMDISK_DIR/ramdisk.img4"
sleep 2
"$IRECOVERY" -c ramdisk

# 6. Load device tree
echo "  [7/8] Loading device tree..."
"$IRECOVERY" -f "$RAMDISK_DIR/DeviceTree.vphone600ap.img4"
"$IRECOVERY" -c devicetree

# 7. Load SEP
echo "  [8/8] Loading SEP..."
"$IRECOVERY" -f "$RAMDISK_DIR/sep-firmware.vresearch101.RELEASE.img4"
"$IRECOVERY" -c firmware

# 8. Load kernel and boot
echo "  [*] Booting kernel..."
"$IRECOVERY" -f "$RAMDISK_DIR/krnl.img4"
"$IRECOVERY" -c bootx

echo "[+] Boot sequence complete. Device should be booting into ramdisk."
