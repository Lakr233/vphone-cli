# C22 `patch_syscallmask_apply_to_proc`

## Status

- Re-analysis date: `2026-03-06`
- Scope: `kernelcache.research.vphone600`
- Prior notes for this patch are treated as untrusted unless restated below.
- Current conclusion: the old repo C22 implementation was a misidentification that patched `_profile_syscallmask_destroy` under an underflow-panic slow path. As of `2026-03-06`, `scripts/patchers/kernel_jb_patch_syscallmask.py` has been rebuilt to target the real syscallmask apply wrapper structurally and recreate the upstream C22 behavior (mutate mask bytes to all-ones, then continue into the normal setter path). User-side restore/boot validation succeeded on `2026-03-06`.

## What This Mechanism Actually Does

This path is not a generic parser or allocator hook. Its real job is to **install per-process syscall filter masks** used later by three enforcement sites:

- Unix syscall dispatch
- Mach trap dispatch
- Kernel MIG / kobject dispatch

In XNU source terms, the closest semantic match is `proc_set_syscall_filter_mask(proc_t p, int which, unsigned char *maskptr, size_t masklen)` in `research/reference/xnu/bsd/kern/kern_proc.c:5142`.

Important XNU references:

- `research/reference/xnu/bsd/sys/proc.h:558` — `SYSCALL_MASK_UNIX`, `SYSCALL_MASK_MACH`, `SYSCALL_MASK_KOBJ`
- `research/reference/xnu/bsd/kern/kern_proc.c:5142` — setter for the three mask kinds
- `research/reference/xnu/bsd/dev/arm/systemcalls.c:161` — Unix syscall enforcement
- `research/reference/xnu/osfmk/arm64/bsd_arm64.c:253` — Mach trap enforcement
- `research/reference/xnu/osfmk/kern/ipc_kobject.c:568` — kobject/MIG enforcement
- `research/reference/xnu/bsd/kern/kern_fork.c:1028` — Unix mask inheritance on fork
- `research/reference/xnu/osfmk/kern/task.c:1759` — Mach/KOBJ filter inheritance

Semantics from XNU:

- If a filter mask pointer is `NULL`, the later dispatch path does **not** perform the extra mask-based deny/evaluate step.
- If a filter mask pointer is present and the bit is clear, the kernel falls back into MACF/Sandbox evaluation.
- If a filter mask pointer is present and the bit is set, the indexed Unix/Mach path does **not** fall into the extra policy callback.
- For KOBJ/MIG there is an important nuance: a non-`NULL` all-ones mask suppresses callback evaluation only when the message already has a registered `kobjidx`; `KOBJ_IDX_NOT_SET` still reaches policy evaluation.
- Therefore, `NULL`-mask install and all-ones install are related but **not identical** behaviors. Historical upstream C22 is the all-ones variant, not the `NULL` variant.

## Revalidated Live Call Chain (IDA)

### 1. Real apply layer in the sandbox kext

`_proc_apply_syscall_masks` at `0xfffffe00093b1a88`

Decompiled shape:

- Calls helper `sub_FFFFFE00093AE5E8(proc, 0, unix_mask)`
- Calls helper `sub_FFFFFE00093AE5E8(proc, 1, mach_mask)`
- Calls helper `sub_FFFFFE00093AE5E8(proc, 2, kobj_mask)`
- On failure, reports:
  - `"failed to apply unix syscall mask"`
  - `"failed to apply mach trap mask"`
  - `"failed to apply kernel MIG routine mask"`

This is the real high-level “apply to proc” logic for the current kernel, even though the stripped symbol is now named `_proc_apply_syscall_masks`, not `_syscallmask_apply_to_proc`.

### 2. Immediate callers of `_proc_apply_syscall_masks`

IDA xrefs show live callers:

- `_proc_apply_sandbox` at `0xfffffe00093b17d4`
- `_hook_cred_label_update_execve` at `0xfffffe00093d0dfc`

That means this path is exercised both when sandbox labels are applied and during exec-time label updates.

### 3. Helper that bridges into kernel proc/task RO state setters

`sub_FFFFFE00093AE5E8` at `0xfffffe00093ae5e8`

Observed behavior:

- Accepts `(proc, which, maskptr)`
- If `maskptr != NULL`, loads the expected mask length for `which`
- Tail-calls into kernel text at `0xfffffe0007fd0c74`

This helper is a narrow wrapper for the true setter logic.

### 4. Kernel-side setter core

The tail-call target is inside `sub_FFFFFE0007FD0B64`, entered at `0xfffffe0007fd0c74`.

Validated behavior from disassembly:

