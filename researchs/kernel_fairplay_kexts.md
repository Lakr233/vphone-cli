# FairPlay IOKit Extensions in PCC Kernel

**Kernel:** `kernelcache.release.vphone600` (PCC/cloudOS, vresearch101ap)
**Total kexts in kernel:** 161
**FairPlay kexts found:** 2

---

## 1. com.apple.driver.AvpFairPlayDriver

| Field | Value |
|-------|-------|
| Path | `/System/Library/Extensions/AvpFairPlayDriver.kext` |
| Version | 2.9.0 |
| Executable Size | 2,920 bytes |
| IOClass | `AvpFairPlayDriver` |
| IOProviderClass | `AppleVirtIOTransport` |
| IOUserClientClass | `AvpFairPlayUserClient` |
| PCI Match | `0x1a08106b` |
| Dependencies | AppleVirtIO, IOKit, libkern |

**Notes:**
- Virtualization-specific FairPlay driver — matches on a VirtIO PCI device ID (`0x1a08106b`).
- Tiny kext (2.9 KB), acts as a paravirtual bridge to the host-side FairPlay backend.
- Implies the host Virtualization.framework exposes a FairPlay VirtIO device to the guest.
- Has two IOKit personalities:
  - `AvpFairPlayDriver` — matches `AppleVirtIOTransport` with `IOVirtIOPrimaryMatch: 0x1a08106b`
  - `AvpFairPlayDriver Transport` — matches `IOPCIDevice` with `IOPCIPrimaryMatch: 0x1a08106b` (published by `com.apple.driver.AppleVirtIO`)

---

## 2. com.apple.driver.FairPlayIOKit

| Field | Value |
|-------|-------|
| Path | `/System/Library/Extensions/FairPlayIOKit.kext` |
| Version | 72.15.0 |
| Executable Size | 269,440 bytes |
| IOClass | `com_apple_driver_FairPlayIOKit` |
| IOProviderClass | `IOResources` (always-match) |
| IOUserClientClass | `com_apple_driver_FairPlayIOKitUserClient` |
| IOMatchCategory | `FairPlayIOKit` |
| IOProbeScore | 1000 |
| Dependencies | bsd, **dsep**, iokit, libkern, mach, private, unsupported |

**Notes:**
- Full FairPlay DRM framework kext (269 KB of code).
- Matches on `IOResources` — loads unconditionally at boot.
- Provides FairPlay services to userland via `com_apple_driver_FairPlayIOKitUserClient`.
- Depends on `com.apple.kpi.dsep` (data-at-rest encryption / DRM subsystem).
- Copyright 2008–2019 — long-lived Apple DRM component.

---

## String Occurrences

| Pattern | Count |
|---------|-------|
| `FairPlay` (case-sensitive) | 139 |
| `fairplay` (lowercase) | 27 |
| `com.apple.driver.FairPlayIOKit` | 6 |
| `com.apple.driver.AvpFairPlayDriver` | 3 |

Lowercase `fairplay` strings include launch constraint labels: `com.apple.fairplayd`, `com.apple.fairplayd.A2`, `com.apple.fairplayd.A2.dev`, `com.apple.fairplayd.G1` — these are userland daemon identifiers referenced in kernel launch constraint plists.

---

## Implications

- Both kexts are present in the non-JB PCC boot kernel and will load at boot.
- `AvpFairPlayDriver` is the VM-aware component — it bridges FairPlay operations to the host via VirtIO. This is unique to the virtualized (PV=3) environment.
- `FairPlayIOKit` is the standard iOS FairPlay kext, providing DRM primitives to userland processes (e.g., `fairplayd`, media frameworks).
- For research purposes, these kexts may need to be patched or neutralized if FairPlay enforcement interferes with instrumentation or custom binaries.
