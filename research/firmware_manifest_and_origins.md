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
| iPhone 26.0    | 5          | All d47ap                                               |
| iPhone 26.0.1  | 5          | All d47ap                                               |
| iPhone 26.1    | 5          | All d47ap                                               |
| iPhone 26.3    | 5          | All d47ap                                               |
| CloudOS 26.1   | 6          | j236cap, j475dap, vphone600ap (x2), vresearch101ap (x2) |
| KnownWork 26.1 | 5          | All vresearch101ap                                      |

26.0 and 26.0.1 have no matching public PCC vphone600 drop in this repo's tested set, so
it is prepared as iPhone 26.0 or 26.0.1 userspace plus the 26.1 PCC boot/runtime stack.
The 26.0 and 26.0.1 `IOMobileFramebuffer` dyld-cache patch in CFW install fixes the
only observed GUI ABI mismatch (`SwapEnd` payload size 0x548 -> 0x560).

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

---

## 9. DeviceTree identity rewrite

The vphone600ap DT carries 13 properties whose values contain the literals
`vphone600` / `VPHONE600` / `iPhone99,11` / `vmapple` / `vresearch`. Most are
load-bearing (kernel kext-matching, restore-time identity, IORegistry path
structure) and cannot be rewritten without breaking boot or restore.
`DeviceTreePatcher` rewrites the 8 that are either userland-facing identity
fields or SoC-generation descriptors with non-binding semantics.

| #  | Path                                                 | Property             | Original                                                  | Patched                                                  | Slot | Risk          |
|----|------------------------------------------------------|----------------------|-----------------------------------------------------------|----------------------------------------------------------|------|---------------|
| 2  | `device-tree`                                        | `target-sub-type`    | `"VPHONE600AP"`                                           | `"D47AP"`                                                | 12   | HIGHER        |
| 3  | `device-tree`                                        | `compatible[1]`      | secondary `"iPhone99,11"` (multi-string)                  | `"iPhone17,3"` (multi-string, primary `"VPHONE600AP"` preserved) | 48 | LOW |
| 10 | `device-tree/product`                                | `fdr-product-type`   | `"iPhone99,11"`                                           | `"iPhone17,3"`                                           | 12   | HIGHER        |
| 11 | `device-tree/product`                                | `sub-product-type`   | `"iPhone99,11"`                                           | `"iPhone17,3"`                                           | 12   | LOW           |
| 12 | `device-tree/product`                                | `unique-model`       | `"VPHONE600AP"`                                           | `"D47AP"`                                                | 12   | LOW           |
| 6  | `device-tree/arm-io`                                 | `device_type`        | `"vresearch1-io"`                                         | `"t8140-io"` (matches d47ap)                             | 14   | MEDIUM        |
| 7  | `device-tree/arm-io`                                 | `soc-generation`     | `"VResearch1"`                                            | `"H17"` (matches d47ap)                                  | 11   | MEDIUM-LOW    |
| 13 | `device-tree/product/vphone600-gestalt-variants`     | `name` (node name)   | `"vphone600-gestalt-variants"`                            | `"d47-gestalt-variants"`                                 | 27   | LOW-MEDIUM    |

**Properties intentionally left at vphone600 values** (with the empirical
reason for each):

- `device-tree.target-type` (`"VPHONE600"`) — Tier 2 attempt broke restore;
  iBoot / restored_external read this and reject the device when the value
  doesn't match the BuildManifest's signed identity.
- `device-tree.model` (`"iPhone99,11"`) — Tier 1 attempt broke restore;
  same reason as `target-type`.
- `device-tree.compatible[0]` (`"VPHONE600AP"`) — IOKit's platform-expert
  matching at boot binds against the FIRST entry of `compatible`. Rewriting
  it to `D47AP` forces `_PE_init_platform_expert` to look for a D47AP-claiming
  kext, which doesn't exist in our kernelcache. Panic guaranteed.
- `device-tree/arm-io.compatible` / `device_type` / `soc-generation`
  (vmapple1 / vresearch1-io / VResearch1) — bind the vmapple1 IO controller
  kext, GIC, and PCIe drivers. Rename → no kext claims the SoC IO → boot
  panic.
- `device-tree/arm-io/gic.compatible`, `device-tree/arm-io/pcie.compatible` —
  same family as arm-io entries.
- `device-tree/product/vphone600-gestalt-variants` (node name) — referenced
  by libMobileGestalt-equivalent code that looks up the subtree by literal
  node name. Rename breaks the lookup.

**Compatible multi-string surgical rewrite** (#3). The original blob is:

```
[0..10]  "VPHONE600AP"       (11 bytes)
[11]     NUL
[12..22] "iPhone99,11"       (11 bytes)
[23]     NUL
[24..46] "AppleVirtualPlatformARM" (23 bytes)
[47]     NUL
```

Patched (slot length preserved at 48):

```
[0..10]  "VPHONE600AP"        ← unchanged: platform-expert bind site
[11]     NUL
[12..21] "iPhone17,3"
[22]     NUL
[23..45] "AppleVirtualPlatformARM"
[46]     NUL
[47]     NUL (pad)
```

`AppleVirtualPlatformARM` shifts 1 byte earlier but every consumer walks
the blob by NUL-terminators, none depend on a fixed byte offset within
the property. IOKit's platform-expert match against `VPHONE600AP` (first
entry) is unaffected; the second entry, which userland walks of the
compatible[] list see when enumerating identifiers, now reports
`iPhone17,3`.

