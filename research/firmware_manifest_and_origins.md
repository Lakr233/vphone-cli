# Firmware Manifest & Component Origins

The erase install firmware is a **hybrid** of three source sets:

1. **PCC vresearch101ap** — boot chain (LLB/iBSS/iBEC/iBoot) and security monitors (SPTM/TXM)
2. **PCC vphone600ap** — runtime components (DeviceTree, SEP, KernelCache, RecoveryMode)
3. **iPhone 17,3** — OS image, trust caches, filesystem

The VM hardware identifies as **vresearch101ap** (BDID 0x90) in DFU mode, so the
BuildManifest identity must use vresearch101ap fields for TSS/SHSH signing. However,
runtime components use the **vphone600** variant because its DeviceTree sets MKB `dt=1`
(allows boot without system keybag), its SEP firmware matches the vphone600 device tree,
and `hardware target` reports as `vphone600ap` for proper iPhone emulation.

`fw_prepare.sh` downloads both IPSWs, merges cloudOS firmware into the iPhone
restore directory, then `fw_manifest.py` generates the hybrid BuildManifest.

---

## 1. Multi-Source IPSW Comparison

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

## 2. Component Source Tracing

### Boot Chain (from PCC vresearch101ap)

| Component     | Source Identity               | File                                                          | Patches Applied                                                          |
| ------------- | ----------------------------- | ------------------------------------------------------------- | ------------------------------------------------------------------------ |
| **AVPBooter** | PCC vresearch1                | `AVPBooter*.bin` (vm dir)                                     | DGST validation bypass (`mov x0, #0`)                                    |
| **iBSS**      | PROD (vresearch101ap release) | `Firmware/dfu/iBSS.vresearch101.RELEASE.im4p`                 | Serial labels + image4 callback bypass                                   |
| **iBEC**      | PROD (vresearch101ap release) | `Firmware/dfu/iBEC.vresearch101.RELEASE.im4p`                 | Serial labels + image4 callback + boot-args                              |
| **LLB**       | PROD (vresearch101ap release) | `Firmware/all_flash/LLB.vresearch101.RELEASE.im4p`            | Serial labels + image4 callback + boot-args + rootfs + panic (6 patches) |
| **iBoot**     | RES (vresearch101ap research) | `Firmware/all_flash/iBoot.vresearch101.RESEARCH_RELEASE.im4p` | Not patched (only research identity carries iBoot)                       |

### Security Monitors (from PCC, shared across board configs)

| Component                             | Source Identity | File                                    | Patches Applied                             |
| ------------------------------------- | --------------- | --------------------------------------- | ------------------------------------------- |
| **Ap,RestoreSecurePageTableMonitor**  | PROD            | `Firmware/sptm.vresearch1.release.im4p` | Not patched                                 |
| **Ap,RestoreTrustedExecutionMonitor** | PROD            | `Firmware/txm.iphoneos.release.im4p`    | Not patched                                 |
| **Ap,SecurePageTableMonitor**         | PROD            | `Firmware/sptm.vresearch1.release.im4p` | Not patched                                 |
| **Ap,TrustedExecutionMonitor**        | RES (research)  | `Firmware/txm.iphoneos.research.im4p`   | Trustcache bypass (`mov x0, #0` at 0x2C1F8) |

### Runtime Components (from PCC vphone600ap)

| Component              | Source Identity            | File                                                     | Patches Applied                        |
| ---------------------- | -------------------------- | -------------------------------------------------------- | -------------------------------------- |
| **DeviceTree**         | VP (vphone600ap release)   | `Firmware/all_flash/DeviceTree.vphone600ap.im4p`         | Not patched                            |
| **RestoreDeviceTree**  | VP                         | `Firmware/all_flash/DeviceTree.vphone600ap.im4p`         | Not patched                            |
| **SEP**                | VP                         | `Firmware/all_flash/sep-firmware.vphone600.RELEASE.im4p` | Not patched                            |
| **RestoreSEP**         | VP                         | `Firmware/all_flash/sep-firmware.vphone600.RELEASE.im4p` | Not patched                            |
| **KernelCache**        | VPR (vphone600ap research) | `kernelcache.research.vphone600`                         | 25 dynamic patches via KernelPatcher   |
| **RestoreKernelCache** | VP (vphone600ap release)   | `kernelcache.release.vphone600`                          | Not patched (used during restore only) |
| **RecoveryMode**       | VP                         | `Firmware/all_flash/recoverymode@2556~iphone-USBc.im4p`  | Not patched                            |

> **Important**: KernelCache (installed to disk, patched) uses the **research** variant.
> RestoreKernelCache (used during restore process only) uses the **release** variant.
> Only vphone600ap identities carry RecoveryMode — vresearch101ap does not.

### OS / Filesystem (from iPhone)

| Component                            | Source                             | Notes              |
| ------------------------------------ | ---------------------------------- | ------------------ |
| **OS**                               | iPhone `iPhone17,3` erase identity | iPhone OS image    |
| **SystemVolume**                     | iPhone erase                       | Root hash          |
| **StaticTrustCache**                 | iPhone erase                       | Static trust cache |
| **Ap,SystemVolumeCanonicalMetadata** | iPhone erase                       | Metadata / mtree   |