- `which == 0` (Unix): if `X2 == 0`, length validation is skipped and the proc RO syscall-mask pointer is updated with `NULL`
- `which == 1` (Mach): if `X2 == 0`, length validation is skipped and the task Mach filter pointer is updated with `NULL`
- `which == 2` (KOBJ/MIG): if `X2 == 0`, length validation is skipped and the task KOBJ filter pointer is updated with `NULL`
- Invalid `which` returns `EINVAL` (`0x16`)

This matches the XNU setter semantics closely enough to trust the mapping.

## PCC 26.1 Upstream-Exact Reconstruction

On the exact PCC 26.1 research kernel matching the historical upstream script, the original C22 chain resolves as follows:

- apply-wrapper entry: `0xfffffe00093994f8` (`sub_FFFFFE00093994F8`)
- high-level caller: `0xfffffe000939c998` (`sub_FFFFFE000939C998`)
- upstream patch writes at:
  - `0xfffffe0009399530` — original `BL` replaced by `mov x17, x0`
  - `0xfffffe0009399584` — original tail branch replaced by branch to cave
  - `0xfffffe0007ab5740` — code cave / data blob region

Validated wrapper behavior before patch:

- `sub_FFFFFE000939C998` calls `sub_FFFFFE00093994F8(proc, 0, unix_mask)`
- then `sub_FFFFFE00093994F8(proc, 1, mach_mask)`
- then `sub_FFFFFE00093994F8(proc, 2, kobj_mask)`
- failures map to the three familiar strings:
  - `failed to apply unix syscall mask`
  - `failed to apply mach trap mask`
  - `failed to apply kernel MIG routine mask`

This is the older PCC 26.1 form of the same logic that appears as `_proc_apply_syscall_masks` on the newer kernel.

At the low wrapper level, `sub_FFFFFE00093994F8` does this:

- if `maskptr == NULL`, skip the pre-processing helper
- otherwise call helper at `0xfffffe0007b761e0` with:
  - `x0` = zone/RO-mutation selector loaded from `word_FFFFFE0007A58354`
  - `x1` = backing object/pointer loaded from `qword_FFFFFE0007A58358`
  - `x2` = original mask pointer
- then load `x3 = masklen_bits` from a small selector table
- then tail-branch into setter core at `0xfffffe0007fc7220`

The historical upstream patch hijacks exactly this seam.

### Exact shellcode semantics

Using the original upstream words from the script, the cave body at `0xfffffe0007ab5768` disassembles to:

- preserve original args in `x19..x22`
- use the saved original helper arg in `x17`
- compute `ceil(masklen_bits / 8)` in `x4`
- call helper at `0xfffffe0007b76258`
- restore original `(proc, which, maskptr, masklen_bits)`
- branch back into setter core at `0xfffffe0007fc7220`

Crucially, the helper call is made with:

- `x0 = x17`
- `x1 = x21` (original `maskptr`)
- `x2 = 0` (offset)
- `x3 = cave base = 0xfffffe0007ab5740`
- `x4 = ceil(masklen_bits / 8)`

and the cave base holds a large `0xFF` blob.

That means the upstream patch mutates the pointed-to mask buffer in place so that the first `ceil(masklen_bits / 8)` bytes become `0xFF`, then installs that mask through the normal setter.

### Final semantic conclusion for upstream C22

The original upstream C22 patch is therefore:

- **not** “skip syscallmask apply”
- **not** “return success early”
- **not** “clear the mask pointer”

It is:

- **rewrite the mask contents to an all-ones allow mask, then continue through the normal setter path**

This is the closest faithful behavioral description of historical C22.

### Implication for modern reimplementation

If we want to reproduce upstream behavior exactly, the modern patch should preserve the apply/setter path and force the effective Unix/Mach/KOBJ masks to all ones.

If we prefer a smaller and likely safer patch for bring-up, the `NULL`-mask strategy remains attractive, but it is a modern simplification rather than an exact upstream reconstruction.

## Legacy Upstream Mapping

The pasted legacy script matches the historical upstream `syscallmask` shellcode patch that this repo later labeled as C22.

Concrete markers that identify it:

- shellcode cave at `0xAB1740`
- redirect from `0x2395584`
- setup write at `0x2395530` (`mov x17, x0`)
- tail branch to `_proc_set_syscall_filter_mask`
- in-cave call to `_zalloc_ro_mut`

Semantically, that upstream patch is **not** a destroy-path patch and **not** a plain early-return patch. It does this instead:

1. If the incoming mask pointer is `NULL`, skip the custom work.
2. Otherwise compute `ceil(mask_bits / 8)`.
3. Use `_zalloc_ro_mut` to overwrite the target read-only mask storage with bytes sourced from an in-cave `0xFF` blob.
4. Resume into `_proc_set_syscall_filter_mask`.

This means the historical upstream intent was:

- keep the mask object/path alive
- but force the installed syscall/mach/kobj mask to become an **all-ones allow mask**

That is an important semantic distinction from the newer `NULL`-mask strategy documented later in this file:

