# B19 `patch_io_secure_bsd_root` — 2026-03-06 reanalysis

## Scope

- Kernel used for live reverse-engineering: `kernelcache.research.vphone600`
- Kernel file used locally: `/Users/qaq/Documents/Firmwares/PCC-CloudOS-26.3-23D128/kernelcache.research.vphone600`
- Base VA: `0xFFFFFE0007004000`
- Ground-truth sources for this note:
  - IDA-MCP on the loaded research kernel
  - recovered symbol datasets in `research/kernel_info/json/`
  - open-source XNU in `research/reference/xnu`

This document intentionally discards earlier B19 writeups as untrusted and restarts the analysis from first principles.

## Executive Conclusion

`patch_io_secure_bsd_root` was previously targeting the wrong branch.

The disabled historical patch at `0xFFFFFE000836E1F0` / file offset `0x0136A1F0` does **not** patch the `"SecureRootName"` policy result used by `IOSecureBSDRoot()`. Instead, it patches the earlier `"SecureRoot"` name-match gate inside `AppleARMPE::callPlatformFunction`, which changes generic platform-function dispatch semantics and is a credible root cause for the early-boot failure.

The semantically correct deny path for the `IOSecureBSDRoot(rootdevice)` flow is the `"SecureRootName"` branch in `AppleARMPE::callPlatformFunction`, specifically the final return-value select at:

- VA: `0xFFFFFE000836E464`
- file offset: `0x0136A464`
- before: `f613891a` / `CSEL W22, WZR, W9, NE`
- recommended after: `16008052` / `MOV W22, #0`

That patch preserves the compare, callback, wakeup, and state updates, and only forces the final policy return from `kIOReturnNotPrivileged` to success.

## Implementation Status

- `scripts/patchers/kernel_jb_patch_secure_root.py` was retargeted on 2026-03-06 to emit this `0x0136A464` patch instead of the historical `0x0136A1F0` false-positive branch rewrite.
- `scripts/patchers/kernel_jb.py` now includes `patch_io_secure_bsd_root` again in `_GROUP_B_METHODS` with the retargeted matcher.
- Local dry-run verification on the research kernel emits exactly one write: `0x0136A464` / `16008052` / `mov w22, #0 [_IOSecureBSDRoot SecureRootName allow]`.

## Verified Call Chain

### 1. BSD boot calls `IOSecureBSDRoot`

IDA shows `bsd_init` calling `IOSecureBSDRoot` here:

- `bsd_init` call site: `0xFFFFFE0007F7B7C4` / file offset `0x00F777C4`
- instruction: `BL IOSecureBSDRoot`

The nearby boot flow is:

1. `IOFindBSDRoot`
2. `vfs_mountroot`
3. `IOSecureBSDRoot(rootdevice)`
4. `VFS_ROOT(...)`
5. later `FSIOC_KERNEL_ROOTAUTH`

This matches open-source XNU in `research/reference/xnu/bsd/kern/bsd_init.c`, where `IOSecureBSDRoot(rootdevice);` appears before `VFS_ROOT()` and well before the later root-authentication ioctl.

### 2. `IOSecureBSDRoot` calls platform expert with `"SecureRootName"`

Recovered symbol + IDA decompilation:

- `IOSecureBSDRoot`: `0xFFFFFE0008297FD8` / file offset `0x01293FD8`
- research recovered symbol: `IOSecureBSDRoot`
- release recovered symbol: `IOSecureBSDRoot` at `0xFFFFFE000825FFD8`

The decompiled logic is straightforward:

1. build `OSSymbol("SecureRootName")`
2. wait for `IOPlatformExpert`
3. call `pe->callPlatformFunction(functionName, false, rootName, NULL, NULL, NULL)`
4. if result is `0xE00002C1` (`kIOReturnNotPrivileged`), call `mdevremoveall()`

Open-source XNU confirms the intended semantics in `research/reference/xnu/iokit/bsddev/IOKitBSDInit.cpp`:

