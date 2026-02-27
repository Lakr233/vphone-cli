#!/bin/bash
# prepare_firmware.sh — Download/copy, merge, and generate hybrid restore firmware.
# Combines cloudOS boot chain with iPhone OS images for vresearch101.
#
# Accepts URLs or local file paths. Local paths are copied instead of downloaded.
# All output goes to the current working directory.
#
# Usage:
#   cd VM && ../Scripts/prepare_firmware.sh [iphone_source] [cloudos_source]
#
# Environment variables (override positional args):
#   IPHONE_SOURCE  — URL or local path to iPhone IPSW
#   CLOUDOS_SOURCE — URL or local path to cloudOS IPSW
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

IPHONE_SOURCE="${IPHONE_SOURCE:-${1:-https://updates.cdn-apple.com/2025FallFCS/fullrestores/089-13864/668EFC0E-5911-454C-96C6-E1063CB80042/iPhone17,3_26.1_23B85_Restore.ipsw}}"
CLOUDOS_SOURCE="${CLOUDOS_SOURCE:-${2:-https://updates.cdn-apple.com/private-cloud-compute/399b664dd623358c3de118ffc114e42dcd51c9309e751d43bc949b98f4e31349}}"

# Derive local filenames from source basename
IPHONE_IPSW="${IPHONE_SOURCE##*/}"
IPHONE_DIR="${IPHONE_IPSW%.ipsw}"
CLOUDOS_IPSW="${CLOUDOS_SOURCE##*/}"
# Fallback name if the source basename has no extension (e.g. raw CDN hash URL)
[[ "$CLOUDOS_IPSW" == *.ipsw ]] || CLOUDOS_IPSW="pcc-base.ipsw"
CLOUDOS_DIR="${CLOUDOS_IPSW%.ipsw}"

echo "=== prepare_firmware ==="
echo "  iPhone:  $IPHONE_SOURCE"
echo "  CloudOS: $CLOUDOS_SOURCE"
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
        echo "==> Downloading $out ..."
        wget -q --show-progress -O "$out" "$src" --no-check-certificate
    fi
}

fetch "$IPHONE_SOURCE"  "$IPHONE_IPSW"
fetch "$CLOUDOS_SOURCE" "$CLOUDOS_IPSW"

# ── Extract ───────────────────────────────────────────────────────────
extract() {
    local zip="$1" dir="$2"
    if [[ -d "$dir" ]]; then
        echo "==> Skipping extract: '$dir' already exists."
        return
    fi
    echo "==> Extracting $zip ..."
    mkdir -p "$dir"
    unzip -oq "$zip" -d "$dir"
    chmod -R u+w "$dir"
}

extract "$IPHONE_IPSW" "$IPHONE_DIR"
extract "$CLOUDOS_IPSW" "$CLOUDOS_DIR"

# ── Merge cloudOS firmware into iPhone restore directory ──────────────
echo "==> Importing cloudOS firmware components ..."

cp ${CLOUDOS_DIR}/kernelcache.* "$IPHONE_DIR"/