- **legacy upstream shellcode** => installed mask exists and all bits are allowed
- **proposed modern narrow patch** => installed mask pointer becomes `NULL`

Both strategies bypass this mask-based interception layer in practice, but they are not identical. If we want the closest behavioral match to the historical upstream patch, the modern equivalent should preserve the setter path and write an all-ones mask, not simply early-return.

## Fresh Independent Conclusions (`2026-03-06`)

- The legacy pasted script maps to the historical upstream `syscallmask` shellcode patch later labeled `C22` in this repo.
- The old repo “C22” was a false-positive hit in `_profile_syscallmask_destroy`; that patch class did not control mask installation and is not a trustworthy reference for behavior.
- The faithful upstream C22 class is: hijack the low wrapper, preserve the normal setter path, mutate the effective Unix/Mach/KOBJ mask bytes to all `0xFF`, then tail-branch back into the setter.
- Source-level equivalence is closest to calling `proc_set_syscall_filter_mask(..., all_ones_mask, expected_len)` for `which = 0/1/2`, not `proc_set_syscall_filter_mask(..., NULL, 0)`.
- XNU cross-check matters here: an all-ones mask and a `NULL` mask are behaviorally different for KOBJ/MIG when `kobjidx` is not registered, so the two strategies must stay documented as separate patch classes.

## New Plan

1. Keep the rebuilt all-ones wrapper retarget as the authoritative C22 baseline, because it is the closest match to the historical upstream PCC 26.1 shellcode.
2. Treat `NULL`-mask installation as a separate modern experiment only; do not describe it as “what upstream C22 did”.
3. Re-check the live runtime interaction of C22 with `_proc_apply_syscall_masks`, `_proc_apply_sandbox`, and `_hook_cred_label_update_execve` before blaming any future boot issue on C22 alone.
4. If runtime anomalies remain, classify them by enforcement site:
   - Unix syscall mask regression
   - Mach trap mask regression
   - KOBJ/MIG `KOBJ_IDX_NOT_SET` residual policy path
5. Only after the exact upstream-equivalent path is exhausted should we prototype a separate `NULL`-mask variant for comparison.

## What The Old C22 Implementation Actually Hit

Historical runtime verification logged these writes:

- `0xfffffe00093ae6e4`: `ff8300d1 -> e0031faa`
- `0xfffffe00093ae6e8`: `fd7b01a9 -> ff0f5fd6`

IDA mapping shows both addresses are inside `_profile_syscallmask_destroy` at `0xfffffe00093ae6a4`, not inside any apply-to-proc routine.

More specifically:

- `_profile_syscallmask_destroy` normal path ends at `0xfffffe00093ae6dc`
- `0xfffffe00093ae6e0` is the start of the **underflow panic slow path**
- The old patch replaced instructions in that slow path only

So the old “low-risk early return” did **not** disable syscall mask installation. It merely neutered a panic-reporting subpath after profile mask count underflow.

## Why The Old Matcher Misidentified The Target

The old patcher logic in `scripts/patchers/kernel_jb_patch_syscallmask.py` relies on:

- string anchor `"syscallmask.c"`
- nearby function-start recovery using `PACIBSP`
- legacy 4-argument prologue heuristics from an older shellcode-based implementation

On this kernel:

- the legacy `_syscallmask_apply_to_proc` shape is gone
- the nearby string cluster includes create/destroy/populate helpers
- the nearest `PACIBSP` around the string is at `0xfffffe00093ae6e0`, which is **not a real function entry** for the apply path

That is why the old low-risk fallback produced a false positive.

## Real Targets That Matter

### Safe semantic target

`_proc_apply_syscall_masks` at `0xfffffe00093b1a88`

This is the right place if the goal is:

- allow processes to keep running without syscall/mach/kobj mask-based interception
- preserve surrounding control flow and error handling
- avoid corrupting parser state or shared kernel setter logic

### Alternative narrower helper target

`sub_FFFFFE00093AE5E8` at `0xfffffe00093ae5e8`

This helper only appears to serve the apply layer here, but it is still a broader patch than changing the three call sites directly.

## Recommended Patch Strategy (Not Applied Here)

Per your instruction, no repository code changes are landed here. This section documents the patch strategy that appears correct from the live re-analysis.

### Preferred strategy: clear masks explicitly at the three call sites

Patch the three `LDR X2, [X8]` instructions in `_proc_apply_syscall_masks` to `MOV X2, XZR`.

Patchpoints:

1. Unix mask load
   - VA: `0xfffffe00093b1abc`
   - Before: `020140f9` (`ldr x2, [x8]`)
   - After: `e2031faa` (`mov x2, xzr`)

2. Mach trap mask load
   - VA: `0xfffffe00093b1af0`
   - Before: `020140f9` (`ldr x2, [x8]`)
   - After: `e2031faa` (`mov x2, xzr`)

