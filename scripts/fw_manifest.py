#!/usr/bin/env python3
"""Generate hybrid BuildManifest.plist and Restore.plist for vresearch1 restore.

Merges cloudOS boot-chain infrastructure with iPhone OS images into a single
DFU erase-install Build Identity.  Only one identity is needed because the VM
always boots via DFU restore (never upgrade / recovery).

idevicerestore selects identities by partial-matching Info.Variant against
"Erase Install (IPSW)" while excluding variants containing "Research".
Our Variant "Darwin Cloud Customer Erase Install (IPSW)" satisfies both
conditions, so a single identity is sufficient.

Usage:
    python3 prepare_firmware_build_manifest.py <iphone_dir> <cloudos_dir>
"""

import copy, os, plistlib, sys


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def load(path):
    with open(path, "rb") as f:
        return plistlib.load(f)


def entry(identities, idx, key):
    """Deep-copy a single Manifest entry from a build identity."""
    return copy.deepcopy(identities[idx]["Manifest"][key])


# ---------------------------------------------------------------------------
# Identity discovery
# ---------------------------------------------------------------------------

def _is_research(bi):
    """Determine whether a build identity is a research variant.

    Checks the build-style segment in LLB/iBSS/iBEC paths
    (e.g. ``RELEASE`` vs ``RESEARCH_RELEASE``).
    Falls back to ``Info.Variant`` if no firmware paths are found.
    """
    for comp in ("LLB", "iBSS", "iBEC"):
        path = bi.get("Manifest", {}).get(comp, {}).get("Info", {}).get("Path", "")
        if not path:
            continue
        parts = os.path.basename(path).split(".")
        # Expected format: Component.Board.Style.im4p  (4 segments)
        if len(parts) == 4:
            return "RESEARCH" in parts[2]
    # Fallback: inspect the human-readable Variant string
    variant = bi.get("Info", {}).get("Variant", "")
    return "research" in variant.lower()


def find_cloudos(identities, device_class="vresearch101ap"):
    """Find release and research identity indices for the given DeviceClass."""
    release = research = None
    for i, bi in enumerate(identities):
        dc = bi.get("Info", {}).get("DeviceClass", "")
        if dc != device_class:
            continue
        if _is_research(bi):
            if research is None:
                research = i
        else:
            if release is None:
                release = i
    if release is None:
        raise KeyError(f"No release identity for DeviceClass={device_class}")
    if research is None:
        raise KeyError(f"No research identity for DeviceClass={device_class}")
    return release, research


