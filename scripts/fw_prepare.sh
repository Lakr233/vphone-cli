#!/bin/bash
# fw_prepare.sh — Download/copy, merge, and generate hybrid restore firmware.
# Combines cloudOS boot chain with iPhone OS images for vresearch101.
#
# Accepts URLs or local file paths. Local paths are copied instead of downloaded.
# IPSWs are cached in a project-level directory; extracted firmware output goes to cwd.
#
# Usage:
#   make fw_prepare
#
# Environment variables (override positional args):
#   IPHONE_SOURCE  — URL or local path to iPhone IPSW
#   CLOUDOS_SOURCE — URL or local path to cloudOS IPSW
#   IPSW_DIR       — directory used to cache downloaded/copied IPSWs
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

IPHONE_SOURCE="${IPHONE_SOURCE:-${1:-https://updates.cdn-apple.com/2025FallFCS/fullrestores/089-13864/668EFC0E-5911-454C-96C6-E1063CB80042/iPhone17,3_26.1_23B85_Restore.ipsw}}"
CLOUDOS_SOURCE="${CLOUDOS_SOURCE:-${2:-https://updates.cdn-apple.com/private-cloud-compute/399b664dd623358c3de118ffc114e42dcd51c9309e751d43bc949b98f4e31349}}"
IPSW_DIR="${IPSW_DIR:-${SCRIPT_DIR}/../ipsws}"

# Derive local filenames from source basename
IPHONE_IPSW="${IPHONE_SOURCE##*/}"
IPHONE_DIR="${IPHONE_IPSW%.ipsw}"
CLOUDOS_IPSW="${CLOUDOS_SOURCE##*/}"
# Fallback name if the source basename has no extension (e.g. raw CDN hash URL)
[[ "$CLOUDOS_IPSW" == *.ipsw ]] || CLOUDOS_IPSW="pcc-base.ipsw"
CLOUDOS_DIR="${CLOUDOS_IPSW%.ipsw}"
IPHONE_IPSW_PATH="${IPSW_DIR}/${IPHONE_IPSW}"
CLOUDOS_IPSW_PATH="${IPSW_DIR}/${CLOUDOS_IPSW}"

mkdir -p "$IPSW_DIR"

echo "=== prepare_firmware ==="
echo "  iPhone:  $IPHONE_SOURCE"
echo "  CloudOS: $CLOUDOS_SOURCE"
echo "  IPSWs:   $IPSW_DIR"
echo "  Output:  $(pwd)/$IPHONE_DIR/"
echo ""

# ── Fetch (download or copy) ─────────────────────────────────────────
is_local() { [[ "$1" != http://* && "$1" != https://* ]]; }

fetch() {
    local src="$1" out="$2"
    if [[ -f "$out" ]]; then
        echo "==> Skipping: '$out' already exists."
        return
    fi
    if is_local "$src"; then
        echo "==> Copying ${src##*/} ..."
        cp -- "$src" "$out"
    else
        echo "==> Downloading ${out##*/} ..."
        if ! wget --no-check-certificate --show-progress -O "$out" "$src"; then
            echo "ERROR: Failed to download '$src'" >&2
            rm -f "$out"
            exit 1
        fi
    fi
}

fetch "$IPHONE_SOURCE"  "$IPHONE_IPSW_PATH"
fetch "$CLOUDOS_SOURCE" "$CLOUDOS_IPSW_PATH"

# ── Extract ───────────────────────────────────────────────────────────
extract() {
    local zip="$1" dir="$2"
    rm -rf "$dir"
    echo "==> Extracting $zip ..."
    mkdir -p "$dir"
    unzip -oq "$zip" -d "$dir"
    chmod -R u+w "$dir"
}

extract "$IPHONE_IPSW_PATH" "$IPHONE_DIR"
extract "$CLOUDOS_IPSW_PATH" "$CLOUDOS_DIR"

# ── Merge cloudOS firmware into iPhone restore directory ──────────────
echo "==> Importing cloudOS firmware components ..."

cp ${CLOUDOS_DIR}/kernelcache.* "$IPHONE_DIR"/

for sub in agx all_flash ane dfu pmp; do
    cp ${CLOUDOS_DIR}/Firmware/${sub}/* "$IPHONE_DIR/Firmware/${sub}"/
done

cp ${CLOUDOS_DIR}/Firmware/*.im4p "$IPHONE_DIR/Firmware"/

# CloudOS ramdisk DMGs and trustcaches (RestoreRamDisk / RestoreTrustCache)
cp -n ${CLOUDOS_DIR}/*.dmg "$IPHONE_DIR"/ 2>/dev/null || true
cp -n ${CLOUDOS_DIR}/Firmware/*.dmg.trustcache "$IPHONE_DIR/Firmware"/ 2>/dev/null || true

# ── Preserve original iPhone BuildManifest (cfw_install.sh reads Cryptex paths) ──
cp "$IPHONE_DIR/BuildManifest.plist" "$IPHONE_DIR/BuildManifest-iPhone.plist"

# ── Generate hybrid BuildManifest.plist & Restore.plist ───────────────
echo "==> Generating hybrid plists ..."

python3 "$SCRIPT_DIR/fw_manifest.py" "$IPHONE_DIR" "$CLOUDOS_DIR"

# ── Cleanup (keep IPSWs in IPSW_DIR, remove intermediate files) ──────
echo "==> Cleaning up ..."
rm -rf "$CLOUDOS_DIR"

echo "==> Done. Restore directory ready: $IPHONE_DIR/"
echo "    Run 'make fw_patch' to patch boot-chain components."
