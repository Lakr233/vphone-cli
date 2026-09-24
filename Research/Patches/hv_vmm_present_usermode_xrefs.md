# `kern.hv_vmm_present` user-mode call sites — iPhone17,3 26.1 (23B85)

Source material: `ipsws/iPhone17,3_26.1_23B85_Restore` (raw IPSW; encrypted DMGs)
and `ipsws/iPhone17,3_26.1_23B85_Restore_extracted` (rebuilt rootfs with split DSC).

This document enumerates every place in user space that reads
`kern.hv_vmm_present` via the `sysctl` family on this firmware, what each
caller appears to do with the result, and what is reasonable to expect from
patching that specific reader instead of the kernel.

## Current shipping design — blacklist-flip + kernel rename

The current patch pipeline takes a **kernel-rename + user-mode-blacklist**
approach. Summary:

* The Swift kernel patch `patch_hv_vmm_rename` (JB-26, Group B) renames
  the kernel's `hv_vmm_present` sysctl OID name in place to
  `Xv_vmm_present` (single byte change at offset 0 of the 14-byte
  cstring `\0hv_vmm_present\0`). After this kernel patch:
  - `sysctlbyname("kern.hv_vmm_present", ...)` returns ENOENT.
  - `sysctlbyname("kern.Xv_vmm_present", ...)` returns 1, the OID's
    real int value.
* The user-mode mangle pattern moved from byte 0 (`'k' → 'X'`,
  producing `Xern.hv_vmm_present` — unroutable because `Xern` isn't a
  top-level namespace) to byte 5 (`'h' → 'X'`, producing
  `kern.Xv_vmm_present` — keeps `kern.` intact, routes to the renamed
  OID).
* `scripts/patchers/cfw_patch_hv_vmm_dsc.py` now applies the mangle as
  a BLACKLIST. The list `DONT_PATCH_INSTALL_NAMES` names dylibs whose
  cstring is LEFT untouched — they query the original (now
  ENOENT-returning) name and cache 0 ("not in a VM"). Every other DSC
  dylib with the cstring gets the byte-5 mangle, queries the new name,
  and caches 1 ("in a VM", same as stock) — keeping graphics +
  compute/accel fast paths intact.
* The standalone-binary patch step over SSH (originally `cfw_install_jb.sh`
  JB-3.5 and `cfw_install_dev.sh` 6.5/7) was removed. With the kernel
  rename in place, those 6 rootfs binaries fall into the "unpatched → ENOENT
  → cache 0" bucket automatically.

The earlier whitelist-only design (no kernel patch, mangle a chosen
subset to ENOENT) is preserved for reference in the section
"Pre-blacklist whitelist enumeration" below, since the per-caller
classification work is still the source-of-truth for what each
binary's cstring usage actually looks like.

## What the sysctl is

`kern.hv_vmm_present` is defined in XNU at
`bsd/kern/hvg_sysctl.c:176`:

> `static SYSCTL_PROC(_kern, OID_AUTO, hv_vmm_present,`
> `    CTLTYPE_INT | CTLFLAG_ANYBODY | CTLFLAG_KERN | CTLFLAG_LOCKED, …)`

Backing handler `sysctl_vmm_present` (line 136 in the same file) returns
an `int`, computed on arm64 from `IODTGetDefault("vmm-present", …)` —
i.e. a device-tree key that Apple's Virtualization.framework /
PCC bring-up plants in the guest. On real hardware the key is absent
and the read returns `0`; on PCC/research VMs it returns `1`. That is
exactly the path you are flipping today by patching the kernel.

Because this is a single named OID with `CTLFLAG_ANYBODY`, every user-mode
reader funnels through the canonical `sysctlbyname()` shape:

```
adrp  x0, <page>            ; x0 = "kern.hv_vmm_present"
add   x0, x0, #<off>
sub   x1, x29, #4            ; x1 = &result (int)
mov   x2, sp                 ; x2 = &len (= 4)
mov   x3, #0                 ; newp
mov   x4, #0                 ; newlen
bl    _sysctlbyname
```

This shape is the matcher I used to flag “real readers” below.

## Method

1. Located the literal `"kern.hv_vmm_present\0"` inside every Mach-O of the
   rebuilt rootfs (the split DSC dylibs and every executable). 56 binaries
   matched on bytes alone.
