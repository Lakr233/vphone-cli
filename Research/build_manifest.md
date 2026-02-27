
# BuildManifest.plist Research

## 1. Multi-Source Comparison

### Identity Count Overview

| Source | Identities | DeviceClasses |
|--------|-----------|---------------|
| iPhone 26.1 | 5 | All d47ap |
| iPhone 26.3 | 5 | All d47ap |
| CloudOS 26.1 | 6 | j236cap, j475dap, vphone600ap (x2), vresearch101ap (x2) |
| KnownWork 26.1 | 5 | All vresearch101ap |

### CloudOS 26.1 Identity Structure (6 identities)

| Index | DeviceClass | Variant | BuildStyle | Manifest Keys |
|-------|-------------|---------|------------|---------------|
| [0] | j236cap | Darwin Cloud Customer Erase Install (IPSW) | LLB/iBSS/iBEC -> release | 37 keys (server hardware) |
| [1] | j475dap | Darwin Cloud Customer Erase Install (IPSW) | unknown (no path) | 0 keys (empty placeholder) |
| [2] | vphone600ap | Darwin Cloud Customer Erase Install (IPSW) | RELEASE build | 29 keys (includes UI assets) |
| [3] | vresearch101ap | Darwin Cloud Customer Erase Install (IPSW) | RELEASE build | 20 keys (no UI assets) |
| [4] | vphone600ap | Research Darwin Cloud Customer Erase Install (IPSW) | RESEARCH_RELEASE build | 29 keys (research kernel) |
| [5] | vresearch101ap | Research Darwin Cloud Customer Erase Install (IPSW) | RESEARCH_RELEASE build | 20 keys (research kernel) |

Key distinctions:
- CloudOS[2] vs [4] (vphone600ap): [2] uses RELEASE boot chain + release kernelcache; [4] uses RESEARCH_RELEASE + research kernelcache + txm.iphoneos.research.im4p
- CloudOS[3] vs [5] (vresearch101ap): Same pattern — [3] is RELEASE, [5] is RESEARCH_RELEASE
- vphone600ap identities have 29 keys (includes UI: AppleLogo, Battery*, RecoveryMode, RestoreLogo)
- vresearch101ap identities have 20 keys (no UI assets)

### iPhone 26.1 vs 26.3 Comparison

Both have identical identity structure (5 identities, all d47ap):
- [0] Customer Erase Install (103 keys)
- [1] Customer Upgrade Install (103 keys)
- [2] Research Customer Erase Install (103 keys)
- [3] Research Customer Upgrade Install (103 keys)
- [4] Recovery Customer Install (30 keys)

Only DMG filename numbers changed between 26.1 and 26.3 — no structural key additions or removals.

---

## 2. Component Source Tracing

### Boot Chain Components (from CloudOS)

| Component | Path Pattern | Primary CloudOS Source |
|-----------|-------------|----------------------|
| LLB | LLB.vresearch101.RELEASE.im4p | CloudOS[2]/[3] (non-research) |
| LLB | LLB.vresearch101.RESEARCH_RELEASE.im4p | CloudOS[4]/[5] (research) |
| iBSS | iBSS.vresearch101.RELEASE.im4p | CloudOS[2]/[3] |
| iBEC | iBEC.vresearch101.RELEASE.im4p | CloudOS[2]/[3] |
| iBoot | iBoot.vresearch101.RESEARCH_RELEASE.im4p | CloudOS[4]/[5] only |
| DeviceTree | DeviceTree.vphone600ap.im4p | CloudOS[2]/[4] |
| KernelCache | kernelcache.research.vphone600 | CloudOS[4] only |
| RestoreKernelCache | kernelcache.release.vphone600 | CloudOS[2]/[4] |
| SEP/RestoreSEP | sep-firmware.vresearch101.RELEASE.im4p | CloudOS[3]/[5] |
| SPTM | sptm.vresearch1.release.im4p | CloudOS[2]/[3]/[4]/[5] |
| TXM (research) | txm.iphoneos.research.im4p | CloudOS[4]/[5] |

### OS & Data DMGs (from iPhone IPSW)

| Component | Path | Source |
|-----------|------|--------|
| OS | 043-53486-120.dmg.aea | iPhone26.1[0-3] |
| Ap,SystemVolumeCanonicalMetadata | 043-53486-120.dmg.aea.mtree | iPhone26.1[0-3] |
| StaticTrustCache | 043-53486-120.dmg.aea.trustcache | iPhone26.1[0-3] |
| SystemVolume | 043-53486-120.dmg.aea.root_hash | iPhone26.1[0-3] |