def find_iphone_erase(identities):
    """Return the index of the first iPhone erase identity."""
    for i, bi in enumerate(identities):
        var = bi.get("Info", {}).get("Variant", "").lower()
        if "research" not in var and "upgrade" not in var and "recovery" not in var:
            return i
    raise KeyError("No erase identity found in iPhone manifest")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    if len(sys.argv) < 3:
        print(f"Usage: {sys.argv[0]} <iphone_dir> <cloudos_dir>",
              file=sys.stderr)
        sys.exit(1)

    iphone_dir, cloudos_dir = sys.argv[1], sys.argv[2]

    cloudos_bm = load(os.path.join(cloudos_dir, "BuildManifest.plist"))
    iphone_bm  = load(os.path.join(iphone_dir,  "BuildManifest.plist"))
    cloudos_rp = load(os.path.join(cloudos_dir, "Restore.plist"))
    iphone_rp  = load(os.path.join(iphone_dir,  "Restore.plist"))

    C = cloudos_bm["BuildIdentities"]
    I = iphone_bm["BuildIdentities"]

    # ── Discover source identities ───────────────────────────────────
    PROD, RES = find_cloudos(C, "vresearch101ap")
    VP_PROD, VP_RES = find_cloudos(C, "vphone600ap")
    I_ERASE   = find_iphone_erase(I)

    print(f"  cloudOS vresearch101ap: release=#{PROD}, research=#{RES}")
    print(f"  cloudOS vphone600ap:    release=#{VP_PROD}, research=#{VP_RES}")
    print(f"  iPhone  erase: #{I_ERASE}")

    # ── Build the single DFU erase identity ──────────────────────────
    bi = copy.deepcopy(C[PROD])
    bi["Manifest"] = {}
    bi["Ap,ProductType"]   = "ComputeModule14,2"
    bi["Ap,Target"]        = "VRESEARCH101AP"
    bi["Ap,TargetType"]    = "vresearch101"
    bi["ApBoardID"]        = "0x90"
    bi["ApChipID"]         = "0xFE01"
    bi["ApSecurityDomain"] = "0x01"
    for k in ("NeRDEpoch", "RestoreAttestationMode"):
        bi.pop(k, None)
        bi.get("Info", {}).pop(k, None)
    bi["Info"]["FDRSupport"] = False
    bi["Info"]["Variant"] = "Darwin Cloud Customer Erase Install (IPSW)"
    bi["Info"]["VariantContents"] = {
        "BasebandFirmware": "Release",
        "DCP": "DarwinProduction",
        "DFU": "DarwinProduction",
        "Firmware": "DarwinProduction",
        "InitiumBaseband": "Production",
        "InstalledKernelCache": "Production",
        "InstalledSPTM": "Production",
        "OS": "Production",
        "RestoreKernelCache": "Production",
        "RestoreRamDisk": "Production",
        "RestoreSEP": "DarwinProduction",
        "RestoreSPTM": "Production",
        "SEP": "DarwinProduction",
        "VinylFirmware": "Release",
    }

    m = bi["Manifest"]

    # ── RELEASE boot chain (LLB/iBSS/iBEC patched by patch_firmware.py) ──
    m["LLB"]  = entry(C, PROD, "LLB")
    m["iBSS"] = entry(C, PROD, "iBSS")
    m["iBEC"] = entry(C, PROD, "iBEC")
    # iBoot — only the research identity carries it
    m["iBoot"] = entry(C, RES, "iBoot")

    # ── Security monitors ────────────────────────────────────────────
    m["Ap,RestoreSecurePageTableMonitor"]  = entry(C, PROD, "Ap,RestoreSecurePageTableMonitor")
    m["Ap,RestoreTrustedExecutionMonitor"] = entry(C, PROD, "Ap,RestoreTrustedExecutionMonitor")
    m["Ap,SecurePageTableMonitor"]         = entry(C, PROD, "Ap,SecurePageTableMonitor")
    # Research TXM — patched by patch_firmware.py (txm.iphoneos.research.im4p)
    m["Ap,TrustedExecutionMonitor"]        = entry(C, RES,  "Ap,TrustedExecutionMonitor")

    # ── Device tree & SEP ────────────────────────────────────────────
    m["DeviceTree"]        = entry(C, PROD, "DeviceTree")
    m["RestoreDeviceTree"] = entry(C, PROD, "RestoreDeviceTree")
    m["SEP"]               = entry(C, PROD, "SEP")
    m["RestoreSEP"]        = entry(C, PROD, "RestoreSEP")

    # ── Research kernel (kernelcache.research.vphone600, patched by fw_patch.py)
    m["KernelCache"] = entry(C, VP_RES, "KernelCache")
    m["RestoreKernelCache"] = copy.deepcopy(m["KernelCache"])

    # ── CloudOS erase ramdisk ────────────────────────────────────────
    m["RestoreRamDisk"]    = entry(C, PROD, "RestoreRamDisk")
    m["RestoreTrustCache"] = entry(C, PROD, "RestoreTrustCache")

    # ── iPhone OS image ──────────────────────────────────────────────
    m["Ap,SystemVolumeCanonicalMetadata"] = entry(I, I_ERASE, "Ap,SystemVolumeCanonicalMetadata")
    m["OS"]              = entry(I, I_ERASE, "OS")
    m["StaticTrustCache"] = entry(I, I_ERASE, "StaticTrustCache")
    m["SystemVolume"]    = entry(I, I_ERASE, "SystemVolume")

    # ── Assemble BuildManifest ───────────────────────────────────────
    build_manifest = {
        "BuildIdentities": [bi],
        "ManifestVersion":     cloudos_bm["ManifestVersion"],
        "ProductBuildVersion": cloudos_bm["ProductBuildVersion"],
        "ProductVersion":      cloudos_bm["ProductVersion"],
        "SupportedProductTypes": ["iPhone99,11"],
    }

    # ── Assemble Restore.plist ───────────────────────────────────────
    restore = copy.deepcopy(cloudos_rp)
    restore["DeviceMap"] = [iphone_rp["DeviceMap"][0]] + [
        d for d in cloudos_rp["DeviceMap"]
        if d["BoardConfig"] in ("vphone600ap", "vresearch101ap")
    ]
    restore["SystemRestoreImageFileSystems"] = copy.deepcopy(
        iphone_rp["SystemRestoreImageFileSystems"])
    restore["SupportedProductTypeIDs"] = {
        cat: (iphone_rp["SupportedProductTypeIDs"][cat]
              + cloudos_rp["SupportedProductTypeIDs"][cat])
        for cat in ("DFU", "Recovery")
    }
    restore["SupportedProductTypes"] = (
        iphone_rp.get("SupportedProductTypes", [])
        + cloudos_rp.get("SupportedProductTypes", [])
    )

    # ── Write output ─────────────────────────────────────────────────
    for name, data in [("BuildManifest.plist", build_manifest),
                       ("Restore.plist", restore)]:
        path = os.path.join(iphone_dir, name)
        with open(path, "wb") as f:
            plistlib.dump(data, f, sort_keys=True)
        print(f"  wrote {name}")


if __name__ == "__main__":
    main()
