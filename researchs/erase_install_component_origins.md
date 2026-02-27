# Erase Install — Component Origins

The erase install firmware is a **hybrid** of Apple PCC (Private Cloud Compute /
cloudOS / vresearch101ap) and iPhone (iPhone17,3 / 26.1 / 23B85) components.

`prepare_firmware.sh` downloads both IPSWs, then **merges cloudOS firmware into
the iPhone restore directory** — copying kernelcaches, `Firmware/{agx,all_flash,
ane,dfu,pmp}/*`, and all loose `Firmware/*.im4p` files from cloudOS on top of
the iPhone tree. `prepare_firmware_build_manifest.py` then generates a hybrid
`BuildManifest.plist` with 5 build identities.

---

## Component Source Table

### Boot Chain (all from PCC)

| Component | Source | File Pattern | Patches Applied |
|-----------|--------|--------------|-----------------|
| **AVPBooter** | PCC `vresearch1` | `AVPBooter*.bin` (vm dir) | DGST validation bypass (`mov x0, #0`) |
| **iBSS** | PCC `vresearch101ap` | `Firmware/dfu/iBSS.vresearch101.RELEASE.im4p` | Serial labels + image4 callback bypass |
| **iBEC** | PCC `vresearch101ap` | `Firmware/dfu/iBEC.vresearch101.RELEASE.im4p` | Serial labels + image4 callback + boot-args |
| **LLB** | PCC `vresearch101ap` | `Firmware/all_flash/LLB.vresearch101.RELEASE.im4p` | Serial labels + image4 callback + boot-args + rootfs + panic (6 patches) |
| **SPTM** | PCC `vresearch101ap` | `Firmware/all_flash/` | Not patched (loaded as-is) |
| **TXM** | PCC `vresearch101ap` | `Firmware/txm.iphoneos.research.im4p` | Trustcache bypass (`mov x0, #0` at 0x2C1F8) |
| **SEP Firmware** | PCC `vresearch101ap` | `Firmware/all_flash/sep-firmware.vresearch101.RELEASE.im4p` | Not patched |
| **DeviceTree** | PCC `vphone600ap` | `Firmware/all_flash/DeviceTree.vphone600ap.im4p` | Not patched |
| **KernelCache** | PCC `vresearch101ap` | `kernelcache.release.vphone600` / `kernelcache.research.vphone600` | 25 dynamic patches via KernelPatcher (APFS, MAC policy, debugger, launch constraints, etc.) |

> Note: TXM filename contains "iphoneos" but it is copied from the cloudOS IPSW
> via `cp ${CLOUDOS_DIR}/Firmware/*.im4p` in `prepare_firmware.sh` line 81.

### OS / Filesystem (all from iPhone)

| Component | Source | Notes |
|-----------|--------|-------|
| **Cryptex1,SystemOS** | iPhone `iPhone17,3` | System volume DMG |
| **Cryptex1,AppOS** | iPhone `iPhone17,3` | App volume DMG |
| **OS** | iPhone `iPhone17,3` | iPhone OS image |
| **SystemVolume** | iPhone `iPhone17,3` | System partition |
| **StaticTrustCache** | iPhone `iPhone17,3` | Static trust cache |

### Ramdisk (depends on identity)

| Component | Identity 0 (Erase) | Identity 1 (Upgrade) |
|-----------|--------------------|--------------------|
| **RestoreRamDisk** | PCC (cloudOS PROD erase ramdisk) | iPhone (upgrade ramdisk) |
| **RestoreTrustCache** | Follows ramdisk source | Follows ramdisk source |

### UI / Misc (from iPhone)

| Component | Source |
|-----------|--------|
| **AppleLogo** | iPhone |
| **RestoreLogo** | iPhone |
| **RecoveryMode** | iPhone |
| **Cryptex1 metadata/keys** | iPhone erase identity (merged into PCC identities) |

### Hardware Firmware (from PCC)

| Component | Source |
|-----------|--------|
| **agx/** (GPU) | PCC cloudOS |
| **ane/** (Neural Engine) | PCC cloudOS |
| **pmp/** (Power Management) | PCC cloudOS |

---

## Patched Components Summary

All 6 patched components in `patch_firmware.py` come from **PCC (cloudOS)**:

| # | Component | Source | Patch Count | Purpose |
|---|-----------|--------|-------------|---------|
| 1 | AVPBooter | PCC | 1 | Bypass DGST signature validation |
| 2 | iBSS | PCC | 2 | Enable serial output + bypass image4 verification |
| 3 | iBEC | PCC | 3 | Enable serial + bypass image4 + inject boot-args |
| 4 | LLB | PCC | 6 | Serial + image4 + boot-args + rootfs mount + panic handler |
| 5 | TXM | PCC | 1 | Bypass trustcache validation |
| 6 | KernelCache | PCC | 25 | APFS seal, MAC policy, debugger, launch constraints, etc. |

All 4 CFW-patched binaries in `patch_cfw.py` / `install_cfw.sh` come from **iPhone**:

| # | Binary | Source | Purpose |
|---|--------|--------|---------|
| 1 | seputil | iPhone (Cryptex SystemOS) | Gigalocker UUID patch (`/%s.gl` → `/AA.gl`) |
| 2 | launchd_cache_loader | iPhone (Cryptex SystemOS) | NOP cache validation check |
| 3 | mobileactivationd | iPhone (Cryptex SystemOS) | Force `should_hactivate` to return true |
| 4 | launchd.plist | iPhone (Cryptex SystemOS) | Inject bash/dropbear/trollvnc daemons |

---

## Build Identities

| # | Name | Boot Chain | Ramdisk | Cryptex1 | Variant String |
|---|------|-----------|---------|----------|----------------|
| 0 | Erase | PCC RELEASE | PCC erase | iPhone | `Darwin Cloud Customer Erase Install (IPSW)` |
| 1 | Upgrade | PCC RESEARCH | iPhone upgrade | iPhone | `Darwin Cloud Customer Upgrade Install (IPSW)` |
| 2 | Research Erase | PCC RESEARCH | PCC erase | None | `Darwin Cloud Customer Research Erase Install (IPSW)` |
| 3 | Research Upgrade | PCC RESEARCH | iPhone upgrade | None | `Darwin Cloud Customer Research Upgrade Install (IPSW)` |
| 4 | Recovery | PCC RESEARCH | None | None | `Darwin Cloud Customer Recovery (IPSW)` |

---

## TL;DR

**Boot-chain patches target PCC components; CFW patches target iPhone components.**

The firmware is a PCC shell (boot chain + kernel + device tree + hardware firmware)
wrapping an iPhone core (iOS filesystem + Cryptex + OS images). The boot chain is
patched to disable signature verification and enable debug access; the iPhone
userland is patched post-install for activation bypass, jailbreak tools, and
persistent SSH/VNC.