### Cryptex1 Components (from iPhone IPSW only)

| Component | Path | Source |
|-----------|------|--------|
| Cryptex1,AppOS | 043-54062-129.dmg | iPhone26.1[0-3] |
| Cryptex1,SystemOS | 043-54303-126.dmg.aea | iPhone26.1[0-3] |

### Key Universe Summary
- 115 total unique Manifest keys across all sources
- 63 keys are iPhone-only (hardware-specific)
- 23 keys are shared across all 4 sources (core boot/restore chain)
- 12 keys are CloudOS-only (server hardware)
- 6 keys are in KnownWork + iPhone only (Cryptex1 entries)

---

## 3. idevicerestore Identity Selection Logic

Source: `idevicerestore/src/idevicerestore.c` lines 2195-2242

### Matching Algorithm

idevicerestore selects a Build Identity by iterating through all `BuildIdentities` and returning the **first match** based on two fields:

1. **`Info.DeviceClass`** — case-insensitive match against device `hardware_model`
2. **`Info.Variant`** — substring match against the requested variant string

For DFU erase restore, the search variant is `"Erase Install (IPSW)"` (defined in `idevicerestore.h`).

### Matching Modes

```c
// Exact match
if (strcmp(str, variant) == 0) return ident;

// Partial match (when exact=0)
if (strstr(str, variant) && !strstr(str, "Research")) return ident;
```

**Critical**: Partial matching **excludes** variants containing `"Research"`. This means:
- `"Darwin Cloud Customer Erase Install (IPSW)"` — matches (contains "Erase Install (IPSW)", no "Research")
- `"Research Darwin Cloud Customer Erase Install (IPSW)"` — skipped (contains "Research")

### What idevicerestore Does NOT Check
- ApBoardID / ApChipID (used after selection, not for matching)
- Identity index or count (no hardcoded indices)
- `build_manifest_get_identity_count()` exists but is never called

### Conclusion for Single Identity

A BuildManifest with **one identity** works fine:
- The loop iterates once (i=0)
- If DeviceClass and Variant match, it's returned
- No minimum identity count required

---

## 4. Final Design: Single DFU Erase Identity

Since vphone-cli always boots via DFU restore (never upgrade/recovery), the BuildManifest is simplified to a single Build Identity.

### Identity Composition

| Component | Source | Rationale |
|-----------|--------|-----------|
| LLB / iBSS / iBEC | PROD (RELEASE) | patch_firmware.py patches RELEASE variants first |
| iBoot | RES (RESEARCH) | Only research identity carries iBoot |
| KernelCache | PROD (RELEASE) | Release kernel — smaller, cleaner base for patching |
| RestoreKernelCache | PROD (RELEASE) | Same release kernel |
| TXM | RES (research) | patch_firmware.py patches txm.iphoneos.research.im4p |
| SPTM (all 4 entries) | PROD | RELEASE monitors |
| SEP / RestoreSEP | PROD | RELEASE SEP firmware |
| DeviceTree / RestoreDeviceTree | PROD | Device hardware description |
| RestoreRamDisk | PROD (cloudOS) | CloudOS erase ramdisk |
| OS / SystemVolume / etc. | iPhone erase | iPhone system image |
| Cryptex1,* | iPhone erase | install_cfw.sh reads DMG paths from these |

### Identity Metadata
```
DeviceClass     = vresearch101ap
Variant         = Darwin Cloud Customer Erase Install (IPSW)
Ap,ProductType  = ComputeModule14,2
Ap,Target       = VRESEARCH101AP
ApBoardID       = 0x90
ApChipID        = 0xFE01
FDRSupport      = False
```

### Removed Identities

| Former Identity | Why Removed |
|----------------|-------------|
| Upgrade (RESEARCH boot, iPhone upgrade ramdisk) | VM never upgrades — always fresh DFU erase |
| Research erase (RESEARCH boot, no Cryptex1) | Merged into single identity with RELEASE boot |
| Research upgrade | VM never upgrades |
| Recovery | VM never enters recovery mode |

### Corresponding patch_firmware.py Change

Kernel search order updated to prioritize release kernel:
```
kernelcache.release.vphone600      ← NEW: matches BuildManifest
kernelcache.release.vresearch101
kernelcache.release.v*
kernelcache.research.vphone600     ← fallback
kernelcache*
```

This ensures the file patch_firmware.py patches is the same file the BuildManifest references.
