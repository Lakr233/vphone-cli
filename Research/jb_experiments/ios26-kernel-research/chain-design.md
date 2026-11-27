# Exploit Chain Design — iOS 26.6.1 (A18)

**Last updated:** 2026-11-16  
**Target:** iPhone 16 Plus (iPhone17,4, D48AP), iOS 26.6.1 (23G83), A18

---

## ⚠️ Dead Ends (as of Nov 16)

| Approach | Status | Killed |
|----------|--------|--------|
| CVE-2026-86916 IGMP UAF | **IGMP attribution DEAD** | Patched in 26.7/27.0 (advisory). The CVE itself is a Kernel UAF («execute arbitrary code with kernel privileges», Wang Yu) still open on 23F84 — site unknown; see `../10_cve_2026_86916_site.md` (correction 2026-11-27). 21M+ multicast ops, zero anomalies. NOT confirmed on 23F84 vs 24B156: `igmp_input_v3_query` CAS-unlock at +0x570 is present in both builds (see `../10_cve_2026_86916_site.md`). |
| SysBumps KASLR (CVE-2024-54531) | **DEAD** | SPTM blocks speculative TTBR1 walk on A18. Nov 7 "result" was batch warmup artifact — interleaved A/B shows zero signal. |
| CVE-2026-65405 OOL descriptor sp+208 | **DEAD** | 26.7.0-only code path. The vulnerable 260-byte block was introduced AND patched in 26.7.0. The 26.6.1 target never had it. |
| CVE-2026-43743 IOGPU race | **DEAD** | UAF triggerable, but all vtable dispatch calls are PAC-signed (discriminants 0xdd4e, 0x4664, 0x43af). Post-UAF exploitation blocked. |
| AVE2 DPB OOB write (NTL=2057) | **DEAD** | DART IOMMU raises DARTHwException at the kext boundary. Empirically confirmed with 0xAA pre-fill detection: 16 victim surfaces unchanged after NTL=2057 encode. |

---

## Current Architecture (Nov 16)

```
AVE2 AssignUnitPreempt OOB Read
  (CVE-2026-112466)
  NTL=16463 + {RCMode:20, EncoderUsage:1}
       |
       v
  OOB ldr x8, [eu_base + 8 + 32*OOB_SLOT]
  (CPU-side kernel read — NOT DART)
       |
       v [value may flow into HEVC VPS/SPS/PPS NAL units]
  CMSampleBuffer callback → kernel VA in VPS bytes
       |
       v
  KASLR slide = leaked_va - known_unslid_base    [UNCONFIRMED]
       |
       +─────────────────────────────────────────+
       |                                          |
       v                                          v
  ICMP6_FILTER write (confirmed)        AVE2 OOB write path
  → target: ucred uid/gid → root        (CVE-2026-112468/469/470)
                                         → heap spray → kernel R/W
                                         → physmap SpringBoard __DATA
                                         → IMP overwrite → battery tweak
```

---

## Stage-by-Stage

### Stage 1: AVE2 OOB — CVE-2026-112466 / 112468–470

**Primary path.** Two distinct AVE2 primitives, both unpatched on 26.6.1 (patched in iOS 26.7.2).

#### 1a: OOB Read — CVE-2026-112466 (KASLR bypass candidate)

Trigger: HEVC 1280×720 VTCompressionSession with:
- `encoderSpec = {RCMode: 20, EncoderUsage: 1}`
- `NumberOfTemporalLayers = 16463`

Vulnerable code in `AVE_DLB::AssignUnitPreempt` at kext offset `0x53a6d8`:
```asm
0x53aa0c: ldr w11, [x20, #0x28]         ; slot = cmd->field_0x28  ← UNVALIDATED
0x53aa14: orr x11, x12, x11, lsl #5     ; x11 = 8 | (slot<<5)
0x53aa20: add x16, x8, x11              ; eu_base + 8 + 32*slot
0x53aa2c: ldr x8, [x12]                 ; ← OOB READ at eu_base + 8 + 32*OOB_SLOT
0x53aa30: cmp x10, x8                   ; bounds check is AFTER the read
```

When `cmd->field_0x28 == 0` → underflow to 0xFFFFFFFF → massive OOB offset.
Value at `eu_base + 8 + 32*OOB_SLOT` is an adjacent kernel heap pointer.

**KASLR bypass hypothesis:** ~~The OOB-read value flows into HEVC VPS/SPS/PPS via CMSampleBuffer.~~

**STATUS: DEAD AS KASLR BYPASS (Nov 16, binary analysis)**

Binary analysis of AssignUnitPreempt (file offset 0x150228, 26.6.1 target kext):
- OOB-read value x8 at 0x53aa2c is used ONLY in `cmp x10, x8`
- Immediately overwritten on BOTH branch paths:
  - b.ge NOT taken: `ldr w8, [x9]` at 0x53aa3c overwrites x8 (32-bit count)
  - b.ge taken: `ldr w8, [x20, #0x50]` at 0x53aa64 overwrites x8
- Neither path stores the OOB value to any output buffer or x25 (arg6/output)
- VPS/SPS/PPS are NOT constructed in this function

The OOB value only controls a branch direction — no data flow to userspace.

Apple's advisory "read kernel memory" = the kernel kext reads OOB (a defect in kernel
code that could expose internal kernel state to the KERNEL, not to the attacker).

**Code change note:** The csel-based protection already present in 26.6.1 kext prevents
slot = 0xFFFFFFFF from reaching the read (poison path causes fault instead). The actual
"fix" for 26.7.2 is upstream — in NTL input validation before the encode pipeline.

