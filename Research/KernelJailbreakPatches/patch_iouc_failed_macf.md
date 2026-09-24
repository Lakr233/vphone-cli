# A5 `patch_iouc_failed_macf`

## Status

- Re-analysis date: `2026-03-06`
- Current conclusion: the historical repo A5 entry early-return is rejected as over-broad, but A5-v2 is now rebuilt as a narrow branch-level patch at the real post-MACF deny gate.
- Current repository behavior: `patch_iouc_failed_macf` is active again with the strict A5-v2 matcher.

## Patch Goal

Bypass the shared IOUserClient MACF deny gate that emits:

- `IOUC AppleAPFSUserClient failed MACF ...`
- `IOUC AppleSEPUserClient failed MACF ...`

This gate blocks `mount-phase-1` and `data-protection` (`seputil`) in current JB boot logs.

## Historical Repo Hit (rejected)

- Anchor string: `"failed MACF"`
- Candidate function selected by anchor xref + IOUC co-reference:
  - function start: `0xfffffe000825b0c0`
- Historical patch points:
  - `0xfffffe000825b0c4`
  - `0xfffffe000825b0c8`

## Why The Historical Repo Patch Is Rejected

- IDA decompilation shows `0xfffffe000825b0c0` is a large IOUserClient open / setup path, not a tiny standalone MACF helper.
- That function also prepares output state (`a7` / `a8` in decompilation) before returning to its caller.
- The historical repo patch overwrote the first two instructions after `PACIBSP` with `mov x0, xzr ; retab`, which forces an immediate success return before that wider setup work happens.
- Therefore the old patch is broader than the actual MACF deny branch and is not a good upstream-aligned design.

## Pseudocode (Before)

```c
int iouc_macf_gate(...) {
    // iterate policy callbacks, run MACF checks
    // on deny: log "failed MACF" and return non-zero error
    ...
}
```

## Narrow Branch (current A5-v2 target)

```c
// inside sub_FFFFFE000825B0C0
ret = mac_iokit_check_open(...);
if (ret != 0) {
    IOLog("IOUC %s failed MACF in process %s\n", ...);
    error = kIOReturnNotPermitted;
    goto out;
}
```

Current IDA-validated branch window:

- `0xfffffe000825ba94` — `BL sub_FFFFFE00082EB07C`
- `0xfffffe000825ba98` — `CBZ W0, loc_FFFFFE000825BB0C`
- `0xfffffe000825baf8` — `ADRL X0, "IOUC %s failed MACF in process %s\n"`

A5-v2 patches exactly this gate by replacing `CBZ W0, loc_FFFFFE000825BB0C` with unconditional `B loc_FFFFFE000825BB0C`.

## Why This Patch Was Added

- Extending sandbox hooks to cover `ops[201..210]` was not sufficient.
- Runtime still showed both:
  - `IOUC AppleAPFSUserClient failed MACF in process pid 4, mount`
  - `IOUC AppleSEPUserClient failed MACF in process pid 6, seputil`
- This indicates deny can still occur through centralized IOUC MACF gate flow beyond per-policy sandbox hook stubs.

## Patch Metadata

- Primary patcher module:
  - `scripts/patchers/kernel_jb_patch_iouc_macf.py`
- JB scheduler status:
  - present in active `_PATCH_METHODS`
  - patch method emits one branch rewrite when the strict shape matches

## Validation (static, local)

- Historical repo dry-run emitted 2 writes on current kernel:
  - `0x012570C4` `mov x0,xzr [IOUC MACF gate low-risk]`
  - `0x012570C8` `retab [IOUC MACF gate low-risk]`
- Current A5-v2 dry-run emits **1 write** on current kernel:
  - `0x01257A98` `b #0x74 [IOUC MACF deny → allow]`

## XNU Reference Cross-Validation (2026-03-06)

What XNU confirms:

- The exact IOUC deny logs exist in open-source path:
  - `IOUC %s failed MACF in process %s`
  - `IOUC %s failed sandbox in process %s`
  - source: `iokit/Kernel/IOUserClient.cpp`
- MACF gate condition is wired as:
  - `mac_iokit_check_open(...) != 0` -> emit `failed MACF` log
  - source: `iokit/Kernel/IOUserClient.cpp`
- MACF bridge function exists and dispatches policy checks:
  - `mac_iokit_check_open` -> `MAC_CHECK(iokit_check_open, ...)`
  - source: `security/mac_iokit.c` and `security/mac_policy.h`

What still requires IDA/runtime evidence:

- The exact patched function start/address and branch location for this kernel build.
- Class-specific runtime instances (`AppleAPFSUserClient`, `AppleSEPUserClient`) that appear in boot logs.

Interpretation:

- The IOUC MACF mechanism itself is real and source-backed.
- The old repo hit-point was too wide.
- A5-v2 now follows the narrower branch-level retarget: preserve the IOUserClient open path and only force the post-`mac_iokit_check_open` gate into the allow path.

## Bottom Line

- The old entry early-return was a repo-local experiment and is no longer used.
- The current A5-v2 implementation patches only the narrow `mac_iokit_check_open` deny gate inside `0xfffffe000825b0c0`.
- Focused dry-run on `kernelcache.research.vphone600` hits a single branch rewrite at `0x01257A98`, which is much closer to an upstream-style minimal gate patch than the old entry short-circuit.