2. For each match, parsed the LC\_SEGMENT\_64 layout and located the
   actual section. Anything that wasn't in `__TEXT,__cstring` (or another
   section flagged `S_CSTRING_LITERALS`, flag `0x2`) was investigated
   separately.
3. For each cstring hit, looked for ADRP+ADD or ADRP+LDR pairs in any
   executable section that compute the string's vm address, then walked
   forward up to ~24 instructions tracking simple register propagation
   (`mov xN, xM`).
4. Classified each xref:
   * `CANONICAL` — string ends up in `x0`, `x3=x4=0`, BL within the window.
     Matches `sysctlbyname(name, oldp, oldlenp, NULL, 0)`.
   * `PROBABLE` — string in `x0` and a BL in window, but `x3`/`x4` zeroing
     not seen.
   * `REFERENCED` — xref exists but it is loaded into a non-x0 register or
     used as an address anchor for adjacent data, not handed to a syscall.
   * `STORED` — string written into a struct (i.e. a registry, not a
     direct caller).
   * `DEAD` — string lives in `__cstring` but no executable instruction
     points at its page.

The full per-binary results (snippets, addresses, classification) are
saved at `outputs/hv_vmm_present_xref.json`.

## Inventory by class

### A. CANONICAL `sysctlbyname("kern.hv_vmm_present", …)` callers — 35

Each line is `<binary>  string@<vmaddr>  xref@<vmaddr>`. The xref
address is the **`add` instruction** that finalizes the pointer value
in `x0`; immediately followed by the canonical 5-arg `sysctlbyname`
preamble and a `bl`.

```
usr/lib/libMobileGestalt.dylib                                                          string@0x1b0201c60  xref@0x1b0198d00
System/Library/Frameworks/CoreVideo.framework/CoreVideo                                 string@0x19d17a4bb  xref@0x19d122eb8
System/Library/Frameworks/CoreML.framework/CoreML                                       string@0x1950ed0d0  xref@0x194c3c754
System/Library/Frameworks/StoreKit.framework/Support/storekitd                          string@0x10031a890  xref@0x100176f6c
System/Library/PrivateFrameworks/CoreRE.framework/CoreRE                                string@0x1e3171b20  xref@0x1e2790f28
System/Library/PrivateFrameworks/Espresso.framework/Espresso                            string@0x1949204e5  xref@0x193bef83c
System/Library/PrivateFrameworks/AppleNeuralEngine.framework/AppleNeuralEngine          string@0x1ad297375  xref@0x1ad248248
System/Library/PrivateFrameworks/AppStoreDaemon.framework/Support/appstored             string@0x10046dae6  xref@0x1003e25b8
System/Library/PrivateFrameworks/AppStoreUtilities.framework/AppStoreUtilities          string@0x23ff916d7  xref@0x23ff8bfe4
System/Library/PrivateFrameworks/ApplePushService.framework/ApplePushService            string@0x1b235fd50  xref@0x1b2358d10
System/Library/PrivateFrameworks/AuthKit.framework/AuthKit                              string@0x1933c11de  xref@0x19322f7e8
System/Library/PrivateFrameworks/AAAFoundation.framework/AAAFoundation                  string@0x1c86581a1  xref@0x1c8650ee4
System/Library/PrivateFrameworks/AirPlaySupport.framework/AirPlaySupport                string@0x2223618a0  xref@0x222306a28
System/Library/PrivateFrameworks/CorePrescription.framework/CorePrescription            string@0x2471fe6ed  xref@0x2471ebc18
System/Library/PrivateFrameworks/CorePrescription.framework/XPCServices/CorePrescriptionService.xpc/CorePrescriptionService string@0x100092175  xref@0x100005064
System/Library/PrivateFrameworks/CoreCDP.framework/CoreCDP                              string@0x1dedfa62d  xref@0x1dedbb724
System/Library/PrivateFrameworks/DVTInstrumentsUtilities.framework/DVTInstrumentsUtilities  string@0x247f42ad0  xref@0x247f1154c
System/Library/PrivateFrameworks/DeviceCheckInternal.framework/DeviceCheckInternal      string@0x2487a018c  xref@0x24878d10c
System/Library/PrivateFrameworks/DeviceIdentity.framework/DeviceIdentity                string@0x2260a4b25  xref@0x2260862a4
System/Library/PrivateFrameworks/EmailFoundation.framework/EmailFoundation              string@0x1c61cd1f7  xref@0x1c6165e88
System/Library/PrivateFrameworks/FindMyBase.framework/FindMyBase                        string@0x1df635420  xref@0x1df5fb8d4
System/Library/PrivateFrameworks/IDSFoundation.framework/IDSFoundation                  string@0x1a7ea0fe4  xref@0x1a7c65dc4
System/Library/PrivateFrameworks/IOSurfaceAccelerator.framework/IOSurfaceAccelerator    string@0x2547cd71c  xref@0x2547caa48
System/Library/PrivateFrameworks/MobileActivation.framework/MobileActivation            string@0x2598f06c6  xref@0x2598e2618
System/Library/PrivateFrameworks/PhotoFoundation.framework/PhotoFoundation              string@0x1d8ba907c  xref@0x1d8b9e7fc
System/Library/PrivateFrameworks/RenderBox.framework/RenderBox                          string@0x195e54555  xref@0x195d344a0
System/Library/PrivateFrameworks/TrialServer.framework/TrialServer                      string@0x26f32471e  xref@0x26f224120
System/Library/PrivateFrameworks/VisionKitCore.framework/VisionKitCore                  string@0x1b442d9cf  xref@0x1b435f0a4
System/Library/PrivateFrameworks/WatchdogServiceManagement.framework/WatchdogServiceManagement string@0x272725b23  xref@0x272725114
System/Library/PrivateFrameworks/WebGPU.framework/WebGPU                                string@0x225722b6c  xref@0x22552c2bc
System/Library/PrivateFrameworks/caulk.framework/caulk                                  string@0x27512204f  xref@0x275112808
System/Library/DataClassMigrators/MobileActivationMigrator.migrator/MobileActivationMigrator string@0x72aa     xref@0x3024
System/Library/ExtensionKit/Extensions/HostInferenceProviderService.appex/HostInferenceProviderService string@0x1000112b0  xref@0x10000b890
Applications/CheckerBoard.app/CheckerBoard                                              string@0x10006fb56  xref@0x1000192e8
Applications/StoreKitUISceneService.app/StoreKitUISceneService                          string@0x1000a2ca0  xref@0x100083f04
```

