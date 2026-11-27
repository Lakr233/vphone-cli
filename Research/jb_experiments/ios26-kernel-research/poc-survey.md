# Recent PoC Survey — November 2026

**Date:** 2026-11-13  
**Scope:** Public PoCs and disclosures for iOS 26/27 (Oct–Nov 2026)

## CVE-2026-65343 — AppleKeyStore OOB Read

**Component:** AppleKeyStore, `_LibSer_SEPControl_Deserialize`  
**Bug:** `declared_length` from ACM message not validated against `remaining`. Setting
`declared_length=0x800` → copyout reads ~0x7E8 bytes past buffer into adjacent kernel heap.  
**Impact:** Kernel pointer leak → KASLR defeat.  
**Patched:** iOS 26.6.1 (our version).  
**Trigger:** Requires `IOServiceOpen("AppleKeyStore")` — sandbox-blocked.

**Notable technique:** DYLD_INTERPOSE still works on iOS 26 (`__DATA,__interpose` section
processed at image-load time before `__DATA_CONST` is locked). fishhook is dead (GOT is
read-only before code runs).

Repo: ByteV0rtex/CVE-2026-65343

## CVE-2026-112705 — AppleAVE2 Temporal Layers OOB Write

**Component:** AppleAVE2 (`com.apple.driver.AppleAVE2`)  
**Bug:** `NumberOfTemporalLayers` not bounded before array index use. NTL=16463 panics.  
**Impact:** Kernel data abort in AppleAVE2+0xDA78.  
**Target:** iOS 27 only (A19/T8150). Crashes `videocodecd`, not the app.

**Notable:** From the Calif team who demoed untethered iOS 27.0.1 jailbreak at Hexacon
(Oct 16, 2026). The PoC (Runner.swift) is a 977-line masterclass in systematic VideoToolbox
encoder property fuzzing across 21 stages.

Repo: MchinaMd57764/AVETemporalPoC-CVE-2026-112705

## CVE-2026-43805 — IODMACommand Race Condition

**Component:** IODMACommand (in XNU kernel body)  
**Bug:** `PerformOperation_Impl` missing lock while `PrepareForDMA_Impl` and
`CompleteDMA_Impl` share one. Classic TOCTOU.  
**Fix:** Added `IOLockLock`/`IOLockUnlock` + state re-check.  
**CVSS:** 9.8  
**Patched:** macOS Tahoe 26.6.

**Notable technique: KDK binary diffing.** Author downloaded Tahoe 26.5 and 26.6 Kernel
Debug Kits (x86_64, WITH symbols), loaded into Ghidra, used Version Tracking to match
functions and spot the missing lock. Much easier than reversing stripped ARM64 kernelcaches.

Repo: whysocscs/CVE-2026-43805

## CVE-2026-20687 — AppleJPEGDriver UAF

**Component:** AppleJPEGDriver  
**Bug:** `startDecoder` timeout path frees `JpegRequest` but doesn't dequeue embedded queue
node at `req+0x78`. Also: `terminatePhase1` sets `isInactive()` via arbitration lock (not
command-gated), causing `finish_io_gated` to skip `taggedRelease` → retain leak.  
**Object:** JpegRequest = 0x440 (1088 bytes), pool-allocated.  
**Patched:** iOS 26.4.

### JpegRequest Layout (reversed)
```
+0x00:  task_t              ← vtable-like: *(*(req+0)+40)() = PC control
+0x08:  IOUserClient*
+0x78:  queue link node      (embedded, at driver self+192)
+0x80:  self-pointer         ← FIRST UAF read
+0x310: flags byte           ← SECOND UAF read
```

### IOKit UAF Exploitation Pattern
```
1. Spray:    Submit N async decode requests (taggedRetain per request)
2. Free:     Close connection → terminatePhase1 → isInactive early
3. Stale:    In-flight HW jobs → finish_io_gated → skip taggedRelease → leaked retain
4. Reclaim:  Open new connections / mach_msg OOL descriptors (size 0x440)
5. Trigger:  fullSpeedRequestExist() walks stale queue → dereferences freed memory
```

This pattern maps directly to IGMP UAF exploitation.

Repo: (CVE-2026-20687-AppleJPEGDriver-UAF)

## Other Notable

### Calif iOS 27.0.1 Untethered Jailbreak
- Demonstrated at Hexacon Paris, Oct 16, 2026
- iPhone 18 Pro (A19), iOS 27.0.1
- Survives reboot, root SSH confirmed on stage
- No technical details published

### DarkSword Exploit Kit
- Google TAG, March 2026
- 6-CVE chain including 3 zero-days
- PAC/TPRO bypass via CVE-2026-20700 (see [modern-pac-bypasses.md](modern-pac-bypasses.md))
- Fixed in iOS 26.1/18.7.2

## Key Takeaways

The JPEG driver PoC is the most valuable for our work. Its exploitation pattern
(submit-async → close-early → reclaim → trigger-stale) is a template for any IOKit UAF,
including our IGMP target. The OOL `mach_msg` spray and health-check patterns are
directly applicable.

The KDK diffing technique from the IODMACommand analysis is the right approach for future
kernel bug hunting: get macOS KDKs with symbols, diff there, then port to ARM64.
