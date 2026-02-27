# Erase Install — Component Origins

The erase install firmware is a **hybrid** of three source sets:

1. **PCC vresearch101ap** — boot chain (LLB/iBSS/iBEC/iBoot) and security monitors (SPTM/TXM)
2. **PCC vphone600ap** — runtime components (DeviceTree, SEP, KernelCache, RecoveryMode)
3. **iPhone 17,3** — OS image, trust caches, filesystem

The VM hardware identifies as **vresearch101ap** (BDID 0x90) in DFU mode, so the
BuildManifest identity must use vresearch101ap fields for TSS/SHSH signing. However,
runtime components use the **vphone600** variant because:
- Its DeviceTree sets MKB `dt=1` (allows boot without system keybag)
- Its SEP firmware matches the vphone600 device tree
- `hardware target` reports as `vphone600ap` → proper iPhone emulation

`fw_prepare.sh` downloads both IPSWs, merges cloudOS firmware into the iPhone
restore directory, then `fw_manifest.py` generates the hybrid BuildManifest.

---

## Component Source Table

### Boot Chain (from PCC vresearch101ap)

| Component | Source Identity | File | Patches Applied |
|-----------|---------------|------|-----------------|
| **AVPBooter** | PCC vresearch1 | `AVPBooter*.bin` (vm dir) | DGST validation bypass (`mov x0, #0`) |
| **iBSS** | PROD (vresearch101ap release) | `Firmware/dfu/iBSS.vresearch101.RELEASE.im4p` | Serial labels + image4 callback bypass |
| **iBEC** | PROD (vresearch101ap release) | `Firmware/dfu/iBEC.vresearch101.RELEASE.im4p` | Serial labels + image4 callback + boot-args |
| **LLB** | PROD (vresearch101ap release) | `Firmware/all_flash/LLB.vresearch101.RELEASE.im4p` | Serial labels + image4 callback + boot-args + rootfs + panic (6 patches) |
| **iBoot** | RES (vresearch101ap research) | `Firmware/all_flash/iBoot.vresearch101.RESEARCH_RELEASE.im4p` | Not patched (only research identity carries iBoot) |

### Security Monitors (from PCC, shared across board configs)

| Component | Source Identity | File | Patches Applied |
|-----------|---------------|------|-----------------|
| **Ap,RestoreSecurePageTableMonitor** | PROD | `Firmware/sptm.vresearch1.release.im4p` | Not patched |
| **Ap,RestoreTrustedExecutionMonitor** | PROD | `Firmware/txm.iphoneos.release.im4p` | Not patched |
| **Ap,SecurePageTableMonitor** | PROD | `Firmware/sptm.vresearch1.release.im4p` | Not patched |
| **Ap,TrustedExecutionMonitor** | RES (research) | `Firmware/txm.iphoneos.research.im4p` | Trustcache bypass (`mov x0, #0` at 0x2C1F8) |

### Runtime Components (from PCC vphone600ap)

| Component | Source Identity | File | Patches Applied |
|-----------|---------------|------|-----------------|
| **DeviceTree** | VP (vphone600ap release) | `Firmware/all_flash/DeviceTree.vphone600ap.im4p` | Not patched |
| **RestoreDeviceTree** | VP | `Firmware/all_flash/DeviceTree.vphone600ap.im4p` | Not patched |
| **SEP** | VP | `Firmware/all_flash/sep-firmware.vphone600.RELEASE.im4p` | Not patched |
| **RestoreSEP** | VP | `Firmware/all_flash/sep-firmware.vphone600.RELEASE.im4p` | Not patched |
| **KernelCache** | VPR (vphone600ap research) | `kernelcache.research.vphone600` | 25 dynamic patches via KernelPatcher |
| **RestoreKernelCache** | VP (vphone600ap release) | `kernelcache.release.vphone600` | Not patched (used during restore only) |
| **RecoveryMode** | VP | `Firmware/all_flash/recoverymode@2556~iphone-USBc.im4p` | Not patched |

> **Important**: KernelCache (installed to disk, patched) uses the **research** variant.
> RestoreKernelCache (used during restore process only) uses the **release** variant.
> Only vphone600ap identities carry RecoveryMode — vresearch101ap does not.

### OS / Filesystem (from iPhone)