All 35 readers share the same five-argument shape. Most also share a
post-call idiom: store the boolean result into a static byte (cache),
and a sibling `getter()` reads the cached byte. libMobileGestalt is the
clearest exemplar:

```
0x1b0198cf0  stur  wzr, [x29, #-4]
0x1b0198cf4  mov   w8, #4
0x1b0198cf8  str   x8, [sp]
0x1b0198cfc  adrp  x0, #0x1b0201000
0x1b0198d00  add   x0, x0, #0xc60       ; "kern.hv_vmm_present"
0x1b0198d04  sub   x1, x29, #4
0x1b0198d08  mov   x2, sp
0x1b0198d0c  mov   x3, #0
0x1b0198d10  mov   x4, #0
0x1b0198d14  bl    #<sysctlbyname>
0x1b0198d18  cbnz  w0, ...skip...
0x1b0198d1c  ldur  w8, [x29, #-4]
0x1b0198d24  cset  w8, ne
0x1b0198d28  adrp  x9, #0x1ed446000
0x1b0198d2c  strb  w8, [x9, #0xcf8]      ; cached_is_vmm := (val != 0)
```

CoreML, CoreRE, Espresso, AppleNeuralEngine, MobileActivation,
caulk, RenderBox, etc. all do the same: one call, cached, sibling
accessor. That makes the patch surface for each one very small —
overwriting `cset w8, ne` with `mov w8, #0` (or NOPing the call and
zeroing the cached byte's accessor) is all that's needed per binary.

### B. False positives ruled out by xref analysis

15 of the 56 string-bearing binaries are **not** actual readers:

#### B.1 Embedded entitlement plist (the binary just declares it can read the OID)

These four embed a `com.apple.security.exception.sysctl.read-only` (or
`sysctl-read`) entitlement that names `kern.hv_vmm_present`. The
entitlement only authorises the sandbox; the actual `sysctlbyname` call
happens in libraries they link (almost certainly libMobileGestalt or
CoreFoundation). The binaries themselves contain no instruction
xref to the string.

```
Applications/Family.app/Family
Applications/PeopleMessageService.app/PeopleMessageService
Applications/PeopleViewService.app/PeopleViewService
System/Library/PrivateFrameworks/DataDetectorsUI.framework/PlugIns/com.apple.DataDetectorsUI.ActionsExtension.appex/com.apple.DataDetectorsUI.ActionsExtension
```

#### B.2 Compiled sandbox profile (the string lives inside an embedded SBPL blob)

The string is in `__TEXT,__const`, surrounded by high-entropy bytes that
match a compiled sandbox profile. No code reaches the string. As with
B.1, these only declare the OID is permitted — not that they read it.

```
usr/sbin/absd
usr/sbin/fairplayd.H2
System/Library/CoreServices/ClarityBoard.app/ClarityBoard
System/Library/PrivateFrameworks/CoreALD.framework/CoreALD
System/Library/PrivateFrameworks/IDS.framework/identityservicesd.app/identityservicesd
System/Library/PrivateFrameworks/SonicKit.framework/SonicKit
System/Library/PrivateFrameworks/VideosUI.framework/VideosUI
```

#### B.3 String present in `__cstring` but unreferenced (linker DCE leftover)

The string sits in the cstring section but no ADRP+ADD/LDR in any
executable section computes its vmaddr, and no 8-byte little-endian
encoding of the address (raw, image-relative, or 36-bit chained-fixup
shape) appears in any other section either.

```
usr/sbin/bluetoothd                                                      (verified: 0 ADRPs into the page; 0 byte-pointer matches)
System/Library/Frameworks/MediaToolbox.framework/MediaToolbox
System/Library/Frameworks/ManagedAppDistribution.framework/Support/managedappdistributiond
System/Library/PrivateFrameworks/ApplePushService.framework/apsd
System/Library/PrivateFrameworks/CMCapture.framework/CMCapture
System/Library/PrivateFrameworks/MagnifierSupport.framework/MagnifierSupport
System/Library/PrivateFrameworks/NeuralNetworks.framework/NeuralNetworks
System/Library/PrivateFrameworks/Recon3D.framework/Recon3D
System/Library/PrivateFrameworks/VFX.framework/VFX
```

#### B.4 Adjacent‑string anchor (REFERENCED but not a sysctl call)

```
System/Library/Frameworks/SoundAnalysis.framework/SoundAnalysis
```

The ADRP+ADD here computes `x8 = "kern.hv_vmm_present"`, then immediately
`x20 = x8 - 0x20`, i.e. it is using our string as a fixed offset to reach
a *different* sysctl name 32 bytes earlier in the cstring section. The
sysctlbyname call passes `x20`, not our string. No need to patch.

## What each CANONICAL caller is reasonable to expect to do

I am being literal here: I report what the framework path implies and
what the disassembly shows. Beyond what's listed I do not have direct
evidence of behaviour and would need runtime tracing to be sure.

| Component | Likely role of the check | Patching effect (only this caller) |
|---|---|---|
| `libMobileGestalt.dylib` | Implements `MGCopyAnswer("hv-vmm-present")` and similar — the answer most other Apple frameworks query through it. Single shared cache byte. | Many higher-level callers ask MobileGestalt instead of doing their own sysctl. Forcing MG's cache to 0 makes most “am I a VM?” checks throughout the system see "no" without further code changes. **Highest-leverage single patch.** |
| `CoreML.framework` / `Espresso.framework` / `AppleNeuralEngine.framework` / `CoreRE.framework` / `RenderBox.framework` / `WebGPU.framework` / `caulk.framework` | Compute / accel paths. Each independently caches a "running on VM" flag; their respective dispatchers gate ANE/Metal/HW codecs. | Disables their VM-aware fast-path bypasses. Practical effect: lets these libraries try the same code path they'd use on real silicon. On a research VM with PCC PV=3 they may now hit code that demands real ANE/SEP/etc. and fail — patch only if you specifically need them to take the silicon path. |
| `IOSurfaceAccelerator.framework` | Hardware surface allocation paths. | Same caveat — pushing it onto the silicon path may produce IOKit failures. |
| `RenderBox.framework`, `WebGPU.framework`, `Espresso.framework` | Already covered above (graphics/ML). | — |
| `CoreVideo.framework` | Video pipeline / capture surfaces. Caches a global. | Similar story to the accel libs. |
| `StoreKit.framework` (`storekitd`), `AppStoreDaemon` (`appstored`), `AppStoreUtilities`, `Applications/StoreKitUISceneService` | All of the App Store / IAP daemons and their host UI. They tag receipts with VM status. | Best candidate to patch *together*, because making the Store stop labelling sessions as "vm=1" while everything else stays the same is exactly the kind of selective lying the user asked for. Receipts and SKUI flow start looking like a real device. |
| `ApplePushService` (`ApplePushService`) | APNS client. APNS connection establishment includes a "device characteristics" payload. | Patching makes the APNS handshake claim the device is bare metal. Useful if push tokens are silently downgraded for VMs. |
| `AAAFoundation`, `AuthKit`, `IDSFoundation`, `DeviceIdentity`, `DeviceCheckInternal` | Apple ID / iCloud / iMessage attestation and DeviceCheck (anti-fraud) plumbing. Every one of them caches `is_vmm` to feed into device-binding/anti-abuse decisions. | Patching the AuthKit/IDS/DeviceCheck callers individually is the conservative way to make “Sign in with Apple ID”, iMessage activation, and DeviceCheck attestations stop self-flagging as VM, while leaving compute paths (CoreML, ANE) alone. **High-leverage for "make iMessage/iCloud trust this device" without disabling kernel-level VM behaviour.** |
| `MobileActivation.framework`, `MobileActivationMigrator` | Activation flow + migration tool. | Activation today uses kern.hv_vmm_present to decide whether to take the fastlane / dev path. Patching would normalise activation. |
| `CorePrescription.framework` (+ XPC service) | Health-data prescription store. | The check is almost certainly "don't sync prescriptions on a VM"; patching here gates Health/Rx data sync. |
| `EmailFoundation.framework` | Mail. | Likely a mail-account heuristic; patching is benign. |
| `PhotoFoundation.framework` | Photos. | Likely a "hide some assets on VMs" check. |
| `FindMyBase.framework` | Find My. | Anti-spoof gate. |
| `TrialServer.framework` | Internal A/B / trial-rollout client. | Trials' "exclude VMs" gate. |
| `WatchdogServiceManagement` | The watchdog manager. | Note `string@0x272725b23` lives in the same page as its own `__text`; this is a tiny binary with one and only one consumer. Patching is local and self-contained. |
| `VisionKitCore.framework`, `CoreCDP.framework` | Vision/CDP. Single sysctl, cached. | — |
| `AirPlaySupport.framework` | AirPlay. Cached flag. | Likely a "no AirPlay receiver on VM" gate. |
| `DVTInstrumentsUtilities.framework` | Xcode Instruments support library. | Dev-only; cosmetic. |
| `Applications/CheckerBoard.app` | Apple's internal CoreAccessibility test app — the build-time sample most likely link-imports the same telemetry helper as everyone else. | Cosmetic. |
| `HostInferenceProviderService.appex` | On-device generative-AI inference host. | Same family as the ML accel libs above; gate to compute paths. |

## Why the kernel-side patch breaks display while a user-side patch does not

The kernel-side patch (returning `0` from `sysctl_vmm_present` /
`IODTGetDefault("vmm-present")`) flips the answer for **every** consumer
in the boot pipeline, including kernel-internal users of `vmm-present`
(IOKit, IOSurface, display drivers, AGX). The display path consumes the
flag for its own paravirt routing — that's the symptom you observed.

A user-mode patch only changes what landed in the 35 dylib/exe call sites
above. None of them are on the display bring-up path; they all run
post-launchd, after the framebuffer/IOSurface plumbing is already up.
So the display works as VM, while the higher-level "this is a VM"
hints are suppressed wherever you choose.

## Recommended patch surface

Given the vphone-cli design intent ("VM-aware where it has to be,
device-like where it can be"), the smallest set that buys the most is:

1. **`libMobileGestalt.dylib`** — single biggest fan-in. Many other
   processes ask MG instead of calling `sysctlbyname` directly, so this
   one patch propagates.
2. **`CorePrescription`, `WatchdogServiceManagement`, `EmailFoundation`,
   `PhotoFoundation`, `FindMyBase`, `AirPlaySupport`, `TrialServer`,
   `CoreCDP`, `VisionKitCore`** — the consumer apps/services. Patching
   them gives the device-like surface for sync, mail, photos, find-my,
   etc.
3. **`AAAFoundation`, `AuthKit`, `IDSFoundation`, `DeviceIdentity`,
   `DeviceCheckInternal`, `MobileActivation`, `MobileActivationMigrator`,
   `ApplePushService`** — identity / push / activation. Patching here
   normalises the device's posture against Apple's anti-abuse signals.
4. **`StoreKit/storekitd`, `AppStoreDaemon/appstored`, `AppStoreUtilities`,
   `StoreKitUISceneService`** — App Store + IAP. Patch as a group.
5. **DO NOT patch (most likely):** `CoreML`, `CoreRE`, `Espresso`,
   `AppleNeuralEngine`, `RenderBox`, `WebGPU`, `caulk`, `CoreVideo`,
   `IOSurfaceAccelerator`, `HostInferenceProviderService`. These are the
   compute/accel libraries — pushing them onto the silicon path on a VM
   is the most likely way to cause new failures (no real ANE / no real
   AGX / no real H.265 hardware encoder available to take the call).
6. Ignore the false positives in section B entirely — they don't read
   the sysctl.

The exact byte-level patch shape that works for every CANONICAL site is
identical to what you already have in the kernel: turn the 1-bit boolean
that gets cached after the call into a constant 0. The ARM64 idiom
`cset wN, ne` (after `cmp wM, #0`) → `mov wN, #0` (3 byte-pattern
substitutions: `0x9f1f00b1` zero immediate move, etc.) is a one-instruction
patch per consumer.

If you'd rather skip the call entirely, replace the `bl <sysctlbyname>`
with `mov w0, #0` (success) and zero the result on the stack — also
one instruction, but now `w0=0` is read as the int result so the
post-call boolean naturally becomes 0.

## Files

* `outputs/hv_vmm_present_xref.json` — full per-binary xref dump
  (string addresses, xref addresses, classification, surrounding
  disassembly).
* `Research/hv_vmm_present_xref.json` — same dump committed in-tree.

## Patcher implementation (Dev + JB only)

Implemented as part of the existing `cfw_install_dev.sh` /
`cfw_install_jb.sh` flows; the regular `cfw_install.sh` is left
untouched (per design — the regular variant stays "as honest as
possible", and the device-likeness layer is opt-in via the dev or
jb variants).

**Patch shape, every site** — 1-byte cstring mangle:

```
cstring "kern.hv_vmm_present\0"    →    "Xern.hv_vmm_present\0"
        ^ byte 0 = 'k' (0x6B)           ^ byte 0 = 'X' (0x58)
```

The kernel returns `ENOENT` for the mangled name; the canonical
post-call error check (`cbnz w0, skip` / `cmp w0,#0 ; b.ne skip`)
takes the skip-cache path, so the cached "is_vmm" byte stays at its
initial 0 (stack pre-zeroed by `stur wzr` or BSS-zero for a global
`oldp`). Idempotent: a re-run can't find the unmangled cstring and
no-ops.

We don't touch executable code — only one byte of string data in
`__TEXT,__cstring`. The kernel call still happens (so sysctl
instrumentation still sees activity), it just fails the
name-to-MIB translation.

**What gets patched**

| Tier             | Scope                | Where applied                                             |
| ---------------- | -------------------- | --------------------------------------------------------- |
| DSC dylibs (20)  | Identity / store / consumer-services (see list above) | DSC chunks inside the SystemOS Cryptex DMG, while it is mounted on the host |
| Standalone (6)   | MobileActivationMigrator, CheckerBoard, StoreKitUISceneService, storekitd, appstored, CorePrescriptionService.xpc | Pulled from the device rootfs over SSH, patched, ldid-signed, pushed back |
| Compute / accel (10) | CoreML, Espresso, ANE, CoreRE, RenderBox, WebGPU, caulk, IOSurfaceAccelerator, HostInferenceProviderService | **Not patched** — leaving these alone preserves their VM-aware fast-path bypasses |

**Source files**

* `scripts/patchers/cfw_patch_hv_vmm.py` — standalone cstring patcher
  (`patch_hv_vmm(filepath)`): finds occurrences of `"kern.hv_vmm_present\0"`
  in `__cstring` (and the objc method/class name pools, for safety) and
  rewrites byte 0 from `'k'` to `'X'`.
* `scripts/patchers/cfw_dsc_chunks.py` — chunked-DSC byte-level helper:
  vmaddr ↔ chunk-fileoff mapping, executable-mapping cstring scan,
  byte read/write at a vmaddr, and Mach-O header walk-back to resolve
  a vmaddr to the containing dylib's install name.
* `scripts/patchers/cfw_patch_hv_vmm_dsc.py` — DSC-native orchestrator.
  No external `ipsw` dependency. For every `"kern.hv_vmm_present\0"`
  occurrence found in any executable mapping, walks back to the
  containing dylib's Mach-O header, reads `LC_ID_DYLIB`, and — if the
  install name is in the explicit `PATCH_INSTALL_NAMES` whitelist —
  rewrites the first byte of the cstring through
  `DSCChunks.write_at_vma`. After all whitelisted byte-mangles, calls
  `cfw_dsc_codesign.reattest_modified_pages` to recompute the SHA-256
  slot hash in the containing DSC chunk's `CS_CodeDirectory` for every
  affected 16 KiB page (see below — this is required on hardware with
  `codeSigningMonitor == 2`). The whitelist is one entry per line in
  the source file so an operator can comment out individual dylibs
  during bisection. (An earlier draft used `bl _sysctlbyname` →
  `movn w0,#0` instruction patching and an `ipsw dyld extract` path;
  both were scrapped — the former because it modifies executable
  bytes which has the same per-page-hash risk as the cstring approach
  but a larger surface area, and the latter because `ipsw` returns a
  Mach-O whose load-command file offsets reference the original DSC
  chunk's file layout, making it unparseable as a standalone Mach-O.)
* `scripts/patchers/cfw_dsc_codesign.py` — page-hash re-attestation.
  Without this pass, every byte-mangle invalidates the affected 16 KiB
  page's SHA-256 slot hash in the chunk-level `CS_CodeDirectory`. On
  iPhone17,3 / iOS 26.1 (`codeSigningMonitor == 2`), TXM enforces
  per-page integrity at demand-page-in (XNU defers exec-page
  validation to TXM for `csm_associated` mappings —
  `research/reference/xnu/osfmk/vm/vm_fault.c:2763-2780`). Concrete
  repro before re-attestation: `lsd-2026-05-11-035240.ips` faults
  inside MobileActivation's __TEXT at offset `0x13DC0`, in the same
  16 KiB page as the mangled cstring (offset `0x106C6`). The
  re-attestation rewrites only the 32-byte slot whose page contains
  a modified byte; the CDHash side-effect (CD blob hash changes
  when slots change) is accepted by TXM at DSC mount time
  (empirically verified — device boots with re-attested DSC).
* `scripts/patchers/cfw.py` — adds the `patch-hv-vmm-dsc <chunks_dir>`
  subcommand. (A `patch-hv-vmm <binary>` subcommand existed when this
  was written and no longer does: it and `cfw_patch_hv_vmm_rootfs.py`
  were removed in the blacklist-flip redesign, which made the
  standalone rootfs mangle unnecessary. See item 8 in
  `Research/0_binary_patch_comparison.md`.)
* `scripts/patch_hv_vmm_userland.sh` — thin wrapper used by the
  install scripts.
* `scripts/cfw_install_dev.sh` — DSC patch is applied while the
  SystemOS Cryptex DMG is still mounted on the host (inside step
  `[1/7]`); standalone binaries are patched over SSH in new step
  `[6.5/7]`.
* `scripts/cfw_install_jb.sh` — pre-step before invoking the
  regular `cfw_install.sh`: decrypts the SysOS Cryptex into the
  same cache file `cfw_install.sh` would, mounts it, applies the
  DSC patch, unmounts. The unmodified `cfw_install.sh` then sees
  the cached (already-patched) DMG. Standalone binaries are patched
  in new step `[EXP-JB-3.5]` after the base install completes (EXP variant only).

## Dylibs that must keep seeing VM=1 (graphics + accel passthrough)

Empirically validated: lying to these dylibs about VM presence breaks
the boot graphics path or the compute/accel fast paths. They MUST
read 1 (or the original truthful value) at runtime to function. Under
the new blacklist-flip design they are therefore NOT in
`DONT_PATCH_INSTALL_NAMES` — which means the byte-5 mangle IS applied
to their cstrings, they query the renamed kernel sysctl
`kern.Xv_vmm_present`, and the kernel returns 1 to them just like a
stock device would.

| Dylib                                                          | Why a lie breaks it                                                                                                                                                                                              |
| -------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `/usr/lib/libMobileGestalt.dylib`                              | Highest fan-in answer source. Forcing it to think "not a VM" sends the whole display-init chain into paths that demand real silicon display hardware.                                                            |
| `PrivateFrameworks/PhotoFoundation.framework/PhotoFoundation`  | Photos / image pipeline ties into the boot display path (asset decode + thumbnail rendering touches the same Metal surfaces the boot UI uses).                                                                   |
| `PrivateFrameworks/AirPlaySupport.framework/AirPlaySupport`    | AirPlay screen-mirroring plumbing registers as a display source at boot; lying about VM mode flips the registration path.                                                                                        |
| `PrivateFrameworks/VisionKitCore.framework/VisionKitCore`      | Camera / vision-intelligence stack hooks into the boot-time display chain on this device.                                                                                                                        |
| `Frameworks/CoreVideo.framework/CoreVideo`                     | Directly in the display pipeline — lying routes the boot display path through code that assumes physical capture surfaces.                                                                                       |
| `Frameworks/CoreML.framework/CoreML`                           | Compute fast-path. The VM-aware bypass is what prevents CoreML from trying to drive real ANE.                                                                                                                    |
| `PrivateFrameworks/Espresso.framework/Espresso`                | Same — neural-net inference dispatch.                                                                                                                                                                            |
| `PrivateFrameworks/AppleNeuralEngine.framework/AppleNeuralEngine` | ANE driver bring-up.                                                                                                                                                                                          |
| `PrivateFrameworks/CoreRE.framework/CoreRE`                    | Reality Engine dispatch.                                                                                                                                                                                         |
| `PrivateFrameworks/RenderBox.framework/RenderBox`              | Graphics dispatch.                                                                                                                                                                                               |
| `PrivateFrameworks/WebGPU.framework/WebGPU`                    | GPU dispatch.                                                                                                                                                                                                    |
| `PrivateFrameworks/caulk.framework/caulk`                      | HW codec dispatch.                                                                                                                                                                                               |
| `PrivateFrameworks/IOSurfaceAccelerator.framework/IOSurfaceAccelerator` | IOSurface accelerator dispatch.                                                                                                                                                                          |
| `ExtensionKit/Extensions/HostInferenceProviderService.appex/HostInferenceProviderService` | On-device ML inference host.                                                                                                                                                                  |

Under the new design these libs are not enumerated in code — they
implicitly fall into "not blacklisted → patched → sees VM=1" by
virtue of NOT being in `DONT_PATCH_INSTALL_NAMES`. To explicitly
exclude a different lib from the patch (force it to lie about VM
presence), add its install name to the blacklist. The build / install
flow is idempotent in re-attestation (`cfw_patch_hv_vmm_dsc.py` will
detect already-mangled cstrings on a re-run and re-sync slot hashes
for their pages), so toggling an entry in or out of the blacklist
doesn't require a fresh IPSW unpack — but doing so after a previous
install requires `rm -f vm/.cfw_temp/CryptexSystemOS.dmg` to force a
fresh DSC mount.

## What is verified vs. inferred

Verified by direct disassembly + Mach-O byte inspection:
* The 35 CANONICAL sites use `sysctlbyname("kern.hv_vmm_present", &int, &len, NULL, 0)`.
* The 4 entitlement-plist-only matches are pure plist substring hits.
* The 7 sandbox-profile-only matches are inside a compiled SBPL blob
  (string lives in `__TEXT,__const`, no executable xref, identical
  byte signature across the seven binaries).
* The 9 DEAD-string matches really are unreferenced (no ADRP/LDR
  computes the address; no 8-byte little-endian or 36-bit chained-fixup
  shape contains it).
* `SoundAnalysis` uses our string only as an offset anchor.

Inferred from framework / binary path and the canonical caching shape
(not from runtime tracing): the mapping in the table above of "what
each caller uses the result for". The disassembly proves *that* they
read the OID and how; it does not prove *what they branch on*. Every
"likely role" / "patching effect" claim above should be confirmed by
running the patched dylib and observing behaviour.