- `"SecureRootName"` is the exact function name
- `kIOReturnNotPrivileged` means the root device is not secure
- on that return code, `mdevremoveall()` is invoked

`mdevremoveall()` in `research/reference/xnu/bsd/dev/memdev.c` removes `/dev/md*` devices and clears the memory-device bookkeeping, so this path is directly relevant to ramdisk / custom-root boot flows.

### 3. The real secure-root decision is made in `AppleARMPE::callPlatformFunction`

Relevant function:

- `AppleARMPE::callPlatformFunction`: `0xFFFFFE000836E168` / file offset `0x0136A168`

Within this function, there are **two different** string-based branches that matter:

#### A. `"SecureRoot"` branch — callback/control path

At:

- `0xFFFFFE000836E1EC`: `BLRAA` to `a2->isEqualTo("SecureRoot")`
- `0xFFFFFE000836E1F0`: `CBZ W0, loc_FFFFFE000836E394`

If the name matches `"SecureRoot"`, the function enters a branch that:

- waits on byte flag `[a1+0x118]`
- may call `"SecureRootCallBack"`
- sets / wakes byte flag `[a1+0x119]`
- optionally returns a boolean via `a5`

This is **not** the direct `IOSecureBSDRoot(rootName)` policy result.

#### B. `"SecureRootName"` branch — actual policy decision path

At:

- `0xFFFFFE000836E3C0`: `BLRAA` to `a2->isEqualTo("SecureRootName")`
- `0xFFFFFE000836E3C4`: `CBZ W0, loc_FFFFFE000836E46C`

Then:

- `0xFFFFFE000836E3D4`: call helper that behaves like `strlen`
- `0xFFFFFE000836E3E4`: call helper that behaves like `strncmp`
- `0xFFFFFE000836E3E8`: `CMP W0, #0`
- `0xFFFFFE000836E3EC`: `CSET W8, EQ`
- `0xFFFFFE000836E3F0`: store secure-match bit to `[a1+0x11A]`
- wake waiting threads / synchronize callback state
- `0xFFFFFE000836E450`: reload `[a1+0x11A]`
- `0xFFFFFE000836E454`: load `W9 = 0xE00002C1`
- `0xFFFFFE000836E464`: `CSEL W22, WZR, W9, NE`

That final `CSEL` is the actual deny/success selector for the `"SecureRootName"` request:

- secure match -> return `0`
- mismatch -> return `0xE00002C1` / `kIOReturnNotPrivileged`

## Why the Historical Patch Is Wrong

### Root cause 1: live patcher has no symbol table to use

Running the existing `KernelJBPatcher` locally against the research kernel shows:

- `symbol_count = 0`
- `_resolve_symbol("_IOSecureBSDRoot") == -1`
- `_resolve_symbol("IOSecureBSDRoot") == -1`

So the current code always falls back to a heuristic matcher on this kernel.

### Root cause 2: the fallback heuristic picks the first `BL* + CBZ W0` site

The current fallback logic looks for a function referencing both `"SecureRoot"` and `"SecureRootName"`, then selects the first forward conditional branch shaped like:

- previous instruction is `BL*`
- current instruction is `CBZ/CBNZ W0, target`

That heuristic lands on:

- `0xFFFFFE000836E1F0` / `CBZ W0, loc_FFFFFE000836E394`

But this site is only the result of `isEqualTo("SecureRoot")`. It is **not** the final policy-return site for `"SecureRootName"`.

### Root cause 3: the old patch changes dispatch routing, not just the deny return

Historical patch:

- before: `200d0034` / `CBZ W0, loc_FFFFFE000836E394`
- after: `69000014` / `B #0x1A4`

Effect:

- previously: only true `"SecureRoot"` requests enter the `SecureRoot` branch
- after patch: non-`"SecureRoot"` requests are also forced into that branch

