# BuildManifest.plist Research

## 1. Multi-Source Comparison

### Identity Count Overview

| Source         | Identities | DeviceClasses                                           |
| -------------- | ---------- | ------------------------------------------------------- |
| iPhone 26.1    | 5          | All d47ap                                               |
| iPhone 26.3    | 5          | All d47ap                                               |
| CloudOS 26.1   | 6          | j236cap, j475dap, vphone600ap (x2), vresearch101ap (x2) |
| KnownWork 26.1 | 5          | All vresearch101ap                                      |

### CloudOS 26.1 Identity Structure (6 identities)

| Index | DeviceClass    | Variant                                             | BuildStyle             | Manifest Keys                |
| ----- | -------------- | --------------------------------------------------- | ---------------------- | ---------------------------- |
| [0]   | j236cap        | Darwin Cloud Customer Erase Install (IPSW)          | RELEASE build          | 37 keys (server hardware)    |
| [1]   | j475dap        | Darwin Cloud Customer Erase Install (IPSW)          | unknown (no path)      | 0 keys (empty placeholder)   |
| [2]   | vphone600ap    | Darwin Cloud Customer Erase Install (IPSW)          | RELEASE build          | 29 keys (includes UI assets) |
| [3]   | vresearch101ap | Darwin Cloud Customer Erase Install (IPSW)          | RELEASE build          | 20 keys (no UI assets)       |
| [4]   | vphone600ap    | Research Darwin Cloud Customer Erase Install (IPSW) | RESEARCH_RELEASE build | 29 keys (research kernel)    |
| [5]   | vresearch101ap | Research Darwin Cloud Customer Erase Install (IPSW) | RESEARCH_RELEASE build | 20 keys (research kernel)    |

Key distinctions:

- CloudOS[2] vs [4] (vphone600ap): [2] uses RELEASE boot chain + release kernelcache; [4] uses RESEARCH_RELEASE + research kernelcache + txm.iphoneos.research.im4p
- CloudOS[3] vs [5] (vresearch101ap): Same pattern — [3] is RELEASE, [5] is RESEARCH_RELEASE
- **vphone600ap has components vresearch101ap lacks**: RecoveryMode, AppleLogo, Battery\*, RestoreLogo, SEP (vphone600 variant)
- vresearch101ap has only 20 manifest keys (no UI assets, no RecoveryMode)

### vphone600ap vs vresearch101ap Key Differences

| Property       | vphone600ap                         | vresearch101ap                         |
| -------------- | ----------------------------------- | -------------------------------------- |
| Ap,ProductType | iPhone99,11                         | ComputeModule14,2                      |
| Ap,Target      | VPHONE600AP                         | VRESEARCH101AP                         |
| ApBoardID      | 0x91                                | 0x90                                   |
| DeviceTree     | DeviceTree.vphone600ap.im4p         | DeviceTree.vresearch101ap.im4p         |
| SEP            | sep-firmware.vphone600.RELEASE.im4p | sep-firmware.vresearch101.RELEASE.im4p |
| RecoveryMode   | recoverymode@2556~iphone-USBc.im4p  | **NOT PRESENT**                        |
| MKB dt flag    | dt=1 (keybag-less boot OK)          | dt=0 (fatal keybag error)              |

---

## 2. Component Source Tracing (Corrected)

### Hybrid Identity: vresearch101 boot chain + vphone600 runtime

The working configuration mixes components from both board configs:

| Component                        | Source Identity              | File                                       | Why This Source                  |
| -------------------------------- | ---------------------------- | ------------------------------------------ | -------------------------------- |
| LLB                              | PROD (vresearch101 release)  | `LLB.vresearch101.RELEASE.im4p`            | Matches DFU hardware (BDID 0x90) |
| iBSS                             | PROD                         | `iBSS.vresearch101.RELEASE.im4p`           | Matches DFU hardware             |
| iBEC                             | PROD                         | `iBEC.vresearch101.RELEASE.im4p`           | Matches DFU hardware             |
| iBoot                            | RES (vresearch101 research)  | `iBoot.vresearch101.RESEARCH_RELEASE.im4p` | Only research identity has iBoot |
| SPTM (all)                       | PROD                         | `sptm.vresearch1.release.im4p`             | Shared across board configs      |
| TXM restore                      | PROD                         | `txm.iphoneos.release.im4p`                | RELEASE for restore              |
| TXM installed                    | RES                          | `txm.iphoneos.research.im4p`               | Research variant, patched        |
| **DeviceTree/RestoreDeviceTree** | **VP (vphone600 release)**   | `DeviceTree.vphone600ap.im4p`              | Sets MKB dt=1                    |
| **SEP/RestoreSEP**               | **VP**                       | `sep-firmware.vphone600.RELEASE.im4p`      | Must match device tree           |
| **KernelCache**                  | **VPR (vphone600 research)** | `kernelcache.research.vphone600`           | Patched by fw_patch.py           |
| **RestoreKernelCache**           | **VP (vphone600 release)**   | `kernelcache.release.vphone600`            | Unpatched, restore-time only     |
| **RecoveryMode**                 | **VP**                       | `recoverymode@2556~iphone-USBc.im4p`       | Only vphone600ap has it          |
| RestoreRamDisk/RestoreTrustCache | PROD                         | cloudOS erase ramdisk/trustcache           | PCC restore ramdisk              |
| OS / SVC / etc.                  | I_ERASE (iPhone)             | iPhone OS image                            | iPhone system                    |