**Risk classification.**

- **LOW** (#3, #11, #12) — read only by userland identity APIs
  (libMobileGestalt, IORegistry queries, App Store device class).
  No iBoot / restored_external / TSS dependency.
- **HIGHER** (#2, #10) — `target-sub-type` is in the same restore-signed
  family as `target-type` (already proven to break restore);
  `fdr-product-type` is read by Factory-Data-Restore code paths that may
  check it against the BuildManifest. If restore fails after a build that
  enables these, remove them first and try the remaining LOW-risk three
  in isolation.

Wiring: all 5 patches are declared in
`sources/FirmwarePatcher/DeviceTree/DeviceTreePatcher.swift` under
`propertyPatches`. The serializer rebuilds the entire tree on every run,
so each new value is written at the same slot length as the original.
The `compatible` patch uses a new `PropertyValue.bytes(Data)` case that
takes a pre-built byte blob (necessary because the multi-string layout
contains embedded NULs).

## 10. Post-restore DT identity rewrite (EXP-JB-6)

The properties under "known-bad from prior rounds" (root `model`, root
`target-type`) cannot be edited at fw_patch time because
`restored_external` / iBoot's restore mode cross-checks them against the
BuildManifest's signed `SupportedProductTypes`. But that cross-check
fires **only during installation**. After restore completes, the boot
path is

```
AVPBooter (patched)
   → iBSS / iBEC (image4_validate_property_callback bypass patches)
   → LLB (image4 bypass + rootfs bypass patches)
   → iBoot (research) → DT loaded from disk
   → kernel → sysctls populated from DT
```

The image4 bypass patches we already ship are what allow every
fw_patch-time IM4P modification to boot at all — they make the IM4M's
stored digest irrelevant on subsequent boots. So an additional IM4P
modification applied **after** restore completes is in-policy with the
project's existing trust-chain bypass.

The **EXP-JB-6** install step exploits this (in `cfw_install_exp.sh`
only — JB and DEV variants do NOT run it). While the install pipeline
still has `/mnt5` (the preboot volume) mounted in ramdisk mode, it:

1. Pulls `/mnt5/<boot-hash>/usr/standalone/firmware/devicetree.img4` to
   the host.
2. Runs `scripts/patchers/cfw_patch_post_restore_dt.py`, which:
   - Unwraps img4 → IM4P → decompresses LZFSE → DT blob (via pyimg4).
   - Applies the three restore-unsafe edits (table below).
   - Re-compresses LZFSE → repacks IM4P → repacks IMG4 with the original
     IM4M.
3. Pushes the modified img4 back to the same path.
4. The device reboots out of ramdisk; iBoot loads the modified DT;
   kernel populates `machine_info` from the new property values.

| Property                  | Before (post-Tier-1b state on disk)                                       | After (EXP-JB-6 rewrites to)                                            | Slot |
|---------------------------|---------------------------------------------------------------------------|-------------------------------------------------------------------------|------|
| `device-tree.model`       | `"iPhone99,11"`                                                           | `"iPhone17,3"`                                                          | 12   |
| `device-tree.target-type` | `"VPHONE600"`                                                             | `"D47"`                                                                 | 10   |
| `device-tree.compatible`  | `["VPHONE600AP", "iPhone17,3", "AppleVirtualPlatformARM"]` (post-Tier-1b) | `["D47AP", "VPHONE600AP", "AppleVirtualPlatformARM"]` (reordered)       | 48   |

The `compatible` rewrite is a **reorder**, not a replacement: VPHONE600AP
stays in the list (now as the second entry), so IOKit's platform-expert
match against the AppleVMApple1IO kext still binds. `compatible[0]`
becomes D47AP, which is what userland's `hw.model` resolves to.

Userland-visible effects after the next boot:

- `sysctl hw.machine` → `"iPhone17,3"` (was `"iPhone99,11"`)
- `sysctl hw.product` → `"iPhone17,3"` (was `"iPhone99,11"`)
- `sysctl hw.model`   → `"D47AP"`      (was `"VPHONE600AP"`)
- Settings → General → About → Model Identifier reflects the new
  ProductType.
- Every `MGCopyAnswer` key backed by `IOPlatformExpertDevice` properties
  picks up the new values.

Idempotence: the patcher reads the existing DT, applies edits, and
writes back only if there's a difference. A second run on an
already-patched devicetree.img4 detects target-state-already-met and
exits without rewriting.

Wiring:

* `scripts/patchers/cfw_patch_post_restore_dt.py` — host-side patcher.
  Uses pyimg4 for img4↔IM4P+LZFSE round-trip; mirrors the DT format
  parser/serializer from `DeviceTreePatcher.swift`.
* `scripts/cfw_install_exp.sh [EXP-JB-6]` — install step that runs after
  JB-5 (LaunchDaemon deploy) and before the CLEANUP/umount block, in the
  EXP install script only. Discovers the boot-manifest-hash via the same
  `get_boot_manifest_hash` helper used by earlier install steps. Tolerates
  a missing devicetree.img4 with warn-and-skip rather than aborting the
  install. JB and DEV install scripts do NOT carry this step.

Why this is restore-safe (and the fw_patch-time version was not):

- **fw_patch-time path** modifies the IM4P bytes that are sent during
  restore. iBoot's restore mode reads each IM4P and (via the image4
  validation callback the iBSS/iBEC/LLB patches already neuter) accepts
  its digest mismatch — but some other path inside `restored_external`
  enforces the top-level `SupportedProductTypes` check independently and
  rejects DT.model values that don't appear in that list.
- **EXP-JB-6 post-restore path** never re-runs the BuildManifest check.
  Subsequent boots validate IM4P contents against the IM4M only — which
  the image4 bypass patches already wave through. So the same byte
  change that's fatal at restore is harmless after restore.

## 11. Build-version rewrite (EXP-JB-7, opt-in)

**Opt-in step**. EXP-JB-7 runs only when the `SPOOF_BUILD` environment
variable is set — e.g. `make setup_machine EXP=1 SPOOF_BUILD=23F77`, or
`make cfw_install_exp SPOOF_BUILD=23F77` if you're re-running just the
CFW phase. When omitted/empty the step is skipped entirely and the
build identifier stays at whatever the IPSW shipped. Only the EXP
install script runs this step; JB and DEV variants are not affected.

The iPhone IPSW we install from ships with build identifier `23B85` (iOS
26.1). iOS displays this string in Settings → General → About → "Build"
and exposes it through `MGCopyAnswer("BuildVersion")`, `CoreFoundation`'s
`_CFCopyServerVersionDictionary`, App Store telemetry, and every other
framework path that reads `/System/Library/CoreServices/SystemVersion.plist`.

The build identifier lives in exactly two on-device plist files. Both
are plain XML/binary plists (no Apple-side per-file signature), and
both live on volumes that are writable at install time:

| Path                                                                                | Volume       | Role                                                                 |
|-------------------------------------------------------------------------------------|--------------|----------------------------------------------------------------------|
| `/System/Library/CoreServices/SystemVersion.plist`                                  | rootfs       | The canonical source. Read by every userland identity API.           |
| `/private/preboot/Cryptexes/OS/System/Library/CoreServices/SystemVersion.plist`     | preboot      | Cryptex-side copy. Read by Cryptex-aware OS-version queries.         |

The **EXP-JB-7** install step rewrites the `ProductBuildVersion` key in both
plists to a target value (currently `23F77`):

```
ProductBuildVersion: "23B85" → "23F77"
```

`ProductVersion` (`26.1`), `ProductName` (`iPhone OS`), `BuildID`,
`SystemImageID`, and `ProductCopyright` are left untouched.

Wiring:

* `scripts/patchers/cfw_patch_build_version.py` — host-side plistlib-based
  rewriter. Auto-detects XML vs binary plist format and preserves it on
  write. Idempotent — a re-run on an already-patched plist exits without
  rewriting.
* `scripts/cfw_install_exp.sh [EXP-JB-7]` — install step that runs after
  EXP-JB-6 (post-restore DT) and before CLEANUP, in the EXP install script
  only. For each of the two plist paths it scp_from's the file to host,
  runs the patcher with target `23F77`, scp_to's the file back. Tolerates
  missing-on-device with warn+continue. JB and DEV install scripts do NOT
  carry this step.

What this **does not** flip:

- `sysctl kern.osversion` — populated at boot from a kernel global
  initialized from boot args, not from `SystemVersion.plist`. The kernel
  image we ship was built against `23B78` (the PCC vphone600 /
  vresearch101 build identifier; visible in 621 kext-Info.plist
  embedded `DTPlatformBuild` / `DTSDKBuild` blobs inside the kernelcache
  but never read by `kern.osversion` at runtime). To flip
  `kern.osversion` we'd need to either rebuild the kernelcache with a
  different `OS_BUILD_VERSION` or patch the kernel boot args path — out
  of scope for this round.
- `SystemVersionCompat.plist` — carries `23B34a` / `19.1`, a legacy
  iOS-19 marker for `MacCatalyst`-style version queries. Not user-
  visible, deliberately untouched.
- DSC dylib internals — the apparent `23B85` byte sequence in DSC chunk
  `.21` is a Swift mangled-name UUID-uniquing substring
  (`_TtC11MediaCoreUIP33_98519F523B8515A67EEFBCB0824D82807Counter`), not
  a build identifier. Patching it would corrupt a Swift symbol name.

Order of operations: this step runs **after** EXP-JB-6 (the DT identity
rewrite) so that any post-restore identity work targeting `/mnt5` has
completed before we modify the Cryptex's SystemVersion.plist (which
lives on the same volume).