### Ramdisk (from PCC)

| Component             | Source                        | Notes                 |
| --------------------- | ----------------------------- | --------------------- |
| **RestoreRamDisk**    | PROD (vresearch101ap release) | CloudOS erase ramdisk |
| **RestoreTrustCache** | PROD                          | Ramdisk trust cache   |

---

## 3. Why the Hybrid Approach

### Why Not All-vresearch101?

The vresearch101ap device tree sets MKB `dt=0`, causing a **fatal keybag error** during boot:

```
MKB_INIT: dt = 0, bootarg = 0
MKB_INIT: FATAL KEYBAG ERROR: failed to load system bag
REBOOTING INTO RECOVERY MODE.
```

Also missing the RecoveryMode entry.

### Why Not All-vphone600?

The DFU hardware identifies as BDID 0x90 (vresearch101ap). Using vphone600ap identity
(BDID 0x91) fails TSS/SHSH signing and idevicerestore identity matching
(`Unable to find a matching build identity`).

### Solution

vresearch101ap identity fields for DFU/TSS + vphone600 runtime components for a working
boot environment. The vphone600ap device tree sets `dt=1`, allowing boot without a
pre-existing system keybag:

```
MKB_INIT: dt = 1, bootarg = 0
MKB_INIT: No system keybag loaded.
```

The SEP firmware must match the device tree (vphone600 SEP with vphone600 DT).

---

## 4. Patched Components Summary

All 6 patched components in `fw_patch.py` come from **PCC (cloudOS)**:

| #   | Component   | Source Board      | Patch Count | Purpose                                                    |
| --- | ----------- | ----------------- | ----------- | ---------------------------------------------------------- |
| 1   | AVPBooter   | vresearch1        | 1           | Bypass DGST signature validation                           |
| 2   | iBSS        | vresearch101      | 2           | Enable serial output + bypass image4 verification          |
| 3   | iBEC        | vresearch101      | 3           | Enable serial + bypass image4 + inject boot-args           |
| 4   | LLB         | vresearch101      | 6           | Serial + image4 + boot-args + rootfs mount + panic handler |
| 5   | TXM         | shared (iphoneos) | 1           | Bypass trustcache validation                               |
| 6   | KernelCache | vphone600         | 25          | APFS seal, MAC policy, debugger, launch constraints, etc.  |

All 4 CFW-patched binaries in `patchers/cfw.py` / `cfw_install.sh` come from **iPhone**:

| #   | Binary               | Source                    | Purpose                                                     |
| --- | -------------------- | ------------------------- | ----------------------------------------------------------- |
| 1   | seputil              | iPhone (Cryptex SystemOS) | Gigalocker UUID patch (`/%s.gl` → `/AA.gl`)                 |
| 2   | launchd_cache_loader | iPhone (Cryptex SystemOS) | NOP cache validation check                                  |
| 3   | mobileactivationd    | iPhone (Cryptex SystemOS) | Force `should_hactivate` to return true                     |
| 4   | launchd.plist        | iPhone (Cryptex SystemOS) | Inject bash/dropbear/trollvnc/vphoned/rpcserver_ios daemons |

---

## 5. idevicerestore Identity Selection

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

## 6. TSS/SHSH Signing

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

## 7. Final Design: Single DFU Erase Identity

Since vphone-cli always boots via DFU restore, only one Build Identity is needed.

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

### Full Manifest Component List

```
LLB                              ← PROD
iBSS                             ← PROD
iBEC                             ← PROD
iBoot                            ← RES
Ap,RestoreSecurePageTableMonitor ← PROD
Ap,RestoreTrustedExecutionMonitor← PROD
Ap,SecurePageTableMonitor        ← PROD
Ap,TrustedExecutionMonitor       ← RES
DeviceTree                       ← VP
RestoreDeviceTree                ← VP
SEP                              ← VP
RestoreSEP                       ← VP
KernelCache                      ← VPR  (research, patched)
RestoreKernelCache               ← VP   (release, unpatched)
RecoveryMode                     ← VP
RestoreRamDisk                   ← PROD
RestoreTrustCache                ← PROD
Ap,SystemVolumeCanonicalMetadata ← I_ERASE
OS                               ← I_ERASE
StaticTrustCache                 ← I_ERASE
SystemVolume                     ← I_ERASE
```

---

## 8. Restore.plist

```
DeviceMap:     [d47ap (iPhone), vphone600ap, vresearch101ap]
ProductTypes:  [iPhone17,3, ComputeModule14,1, ComputeModule14,2, Mac14,14, iPhone99,11]
```

---

## TL;DR

**Boot chain = vresearch101 (matches DFU hardware); runtime = vphone600 (keybag-less boot); OS = iPhone.**

The firmware is a PCC shell wrapping an iPhone core. The vresearch101 boot chain
handles DFU/TSS signing. The vphone600 device tree + SEP + kernel provide the
runtime environment. The iPhone userland is patched post-install for activation
bypass, jailbreak tools, and persistent SSH/VNC.