### Why Not All-vresearch101 or All-vphone600?

**Problem with all-vresearch101**: The vresearch101ap device tree sets MKB `dt=0`,
causing `MKB_INIT: FATAL KEYBAG ERROR` on first boot (no system keybag exists yet).
Also missing RecoveryMode entry.

**Problem with all-vphone600**: The DFU hardware identifies as BDID 0x90
(vresearch101ap). Using vphone600ap identity (BDID 0x91) fails TSS/SHSH signing
and idevicerestore identity matching (`Unable to find a matching build identity`).

**Solution**: vresearch101ap identity fields for DFU/TSS + vphone600 runtime
components for a working boot environment.

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

### Conclusion for Single Identity

A BuildManifest with **one identity** works fine. The loop iterates once, and if
DeviceClass and Variant match, it's returned. No minimum identity count required.

---

## 4. TSS/SHSH Signing

The TSS request sent to `gs.apple.com` includes:

- `ApBoardID = 144` (0x90) — must match vresearch101ap
- `ApChipID = 65025` (0xFE01)
- `Ap,ProductType = ComputeModule14,2`
- `Ap,Target = VRESEARCH101AP`
- Digests for all 21 manifest components

Apple's TSS server signs based on these identity fields + component digests.
Using vphone600ap identity (BDID 0x91) would fail because the DFU device
reports BDID 0x90.

---

## 5. Final Design: Single DFU Erase Identity

### Identity Metadata (fw_manifest.py)

```
DeviceClass     = vresearch101ap    (from C[PROD] deep copy)
Variant         = Darwin Cloud Customer Erase Install (IPSW)
Ap,ProductType  = ComputeModule14,2
Ap,Target       = VRESEARCH101AP
Ap,TargetType   = vresearch101
ApBoardID       = 0x90
ApChipID        = 0xFE01
ApSecurityDomain = 0x01
FDRSupport      = False
```

### Source Variable Map

```
PROD = C[vresearch101ap release]   — boot chain, SPTM, RestoreTXM, ramdisk, RestoreTrustCache
RES  = C[vresearch101ap research]  — iBoot, TXM research
VP   = C[vphone600ap release]      — DeviceTree, RestoreDeviceTree, SEP, RestoreSEP, RestoreKernelCache, RecoveryMode
VPR  = C[vphone600ap research]     — KernelCache (patched by fw_patch.py)
I_ERASE = I[iPhone erase]          — OS, trust caches, system volume
```

### All 21 Manifest Entries

```
Boot chain (PROD):           LLB, iBSS, iBEC
Research iBoot (RES):        iBoot
Security monitors (PROD):   Ap,RestoreSPTM, Ap,RestoreTXM, Ap,SPTM
Research TXM (RES):          Ap,TXM
Device tree (VP):            DeviceTree, RestoreDeviceTree
SEP (VP):                    SEP, RestoreSEP
Kernel (VPR/VP):             KernelCache (research), RestoreKernelCache (release)
Recovery (VP):               RecoveryMode
Ramdisk (PROD):              RestoreRamDisk, RestoreTrustCache
iPhone OS (I_ERASE):         OS, StaticTrustCache, SystemVolume, Ap,SVC Metadata
```

### Restore.plist

```
DeviceMap:     [d47ap (iPhone), vphone600ap, vresearch101ap]
ProductTypes:  [iPhone17,3, ComputeModule14,1, ComputeModule14,2, Mac14,14, iPhone99,11]
```
