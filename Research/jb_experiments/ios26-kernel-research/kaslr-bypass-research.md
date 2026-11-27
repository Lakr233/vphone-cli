# KASLR Bypass Research — iOS 26.6.1 (A18)

**Last updated:** 2026-11-16 (binary analysis complete)  
**Current status: AVE2 OOB read as KASLR confirmed DEAD (comparand-only). Host_stats uninit probe pending.**

---

## Summary Table

| Approach | CVE | Status | Killed by |
|----------|-----|--------|-----------|
| SysBumps TLB side-channel | CVE-2024-54531 | **DEAD** | SPTM blocks speculative TTBR1 walk on A18 |
| OOL descriptor stale sp+208 | "CVE-2026-65405" (mislabeled) | **DEAD** | 26.7.0-only code path, never in 26.6.1 |
| host_info/proc_info uninit residue | CVE-2026-65405 (real) | **Needs re-probe** | Probe incomplete — host_statistics section empty |
| AVE2 OOB read → VPS/SPS/PPS | CVE-2026-112466 | **DEAD** | Binary confirmed: OOB x8 is comparand-only, never stored |
| host_statistics64 uninit | CVE-2026-65405 (STAR Labs) | **Probe pending** | Re-probe with correct constants (job 95e4946f) |

---

## SysBumps — DEAD (killed Nov 13)

**CVE-2024-54531.** Exploits timing difference between TLB hits and misses on kernel virtual
addresses to infer which kernel pages are mapped, defeating KASLR.

**What we tried:**
- 7 syscalls used as probes: `chdir`, `access`, `stat`, `lstat`, `open`, `readlink`, raw `syscall(12)`
- Interleaved A/B comparison: scan known-mapped VA vs. unknown VA, alternating
- 1000 calls per batch, mach_absolute_time at 24MHz (41.67ns/tick)

**Result:** Median timing difference = 0 ticks. Range: [-1, +1] ticks across all conditions.

**Nov 7 false positive:** An earlier batch run showed 55–70 ticks vs. 47–53 ticks "gap". The
interleaved A/B method proved this was a monotonically decreasing warmup gradient — higher
address values happened to come later in the batch, not because of kernel mapping status.

**Root cause:** SPTM runs at EL2 and prevents speculative TLB walks of TTBR1_EL1 from EL0.
The fundamental timing oracle the attack relies on does not exist on A18/iOS 26.

---

## OOL Descriptor sp+208 — DEAD (killed Nov 16)

**Mislabeled as CVE-2026-65405 in earlier notes.** Not a real CVE on 26.6.1.

**Hypothesis:** `ipc_kmsg_copyout_ool_descriptor` in XNU stores a kernel pointer to `sp+208`
at some point during OOL message handling. If a helper function returns 0 (error path), sp+208
is never zeroed before the receive buffer is returned to userspace — leaking the kernel pointer.

**Binary analysis (Nov 16):** The vulnerable code path — a 260-byte block where a kernel
pointer from an internal table gets ORR'd into the user receive buffer — **does not exist in
iOS 26.6.1**. That block was introduced during 26.7.0 development and immediately patched
with `STR wzr, [sp, #0xd0]` before 26.7.0 shipped.

The `ipc_kmsg_copyout_ool_descriptor` in 26.6.1 (VA `0xfffffff00a66a518`, 4256 bytes):
- sp+208 is written with `xzr` (zero) or `w27` (user-controlled OOL size, 32-bit)
- sp+208 is **never read back** anywhere in the function
- No kernel pointer ever reaches sp+208

**Time spent:** ~3 hours chasing this across 3 probe versions. The lesson: verify
the vulnerable code path exists in the target kernel before probing.

---

## host_info / proc_info Uninit — Needs Re-Probe

**Real CVE-2026-65405.** Reporter: Billy Jheng Bing Jhong + Pan Zhenpeng (@Peterpan0927),
STAR Labs SG. Fixed in iOS 26.7 (Sep 14 2026). "An app may be able to determine kernel
memory layout." CWE-457: uninitialized variable.

**What we know:**
- Apple describes this as returning kernel pointer residue from an uninitialized struct field
- The API is host_info or proc_info (from STAR Labs attribution pattern — they typically find
  mach_host/task info leaks)
- The fix is "improved memory handling" in a kernel struct initialization
- Confirmed unpatched on 26.6.1 by Apple's advisory

**What we probed (probe: `kaslr_targeted.py`, Nov ~9):**
- `host_info` flavors 1–25: no kernel pointers
- `host_statistics` flavors 1–10: **empty section in log** — all flavors likely returned KERN_INVALID_ARGUMENT; this section was never actually tested
- `proc_info(callnum=2)` flavors 1–20: found `0xffffffff00000000` at offset +104 for flavors 2, 3, 18 — these are routing/CIDR sentinels (INADDR_BROADCAST pattern), NOT kernel text addresses
- `proc_info(callnum=3)` PIDFDINFO, callnum=4, etc.: empty sections in log
- `mach_vm_region_recurse`: section appeared empty (may have crashed)

**Problem with the probe:**
- Bounds used: `0xfffffff000000000 ≤ q ≤ 0xffffffffffffffff` (too broad, catches sentinels)
- `host_statistics64` and `mach_vm_region_recurse` sections never actually ran
- Probe did not test: `task_info` with extended flavors, `processor_info`, `mach_port_kernel_object`

**Re-probe needed:**
- Tighter kernel pointer bounds: `0xfffffff000000000 ≤ q ≤ 0xfffffff0ffffffff` (kernel text range)
- Test `host_statistics64` explicitly (call it with try/except, log every KERN_* error code)
- Two-pass: run same API twice, compare values — randomized value = KASLR leak
- Target struct sizes just above what the kernel says the struct is (probe for padding beyond declared size)