| Component | Source | Notes |
|-----------|--------|-------|
| **OS** | iPhone `iPhone17,3` erase identity | iPhone OS image |
| **SystemVolume** | iPhone erase | Root hash |
| **StaticTrustCache** | iPhone erase | Static trust cache |
| **Ap,SystemVolumeCanonicalMetadata** | iPhone erase | Metadata / mtree |

### Ramdisk (from PCC)

| Component | Source | Notes |
|-----------|--------|-------|
| **RestoreRamDisk** | PROD (vresearch101ap release) | CloudOS erase ramdisk |
| **RestoreTrustCache** | PROD | Ramdisk trust cache |

---

## Patched Components Summary

All 6 patched components in `fw_patch.py` come from **PCC (cloudOS)**:

| # | Component | Source Board | Patch Count | Purpose |
|---|-----------|-------------|-------------|---------|
| 1 | AVPBooter | vresearch1 | 1 | Bypass DGST signature validation |
| 2 | iBSS | vresearch101 | 2 | Enable serial output + bypass image4 verification |
| 3 | iBEC | vresearch101 | 3 | Enable serial + bypass image4 + inject boot-args |
| 4 | LLB | vresearch101 | 6 | Serial + image4 + boot-args + rootfs mount + panic handler |
| 5 | TXM | shared (iphoneos) | 1 | Bypass trustcache validation |
| 6 | KernelCache | vphone600 | 25 | APFS seal, MAC policy, debugger, launch constraints, etc. |

All 4 CFW-patched binaries in `patch_cfw.py` / `install_cfw.sh` come from **iPhone**:

| # | Binary | Source | Purpose |
|---|--------|--------|---------|
| 1 | seputil | iPhone (Cryptex SystemOS) | Gigalocker UUID patch (`/%s.gl` → `/AA.gl`) |
| 2 | launchd_cache_loader | iPhone (Cryptex SystemOS) | NOP cache validation check |
| 3 | mobileactivationd | iPhone (Cryptex SystemOS) | Force `should_hactivate` to return true |
| 4 | launchd.plist | iPhone (Cryptex SystemOS) | Inject bash/dropbear/trollvnc daemons |

---

## Why vphone600 Runtime Components?

The vresearch101ap device tree causes a **fatal keybag error** during boot:
```
MKB_INIT: dt = 0, bootarg = 0
MKB_INIT: FATAL KEYBAG ERROR: failed to load system bag
REBOOTING INTO RECOVERY MODE.
```

The vphone600ap device tree sets `dt=1`, allowing boot without a pre-existing
system keybag:
```
MKB_INIT: dt = 1, bootarg = 0
MKB_INIT: No system keybag loaded.
```

The SEP firmware must match the device tree (vphone600 SEP with vphone600 DT).

---

## Build Identity (Single DFU Erase)

Since vphone-cli always boots via DFU restore, only one Build Identity is needed.

### Identity Metadata (must match DFU hardware for TSS)
```
DeviceClass     = vresearch101ap
Variant         = Darwin Cloud Customer Erase Install (IPSW)
Ap,ProductType  = ComputeModule14,2
Ap,Target       = VRESEARCH101AP
Ap,TargetType   = vresearch101
ApBoardID       = 0x90
ApChipID        = 0xFE01
FDRSupport      = False
```

### Identity Source Map (fw_manifest.py variables)
```
PROD = vresearch101ap release    — boot chain, SPTM, ramdisk
RES  = vresearch101ap research   — iBoot, TXM (research)
VP   = vphone600ap release       — DeviceTree, SEP, RestoreKernelCache, RecoveryMode
VPR  = vphone600ap research      — KernelCache (research, patched by fw_patch.py)
I_ERASE = iPhone erase identity  — OS image, trust caches, system volume
```

### Manifest Components (21 total)
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

## TL;DR

**Boot chain = vresearch101 (matches DFU hardware); runtime = vphone600 (keybag-less boot); OS = iPhone.**

The firmware is a PCC shell wrapping an iPhone core. The vresearch101 boot chain
handles DFU/TSS signing. The vphone600 device tree + SEP + kernel provide the
runtime environment. The iPhone userland is patched post-install for activation
bypass, jailbreak tools, and persistent SSH/VNC.