3. KOBJ/MIG mask load
   - VA: `0xfffffe00093b1b28`
   - Before: `020140f9` (`ldr x2, [x8]`)
   - After: `e2031faa` (`mov x2, xzr`)

Why this is preferred:

- It preserves `_proc_apply_syscall_masks` control flow and error propagation.
- It still calls the existing setter path for all three mask types.
- The setter already supports `maskptr == NULL`, so this becomes a clean “clear installed filters” operation instead of a malformed early return.
- It avoids stale inherited masks remaining attached to the process.

### Secondary strategy: null out the helper argument once

Single-site alternative:

- VA: `0xfffffe00093ae600`
- Before: `f40301aa` (`mov x19, x2`)
- After: `f3031faa` (`mov x19, xzr`)

This also forces all three setter calls to receive `NULL`, but it is slightly wider than the three-site `_proc_apply_syscall_masks` patch and depends on there being no unintended callers of this helper entry.

## What Not To Patch

### Do not patch `_profile_syscallmask_destroy`

- Address: `0xfffffe00093ae6a4`
- Reason: lifecycle cleanup only; old C22 hit this by mistake

### Do not patch `_populate_syscall_mask`

- Address: `0xfffffe00093cf7f4`
- Reason: parser/allocation path for sandbox profile data; breaking it risks malformed state during sandbox construction and early boot

### Avoid patching the kernel-side setter core directly unless necessary

- Entry used here: `0xfffffe0007fd0c74`
- Reason: shared proc/task RO setters are broader-scope and easier to overpatch than the sandbox apply wrapper

## Expected Effect Of The Recommended Patch

If the three load sites are rewritten to `mov x2, xzr`:

- Unix syscall filter mask is cleared
- Mach trap filter mask is cleared
- Kernel MIG/kobject filter mask is cleared
- Later dispatchers no longer see an installed mask pointer for those channels
- The syscall/mach/kobj “bit clear -> consult MACF/Sandbox evaluator” layer is therefore skipped for these mask-based checks

This does **not** disable every sandbox/MACF path. It only removes this specific mask-installation layer.

## Why A Plain Early Return Is Inferior

A naive early return from `_proc_apply_syscall_masks` would likely return success, but it may leave previously inherited masks untouched.

That is especially risky because XNU inherits these masks across fork/task creation:

- Unix: `research/reference/xnu/bsd/kern/kern_fork.c:1028`
- Mach/KOBJ: `research/reference/xnu/osfmk/kern/task.c:1759`

So an early return can leave stale filter pointers in place, while the explicit `NULL`-setter strategy actively clears them.

## Boot-Risk Assessment

Most plausible failure modes if this family is patched incorrectly:

- stale or invalid mask pointers remain attached to early boot tasks
- Mach/KOBJ traffic gets filtered unexpectedly during bootstrap
- parser/create/destroy bookkeeping becomes inconsistent
- a broad setter patch corrupts proc/task RO state outside the intended sandbox apply path

The proposed three-site `mov x2, xzr` strategy is the narrowest approach found so far that still achieves the intended jailbreak effect.

## Repository Implementation Status

As of `2026-03-06`, the repository implementation has been updated to follow the revalidated C22 design:

- locate the high-level apply manager from the three `failed to apply ... mask` strings
- identify the shared low wrapper that is called with `which = 0/1/2`
- replace the wrapper's pre-setter helper `BL` with `mov x17, x0`
- replace the wrapper's tail `B` with a branch to a code cave
- in the cave, build an all-ones blob, call the structurally-derived mutation helper, then tail-branch back into the normal setter core

Focused dry-run validation on `ipsws/PCC-CloudOS-26.1-23B85/kernelcache.research.vphone600` now emits exactly 3 writes:

- `0x02395530` — `mov x17,x0 [syscallmask C22 save RO selector]`
- `0x023955E8` — `b cave [syscallmask C22 mutate mask then setter]`
- `0x00AB1720` — `syscallmask C22 cave (ff blob 0x100 + structural mutator + setter tail)`

This restores the intended patch class while avoiding the previous false-positive hit on `_profile_syscallmask_destroy`.

User validation note: boot succeeded with the rebuilt C22 enabled on `2026-03-06`.

## Bottom Line

- The historical C22 implementation is mis-targeted.
- The real current “apply to proc” logic is `_proc_apply_syscall_masks`, not `_profile_syscallmask_destroy`.
- The historical upstream patch class is **not** `NULL`-mask install; it is **all-ones mask mutation plus normal setter continuation**.
- The rebuilt wrapper/cave retarget matches that upstream class and has already reached user-reported boot success on `2026-03-06`.
- `NULL`-mask install remains a separate modern alternative worth studying later, especially because KOBJ/MIG semantics differ when `kobjidx` is unset.