---

## AVE2 OOB Read → VPS/SPS/PPS — DEAD (killed Nov 16, binary analysis)

**CVE-2026-112466.** Hcamael + 章鱼哥@aipy. OOB read in `AVEVideoEncoder`.
Apple impact: "Terminate OR **read kernel memory**". Fix: "Improved input validation".
Patched in iOS 26.7.2. **Bug is live on 26.6.1 — but NOT usable as KASLR.**

### Root cause (confirmed by Capstone disassembly, 2026-11-16)

**Bug setter** — in func39 at file offset `0x14540`:
```asm
sub w8, w0, #1          ; w8 = NTL - 1
str w8, [x1, #0x28]     ; cmd->field_0x28 = NTL-1  ← NO BOUNDS CHECK
```
For NTL=16463: slot=16462=0x3FEE. Slot arithmetic gives OOB offset=0x7FDC8 (~492KB past slot table).

**Bug read site** — in `AVE_DLB::AssignUnitPreempt` (file `0x15057c`, VA `0xfffffff00853aa2c`):
```asm
func+0x31c:  ldr w11, [x20, #0x28]    ; w11 = cmd->field_0x28  UNVALIDATED SLOT
func+0x324:  orr x11, x12, x11, lsl #5
func+0x328:  cmp x11, w11, sxtw       ; only checks bit-31 overflow (passes for slot=16462)
func+0x33c:  ldr x8, [x12]            ; ← OOB READ: x8 = *(slot_table_base + 0x7FDC8)
func+0x340:  cmp x10, x8              ; ← COMPARAND ONLY
```

### Why this cannot leak a kernel pointer

The 64-bit OOB-read value (a kernel heap pointer from adjacent EU table memory) is:
1. Loaded into x8
2. Used ONLY as comparand: `cmp x10, x8` (x10 = legitimate slot count)
3. **Never stored** to any output buffer or cmd struct field

Since a kernel VA like `0xfffffff0...` is always > any 32-bit count x10, the fall-through
path always runs. Fall-through stores `x9[0]` (a 32-bit temporal layer count from the
**legitimate** slot table object, not from OOB memory) to `cmd->field_0x50`.

The HEVC VPS/SPS/PPS bytes contain 32-bit temporal layer metadata — not kernel addresses.
Probe `probe_ave2_sbuf_v2.py` (job 88942b35) is running to confirm empirically.

### Fix location

AssignUnitPreempt is **logically identical** in 26.7.2 (3987 instructions, only
ADRP/BL address operands differ). The NTL-setter (`str w8, [x1, #0x28]`) also unchanged.
One upstream caller found in both versions; structurally identical. Fix is likely in XNU
IOUserClient dispatch layer or VideoToolbox.framework userspace (not in AVE2 kext).

### What the OOB IS useful for

The double-dereference pattern at func+0x44c:
```asm
func+0x44c:  ldr x8, [x10]    ; *OOB_ptr (64-bit kernel heap pointer)
func+0x450:  ldr w8, [x8]     ; *x8 (32-bit dereference of that pointer)
func+0x460:  str w8, [x25]    ; stored to output field (arg6)
```
If the OOB slot points to controlled kernel heap (requires prior heap spray → requires KASLR),
this could achieve an **arbitrary 32-bit read** of kernel memory. This is the basis for
CVE-2026-112468/469/470, but all require KASLR first.

---

## host_statistics64 Uninit — Probe Pending

**Real CVE-2026-65405.** Reporter: Billy Jheng Bing Jhong + Pan Zhenpeng (@Peterpan0927),
STAR Labs SG. Fixed in iOS 26.7 (Sep 14 2026). "An app may be able to determine kernel
memory layout." CWE-457: uninitialized variable.

**What we know:**
- Apple describes this as returning kernel pointer residue from an uninitialized struct field
- The API is likely host_statistics64 or task_info (from STAR Labs attribution pattern)
- The fix is "improved memory handling" in a kernel struct initialization
- Confirmed unpatched on 26.6.1 by Apple's advisory

**What we probed (probe: `kaslr_targeted.py`, Nov ~9):**
- `host_statistics` section in log: **completely empty** — all flavors failed silently
- Root cause: probe used wrong constants (integers 1-10 instead of Mach constants)
- `proc_info` hits at `0xffffffff00000000` — routing/CIDR sentinels, false positives

**Re-probe (`probe_host_stats_uninit.py`, job 95e4946f):**
- Uses correct Mach constants: `HOST_VM_INFO64=4`, `HOST_EXTMOD_INFO64=5`, etc.
- Pre-fills buffers with `0xCC` to detect partial initialization
- Covers `host_statistics64`, `host_info`, `task_info`, `mach_zone_info`, sysctl variants
- Submitted 2026-11-16, device suspended — results pending

**Additional probe (`probe_kaslr_v3.py`, job 28558ac5):**
- `mach_port_kobject` — may return kernel VA of port object directly
- `getsockopt` struct padding — uninit bytes in large structs
- Network stats sysctl sweep
- Submitted 2026-11-16, queued

---

## Notes on the 26.6.1 KASLR Landscape

As of November 2026, no public KASLR bypass exists for iOS 26.6.1 on A18. The public
jailbreak landscape:
- **Dopamine 3.0 / Momentarius**: A12/A13 only, iOS 26.0–26.0.1
- **Titan**: A14–A17, iOS 16.5.1–17.3.1 only (AGX hibernation trick, patched in 17.4b4)
- **No public A18/iOS 26 bypass**

This means our chain must implement its own KASLR bypass — AVE2 OOB read is the current
best candidate. CVE-2026-65405 (STAR Labs) is the backup if the AVE2 path causes a panic
rather than a silent read.