Because this is inside generic `AppleARMPE::callPlatformFunction` dispatch, the patch can corrupt the control flow for unrelated platform-function calls that happen to reach this portion of the function. That is much broader than “skip secure-root denial” and is consistent with a boot-time regression.

## What This Patch Actually Does

`patch_io_secure_bsd_root` does **not** replace the later sealed-root / root-authentication gate in `bsd_init`.

What it actually controls is earlier and narrower:

1. determine whether the chosen BSD root name is platform-approved (`"SecureRootName"`)
2. if not approved, return `kIOReturnNotPrivileged`
3. `IOSecureBSDRoot()` maps that failure into `mdevremoveall()`

So the practical effect of a correct B19 bypass is:

- allow a non-approved/custom BSD root name to survive the platform secure-root policy step
- avoid the `kIOReturnNotPrivileged -> mdevremoveall()` failure path
- keep the rest of the boot moving toward `VFS_ROOT` and the later rootauth check

This is why B19 and `patch_bsd_init_auth` are separate methods: they handle different stages of the boot chain.

## Recommended Patch Strategy

### Preferred site: final `"SecureRootName"` return select

Patch only the final result selector:

- VA: `0xFFFFFE000836E464`
- file offset: `0x0136A464`
- before bytes: `f613891a`
- before asm: `CSEL W22, WZR, W9, NE`
- after bytes: `16008052`
- after asm: `MOV W22, #0`

Why this site is preferred:

- preserves the string comparison logic
- preserves the `SecureRootCallBack` synchronization / wakeup handshake
- preserves the state bytes at `[a1+0x118]`, `[a1+0x119]`, `[a1+0x11A]`
- changes only the final deny-vs-success return value

### Secondary option: force the secure-match bit before the final select

- VA: `0xFFFFFE000836E3EC`
- file offset: `0x0136A3EC`
- before bytes: `e8179f1a`
- before asm: `CSET W8, EQ`
- after bytes: `28008052`
- after asm: `MOV W8, #1`

This is broader than the preferred patch because it changes the stored secure-match state itself, not just the returned result.

### Tertiary option: suppress only `IOSecureBSDRoot()` cleanup

There is also a coarser site in `IOSecureBSDRoot` itself:

- `0xFFFFFE0008298144`: compare against `0xE00002C1` followed by `B.NE`

That site can suppress `mdevremoveall()` without touching `AppleARMPE::callPlatformFunction`, but it is less attractive because it leaves the underlying `"SecureRootName"` failure semantics intact and only masks the wrapper-side cleanup.

## Safer Matcher Recipe For Future Python Rework

If/when the Python patcher is reworked, the fallback should stop selecting the first `BL* + CBZ W0` site in the shared function.

A safer matcher for stripped kernels is:

1. locate the function referencing both `"SecureRoot"` and `"SecureRootName"`
2. inside that function, find the `"SecureRootName"` equality check block, not the `"SecureRoot"` block
3. from there, require the sequence:
   - helper call 1 (length)
   - helper call 2 (compare)
   - `CMP W0, #0`
   - `CSET W8, EQ`
   - store to `[X19,#0x11A]`
   - later `MOV W9, #0xE00002C1`
   - final `CSEL W22, WZR, W9, NE`
4. patch only that final `CSEL`

This gives a unique, semantics-aware patch site for the actual deny return.

## Local Reproduction Notes

Local dry analysis of the current patcher on the research kernel produced:

- `fallback_func = 0x136a168`
- emitted patch = `(0x0136A1F0, 69000014, 'b #0x1A4 [_IOSecureBSDRoot]')`

This reproduces the disabled historical behavior and confirms that the current implementation does not yet target the correct deny site.

## Confidence

- Confidence that the historical patch site is wrong: **high**
- Confidence that `0xFFFFFE000836E464` is the correct minimal deny-return site: **high**
- Confidence that this alone is sufficient for full jailbreak boot: **medium**

The last item stays `medium` because B19 only addresses the secure-root platform policy stage; it does not replace the later root-auth/sealedness work handled elsewhere.