**Probe `probe_ave2_sbuf_v2.py` (job 2aa266c9):** Expected result — no kernel pointers
in VPS/SPS/PPS bytes. If NTL=16463 → slot=0xFFFFFFFF: device will panic instead.

#### 1b: OOB Write — CVE-2026-112468/469/470 (kernel corruption)

Same `AssignUnitPreempt` path, write side. After the OOB read at 0x53aa2c, the
loaded value is used as a pointer and dereferenced for a store. Since the OOB-read
value itself cannot be a valid kernel pointer without a prior KASLR bypass, this path
requires KASLR + heap shaping to suppress the panic.

**Status: SECONDARY** — depends on a KASLR bypass from another source.

**Apple's fix (iOS 26.7.2):** "Improved bounds checking" for 112468/469/470 — the
three CVEs correspond to three distinct buffer types that share the same overflow logic.

---

### Stage 2: KASLR Defeat

**CVE-2026-112466 as KASLR bypass: DEAD (Nov 16)**

Binary analysis confirmed the OOB-read value does NOT reach userspace. See Stage 1a.

**Primary candidate: CVE-2026-65405 (host_info/proc_info uninit, STAR Labs)**

**Secondary candidate: CVE-2026-65405 (host_info/proc_info uninit)**

Reporter: Billy Jheng Bing Jhong + Pan Zhenpeng (@Peterpan0927), STAR Labs SG.
Fixed in iOS 26.7, confirmed unpatched on 26.6.1.
"An app may be able to determine kernel memory layout" — CWE-457 uninitialized variable.

Prior sweep of host_info (flavors 1–25), host_statistics64 (flavors 1–15), proc_info
(callnum=2 all flavors) found only `0xffffffff00000000` (routing/netmask sentinels, NOT
kernel text addresses). The `host_statistics` section returned empty — all flavors may
have errored. Needs targeted re-probe against specific struct padding fields.

See [kaslr-bypass-research.md](kaslr-bypass-research.md) for full history.

---

### Stage 3: Kernel Write — CONFIRMED

**ICMP6_FILTER write primitive.**

`setsockopt(IPPROTO_ICMPV6, ICMP6_FILTER, 32B)` writes exactly 32 bytes to
`*in6p_icmp6filt`. The kernel copies 32 bytes of attacker-controlled data to the address
stored in `in6p_icmp6filt`.

- **Target field:** `in6p_icmp6filt` in `struct in6pcb`
- **Write size:** exactly 32 bytes
- **PAC status:** no PAC on the write path — confirmed binary
- **Sandbox:** reachable from app sandbox (DGRAM IPPROTO_ICMPV6 socket works)
- **Confirmed on device:** Nov 15, `probe_icmp6_write.py`

**Without KASLR:** cannot aim this at a useful target.  
**With KASLR:** redirect `in6p_icmp6filt` → `ucred` uid/gid fields (root) or any 32-byte
target within reach.

**Alternative write path (requires AVE2 OOB write working):**

AVE2 OOB write (Stage 1b) → heap spray adjacent `kalloc.512` objects → control OOB-write
destination → arbitrary kernel memory write → physmap → SpringBoard `__DATA` IMP overwrite.

---

### Stage 4: Post-Exploitation — Battery Icon Tweak

**Injection target: SpringBoard**, not backboardd. The status bar battery icon is rendered
in SpringBoard by `_UIStatusBarBatteryView` (UIKit) and `STUIStatusBarBatteryItem`
(SpringBoardDisplay.framework, iOS 26 Liquid Glass).

**Hook targets:**
```objc
-[_UIStatusBarBatteryView _batteryFillColor]      // change fill color
-[_UIStatusBarBatteryView setChargePercent:]       // intercept percentage
-[STUIStatusBarBatteryItem applyUpdate:toDisplayItem:]  // full data pipeline
```

**Mechanism (data-only, SPTM-safe):**

SPTM (EL2) blocks kernel→text page-type transitions. But SpringBoard's `__DATA` segment
is `XNU_DEFAULT` (writable from EL1 via physmap). ObjC IMPs are stored as function
POINTERS in `__DATA` — overwriting them does not create new executable pages.

```
1. KASLR defeat → compute SpringBoard's __DATA VA
2. AVE2 OOB write (or ICMP6_FILTER) → kernel R/W primitive
3. physmap: VA → PA → write ObjC IMP pointer for _batteryFillColor
4. IMP → ROP/JOP gadget in existing SpringBoard/UIKit text → custom payload
```

**Direct ICMP6_FILTER path (simpler):**

With KASLR + `in6p_icmp6filt` redirect:
```
1. Find ucred for ResearchHost/SpringBoard process
2. ICMP6_FILTER 32B write → overwrite uid/gid = 0 (root)
3. Use root to load tweak via launchd or dylib injection
```

---

## Status Summary (Nov 16)

| Component | Status |
|-----------|--------|
| AVE2 OOB trigger (NTL=16463) | Probe submitted — awaiting results |
| AVE2 OOB → KASLR via VPS/SPS/PPS | **Unconfirmed** — leading candidate |
| ICMP6_FILTER write primitive | **Confirmed** on device |
| getsourcefilter read ops | Confirmed API, but needs UAF to corrupt tree |
| KASLR bypass | **Blocked** — no confirmed bypass yet |
| Sandbox escape (worse_query) | Confirmed — orthogonal to kernel chain |

## Device

- iPhone 16 Plus (iPhone17,4, D48AP)
- iOS 26.6.1 (23G83)
- A18 (SPTM + TXM + PAC)
- Kernelcache: `__TEXT_EXEC` at VA `0xfffffff008284000`, fileoff `0x01280000`
