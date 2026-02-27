#!/usr/bin/env python3
"""Generate hybrid BuildManifest.plist and Restore.plist for vresearch1 restore.

Merges cloudOS boot-chain infrastructure with iPhone OS images.
Discovers identities by DeviceClass and build variant instead of using
hard-coded indices, so the script works across firmware versions.

All cloudOS components are sourced exclusively from vresearch101ap identities.

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


def try_entry(identities, idx, key):
    """Deep-copy a Manifest entry, or return None if the key is absent."""
    manifest = identities[idx].get("Manifest", {})
    if key in manifest:
        return copy.deepcopy(manifest[key])
    return None


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


def index_iphone(identities):
    """Map role name -> identity index by ``Info.Variant`` string."""
    result = {}
    for i, bi in enumerate(identities):
        var = bi.get("Info", {}).get("Variant", "").lower()
        is_research = "research" in var
        is_upgrade  = "upgrade"  in var
        is_recovery = "recovery" in var

        if is_recovery:
            result.setdefault("recovery", i)
        elif is_research and is_upgrade:
            result.setdefault("research_upgrade", i)
        elif is_research:
            result.setdefault("research_erase", i)
        elif is_upgrade:
            result.setdefault("upgrade", i)
        else:
            result.setdefault("erase", i)
    return result


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

    # ── Discover identities dynamically ──────────────────────────────
    PROD, RES = find_cloudos(C, "vresearch101ap")
    iidx = index_iphone(I)

    print(f"  cloudOS vresearch101ap: release=#{PROD}, research=#{RES}")
    print("  iPhone  identities: " + ", ".join(
        f"{k}=#{v}" for k, v in sorted(iidx.items())))

    I_ERASE    = iidx["erase"]
    I_UPGRADE  = iidx["upgrade"]
    I_RECOVERY = iidx["recovery"]

    # ── Base identity template ───────────────────────────────────────
    def make_base():
        b = copy.deepcopy(C[PROD])
        b["Manifest"] = {}
        b["Ap,ProductType"]   = "ComputeModule14,2"
        b["Ap,Target"]        = "VRESEARCH101AP"
        b["Ap,TargetType"]    = "vresearch101"
        b["ApBoardID"]        = "0x90"
        b["ApChipID"]         = "0xFE01"
        b["ApSecurityDomain"] = "0x01"
        for k in ("NeRDEpoch", "RestoreAttestationMode"):
            b.pop(k, None)
            b.get("Info", {}).pop(k, None)
        b["Info"]["FDRSupport"] = False
        b["Info"]["Variant"] = "Darwin Cloud Customer Erase Install (IPSW)"
        b["Info"]["VariantContents"] = {
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
        return b

    # ── Shared manifest blocks ───────────────────────────────────────
    def boot_infra(m, boot_variant="release"):
        """CloudOS boot infrastructure from vresearch101ap identities."""
        m["Ap,RestoreSecurePageTableMonitor"]  = entry(C, PROD, "Ap,RestoreSecurePageTableMonitor")
        m["Ap,RestoreTrustedExecutionMonitor"] = entry(C, PROD, "Ap,RestoreTrustedExecutionMonitor")
        m["Ap,SecurePageTableMonitor"]         = entry(C, PROD, "Ap,SecurePageTableMonitor")
        m["Ap,TrustedExecutionMonitor"]        = entry(C, RES,  "Ap,TrustedExecutionMonitor")
        m["DeviceTree"]         = entry(C, PROD, "DeviceTree")
        m["KernelCache"]        = entry(C, RES,  "KernelCache")
        boot_idx = PROD if boot_variant == "release" else RES
        m["LLB"]  = entry(C, boot_idx, "LLB")
        m["iBEC"] = entry(C, boot_idx, "iBEC")
        m["iBSS"] = entry(C, boot_idx, "iBSS")
        m["iBoot"] = entry(C, RES, "iBoot")
        m["RecoveryMode"]       = entry(I, I_ERASE, "RecoveryMode")
        m["RestoreDeviceTree"]  = entry(C, PROD, "RestoreDeviceTree")
        m["RestoreKernelCache"] = entry(C, PROD, "RestoreKernelCache")
        m["RestoreSEP"]         = entry(C, PROD, "RestoreSEP")
        m["SEP"]                = entry(C, PROD, "SEP")

    def iphone_os(m, os_src=I_ERASE):
        """iPhone OS image entries."""
        m["Ap,SystemVolumeCanonicalMetadata"] = entry(I, os_src, "Ap,SystemVolumeCanonicalMetadata")
        m["OS"]              = entry(I, os_src, "OS")
        m["StaticTrustCache"] = entry(I, os_src, "StaticTrustCache")
        m["SystemVolume"]    = entry(I, os_src, "SystemVolume")

    def add_logos(m):
        """Add AppleLogo/RestoreLogo if present in the research identity."""
        for k in ("AppleLogo", "RestoreLogo"):
            e = try_entry(C, RES, k)
            if e:
                m[k] = e

    # ── 5 Build Identities ──────────────────────────────────────────
    def identity_0():
        """Erase — Cryptex1 identity keys, RELEASE boot, cloudOS erase ramdisk."""
        bi = make_base()
        for k in ("Cryptex1,ChipID", "Cryptex1,NonceDomain",
                  "Cryptex1,PreauthorizationVersion", "Cryptex1,ProductClass",
                  "Cryptex1,SubType", "Cryptex1,Type", "Cryptex1,Version"):
            bi[k] = I[I_ERASE][k]
        bi["Info"]["Cryptex1,AppOSSize"]    = I[I_ERASE]["Info"]["Cryptex1,AppOSSize"]
        bi["Info"]["Cryptex1,SystemOSSize"] = I[I_ERASE]["Info"]["Cryptex1,SystemOSSize"]
        bi["Info"]["VariantContents"]["Cryptex1,AppOS"]    = "CryptexOne"
        bi["Info"]["VariantContents"]["Cryptex1,SystemOS"] = "CryptexOne"
        m = bi["Manifest"]
        boot_infra(m, boot_variant="release")
        m["RestoreRamDisk"]    = entry(C, PROD, "RestoreRamDisk")
        m["RestoreTrustCache"] = entry(C, PROD, "RestoreTrustCache")
        iphone_os(m)
        return bi

    def identity_1():
        """Upgrade — Cryptex1 manifest entries, RESEARCH boot, iPhone upgrade ramdisk."""
        bi = make_base()
        m = bi["Manifest"]
        boot_infra(m, boot_variant="research")
        add_logos(m)
        for k in ("Cryptex1,AppOS", "Cryptex1,AppTrustCache",
                  "Cryptex1,AppVolume", "Cryptex1,SystemOS",
                  "Cryptex1,SystemTrustCache", "Cryptex1,SystemVolume"):
            m[k] = entry(I, I_ERASE, k)
        m["RestoreRamDisk"]    = entry(I, I_UPGRADE, "RestoreRamDisk")
        m["RestoreTrustCache"] = entry(I, I_UPGRADE, "RestoreTrustCache")
        iphone_os(m)
        return bi

    def identity_2():
        """Research erase — RESEARCH boot, cloudOS erase ramdisk, no Cryptex1."""
        bi = make_base()
        m = bi["Manifest"]
        boot_infra(m, boot_variant="research")
        add_logos(m)
        m["RestoreRamDisk"]    = entry(C, PROD, "RestoreRamDisk")
        m["RestoreTrustCache"] = entry(C, PROD, "RestoreTrustCache")
        iphone_os(m)
        return bi

    def identity_3():
        """Research upgrade — same as identity_2 but with iPhone upgrade ramdisk."""
        bi = identity_2()
        m = bi["Manifest"]
        m["RestoreRamDisk"]    = entry(I, I_UPGRADE, "RestoreRamDisk")
        m["RestoreTrustCache"] = entry(I, I_UPGRADE, "RestoreTrustCache")
        return bi

    def identity_4():
        """Recovery — stripped down, iPhone Recovery OS."""
        bi = make_base()
        m = bi["Manifest"]
        boot_infra(m, boot_variant="research")
        for k in ("LLB", "RestoreDeviceTree", "RestoreSEP", "SEP",
                  "RecoveryMode", "iBoot"):
            m.pop(k, None)
        # AppleLogo only (no RestoreLogo for recovery)
        e = try_entry(C, RES, "AppleLogo")
        if e:
            m["AppleLogo"] = e
        m["RestoreRamDisk"]    = entry(C, PROD, "RestoreRamDisk")
        m["RestoreTrustCache"] = entry(C, PROD, "RestoreTrustCache")
        iphone_os(m, os_src=I_RECOVERY)
        return bi

    # ── Assemble BuildManifest ───────────────────────────────────────
    build_manifest = {
        "BuildIdentities": [
            identity_0(), identity_1(), identity_2(),
            identity_3(), identity_4(),
        ],
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