for sub in agx all_flash ane dfu pmp; do
    cp ${CLOUDOS_DIR}/Firmware/${sub}/* "$IPHONE_DIR/Firmware/${sub}"/
done

cp ${CLOUDOS_DIR}/Firmware/*.im4p "$IPHONE_DIR/Firmware"/

# ── Generate hybrid BuildManifest.plist & Restore.plist ───────────────
echo "==> Generating hybrid plists ..."

python3 - "$IPHONE_DIR" "$CLOUDOS_DIR" <<'PYEOF'
import copy, os, plistlib, sys

iphone_dir, cloudos_dir = sys.argv[1], sys.argv[2]

def load(path):
    with open(path, "rb") as f:
        return plistlib.load(f)

cloudos_bm = load(os.path.join(cloudos_dir, "BuildManifest.plist"))
iphone_bm = load(os.path.join(iphone_dir,  "BuildManifest.plist"))
cloudos_rp = load(os.path.join(cloudos_dir, "Restore.plist"))
iphone_rp  = load(os.path.join(iphone_dir,  "Restore.plist"))

# Source identities
# C: [0]j236c [1]j475d [2]vphone600-prod [3]vresearch101-prod [4]vphone600-research [5]vresearch101-research
# I: [0]Erase [1]Upgrade [2]ResearchErase [3]ResearchUpgrade [4]Recovery
C = cloudos_bm["BuildIdentities"]
I = iphone_bm["BuildIdentities"]

def entry(src, idx, key):
    return copy.deepcopy(src[idx]["Manifest"][key])

# ── Base identity template (vresearch101) ─────────────────────────────
def make_base():
    b = copy.deepcopy(C[3])
    b["Manifest"] = {}
    b["Ap,ProductType"]    = "ComputeModule14,2"
    b["Ap,Target"]         = "VRESEARCH101AP"
    b["Ap,TargetType"]     = "vresearch101"
    b["ApBoardID"]         = "0x90"
    b["ApChipID"]          = "0xFE01"
    b["ApSecurityDomain"]  = "0x01"
    for k in ("NeRDEpoch", "RestoreAttestationMode"):
        b.pop(k, None)
        b.get("Info", {}).pop(k, None)
    b["Info"]["FDRSupport"] = False
    b["Info"]["Variant"] = "Darwin Cloud Customer Erase Install (IPSW)"
    b["Info"]["VariantContents"] = {
        "BasebandFirmware": "Release",       "DCP": "DarwinProduction",
        "DFU": "DarwinProduction",           "Firmware": "DarwinProduction",
        "InitiumBaseband": "Production",     "InstalledKernelCache": "Production",
        "InstalledSPTM": "Production",       "OS": "Production",
        "RestoreKernelCache": "Production",  "RestoreRamDisk": "Production",
        "RestoreSEP": "DarwinProduction",    "RestoreSPTM": "Production",
        "SEP": "DarwinProduction",           "VinylFirmware": "Release",
    }
    return b

# Shared manifest blocks — cloudOS boot infra
def boot_infra(m, llb_src=3, sep_src=2, boot_variant="release"):
    """Add SPTM/TXM/DeviceTree/KernelCache/LLB/iBoot/iBEC/iBSS/SEP entries."""
    research = 4  # cloudOS research identity index
    m["Ap,RestoreSecurePageTableMonitor"]  = entry(C, 3, "Ap,RestoreSecurePageTableMonitor")
    m["Ap,RestoreTrustedExecutionMonitor"] = entry(C, 3, "Ap,RestoreTrustedExecutionMonitor")
    m["Ap,SecurePageTableMonitor"]         = entry(C, 3, "Ap,SecurePageTableMonitor")
    m["Ap,TrustedExecutionMonitor"]        = entry(C, research, "Ap,TrustedExecutionMonitor")
    m["DeviceTree"]          = entry(C, 2, "DeviceTree")
    m["KernelCache"]         = entry(C, research, "KernelCache")
    idx = 3 if boot_variant == "release" else research
    m["LLB"]  = entry(C, idx, "LLB")
    m["iBEC"] = entry(C, idx, "iBEC")
    m["iBSS"] = entry(C, idx, "iBSS")
    m["iBoot"] = entry(C, research, "iBoot")
    m["RecoveryMode"]        = entry(I, 0, "RecoveryMode")
    m["RestoreDeviceTree"]   = entry(C, 2, "RestoreDeviceTree")
    m["RestoreKernelCache"]  = entry(C, 2, "RestoreKernelCache")
    m["RestoreSEP"]          = entry(C, sep_src, "RestoreSEP")
    m["SEP"]                 = entry(C, sep_src, "SEP")

# Shared manifest block — iPhone OS images
def iphone_os(m, os_src=0):
    m["Ap,SystemVolumeCanonicalMetadata"] = entry(I, os_src, "Ap,SystemVolumeCanonicalMetadata")
    m["OS"]              = entry(I, os_src, "OS")
    m["StaticTrustCache"] = entry(I, os_src, "StaticTrustCache")
    m["SystemVolume"]    = entry(I, os_src, "SystemVolume")

# ── 5 Build Identities ───────────────────────────────────────────────
def identity_0():
    """Erase — Cryptex1 identity keys, RELEASE LLB/iBEC/iBSS, cloudOS erase ramdisk."""
    bi = make_base()
    for k in ("Cryptex1,ChipID", "Cryptex1,NonceDomain", "Cryptex1,PreauthorizationVersion",
              "Cryptex1,ProductClass", "Cryptex1,SubType", "Cryptex1,Type", "Cryptex1,Version"):
        bi[k] = I[0][k]
    bi["Info"]["Cryptex1,AppOSSize"]    = I[0]["Info"]["Cryptex1,AppOSSize"]
    bi["Info"]["Cryptex1,SystemOSSize"] = I[0]["Info"]["Cryptex1,SystemOSSize"]
    bi["Info"]["VariantContents"]["Cryptex1,AppOS"]    = "CryptexOne"
    bi["Info"]["VariantContents"]["Cryptex1,SystemOS"] = "CryptexOne"
    m = bi["Manifest"]
    boot_infra(m, llb_src=3, sep_src=2, boot_variant="release")
    m["RestoreRamDisk"]  = entry(C, 3, "RestoreRamDisk")
    m["RestoreTrustCache"] = entry(C, 3, "RestoreTrustCache")
    iphone_os(m)
    return bi

def identity_1():
    """Upgrade — Cryptex1 manifest entries, RESEARCH boot chain, iPhone upgrade ramdisk."""
    bi = make_base()
    m = bi["Manifest"]
    boot_infra(m, llb_src=4, sep_src=3, boot_variant="research")
    m["AppleLogo"]   = entry(C, 4, "AppleLogo")
    m["RestoreLogo"] = entry(C, 4, "RestoreLogo")
    for k in ("Cryptex1,AppOS", "Cryptex1,AppTrustCache", "Cryptex1,AppVolume",
              "Cryptex1,SystemOS", "Cryptex1,SystemTrustCache", "Cryptex1,SystemVolume"):
        m[k] = entry(I, 0, k)
    m["RestoreRamDisk"]    = entry(I, 1, "RestoreRamDisk")
    m["RestoreTrustCache"] = entry(I, 1, "RestoreTrustCache")
    iphone_os(m)
    return bi

def identity_2():
    """Research erase — RESEARCH boot chain, cloudOS erase ramdisk, no Cryptex1."""
    bi = make_base()
    m = bi["Manifest"]
    boot_infra(m, llb_src=4, sep_src=3, boot_variant="research")
    m["AppleLogo"]       = entry(C, 4, "AppleLogo")
    m["RestoreLogo"]     = entry(C, 4, "RestoreLogo")
    m["RestoreRamDisk"]  = entry(C, 3, "RestoreRamDisk")
    m["RestoreTrustCache"] = entry(C, 3, "RestoreTrustCache")
    iphone_os(m)
    return bi

def identity_3():
    """Research upgrade — same as identity_2 but with iPhone upgrade ramdisk."""
    bi = identity_2()
    m = bi["Manifest"]
    m["RestoreRamDisk"]    = entry(I, 1, "RestoreRamDisk")
    m["RestoreTrustCache"] = entry(I, 1, "RestoreTrustCache")
    return bi

def identity_4():
    """Recovery — stripped down, iPhone Recovery OS."""
    bi = make_base()
    m = bi["Manifest"]
    boot_infra(m, llb_src=4, sep_src=3, boot_variant="research")
    # Recovery has no RestoreDeviceTree/RestoreSEP/SEP/RecoveryMode/iBoot
    for k in ("RestoreDeviceTree", "RestoreSEP", "SEP", "RecoveryMode", "iBoot"):
        m.pop(k, None)
    m["AppleLogo"]       = entry(C, 4, "AppleLogo")
    m["RestoreRamDisk"]  = entry(C, 3, "RestoreRamDisk")
    m["RestoreTrustCache"] = entry(C, 3, "RestoreTrustCache")
    iphone_os(m, os_src=4)
    return bi

# ── Assemble BuildManifest ────────────────────────────────────────────
build_manifest = {
    "BuildIdentities": [identity_0(), identity_1(), identity_2(), identity_3(), identity_4()],
    "ManifestVersion": cloudos_bm["ManifestVersion"],
    "ProductBuildVersion": cloudos_bm["ProductBuildVersion"],
    "ProductVersion": cloudos_bm["ProductVersion"],
    "SupportedProductTypes": ["iPhone99,11"],
}

# ── Assemble Restore.plist ────────────────────────────────────────────
restore = copy.deepcopy(cloudos_rp)
restore["DeviceMap"] = [iphone_rp["DeviceMap"][0]] + [
    d for d in cloudos_rp["DeviceMap"] if d["BoardConfig"] in ("vphone600ap", "vresearch101ap")
]
restore["SystemRestoreImageFileSystems"] = copy.deepcopy(iphone_rp["SystemRestoreImageFileSystems"])
restore["SupportedProductTypeIDs"] = {
    cat: iphone_rp["SupportedProductTypeIDs"][cat] + cloudos_rp["SupportedProductTypeIDs"][cat]
    for cat in ("DFU", "Recovery")
}
restore["SupportedProductTypes"] = (
    iphone_rp.get("SupportedProductTypes", []) + cloudos_rp.get("SupportedProductTypes", [])
)

# ── Write output ──────────────────────────────────────────────────────
for name, data in [("BuildManifest.plist", build_manifest), ("Restore.plist", restore)]:
    path = os.path.join(iphone_dir, name)
    with open(path, "wb") as f:
        plistlib.dump(data, f, sort_keys=True)
    print(f"  wrote {name}")
PYEOF

# ── Cleanup (keep IPSWs, remove intermediate files) ──────────────────
echo "==> Cleaning up ..."
rm -rf "$CLOUDOS_DIR"

echo "==> Done. Restore directory ready: $IPHONE_DIR/"
