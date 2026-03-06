# C24 `patch_kcall10`

## Status (2026-03-06, PCC 26.1 re-analysis)

- Treat all older `kcall10` notes in this repo as historical / untrusted unless they match the facts below.
- Current verdict for the legacy upstream-style design: it was ABI-incorrect for PCC 26.1 and has been replaced in the patcher with a rebuilt ABI-correct syscall-cave design.
- Scope of this document: single-patch re-research only, focused exclusively on the `kcall10` kernel-call patch itself.

## Goal

- Repurpose `SYS_kas_info` (`syscall 439`) into a usable kernel-call primitive for jailbreak workflows.
- Keep the hook on a syscall slot that is already effectively unused on this kernel.
- Make the patch structurally correct for the real arm64 XNU syscall ABI so it can be dry-run validated without relying on guessed stack contracts.

## Verified PCC 26.1 Facts

### `sysent[439]` on the loaded PCC 26.1 research kernel

- IDA function `sub_FFFFFE00081279E4` is the arm64 Unix syscall dispatcher (`unix_syscall` semantics confirmed by XNU source and call shape).
- It computes the syscall-table base as `off_FFFFFE000773F858` and indexes entries as `base + code * 0x18`.
- Therefore `sysent[439]` is at:
  - VA `0xFFFFFE0007742180`
  - file offset `0x0073E180`
- Unpatched entry contents on PCC 26.1:
  - `sy_call = 0xFFFFFE0008077978`
  - `sy_arg_munge32 = 0xFFFFFE0007C6AC4C`
  - `sy_return_type = 1`
  - `sy_narg = 3`
  - `sy_arg_bytes = 0x000C`

### Raw entry dump

- 24-byte `sysent[439]` dump as observed in IDA / local decode:
  - qword `[+0x00]`: `0xFFFFFE0008077978`
  - qword `[+0x08]`: `0xFFFFFE0007C6AC4C`
  - dword `[+0x10]`: `0x00000001`
  - half `[+0x14]`: `0x0003`
  - half `[+0x16]`: `0x000C`
- Same entry in 32-bit little-endian words:
  - `08077978 fffffe00 07c6ac4c fffffe00 00000001 000c0003`

### What `syscall 439` currently does here

- `0xFFFFFE0008077978` disassembles to:
  - `MOV W0, #0x2D`
  - `RET`
- `0x2D` is `45` decimal, i.e. `ENOTSUP`.
- So on this PCC 26.1 research kernel, `SYS_kas_info` is effectively a stubbed-out `ENOTSUP` syscall target, which makes it a good hook point.

### Verified dispatcher ABI

- In `sub_FFFFFE00081279E4`, the handler call sequence is:
  - `LDR X8, [X22]`
  - `MOV X0, X21`
  - `MOV X1, X19`
  - `MOV X2, X24`
  - `MOV X17, #0xBCAD`
  - `BLRAA X8, X17`
- Derived state at the call:
  - `X21 = struct proc *`
  - `X19 = &uthread->uu_arg[0]`
  - `X24 = &uthread->uu_rval[0]`
- So the real handler ABI is:
  - `x0 = struct proc *`
  - `x1 = &uthread->uu_arg[0]`
  - `x2 = &uthread->uu_rval[0]`

## XNU Cross-Check

- `research/reference/xnu/bsd/sys/sysent.h` defines `sy_call_t` as `int32_t sy_call(struct proc *, void *, int *)`.
- `research/reference/xnu/bsd/dev/arm/systemcalls.c` shows `unix_syscall()` calling `(*callp->sy_call)(proc, &uthread->uu_arg[0], &uthread->uu_rval[0])`.
- arm64 `unix_syscall` only accepts up to **8** syscall argument slots.
- `research/reference/xnu/bsd/sys/user.h` shows `uu_rval` is `int uu_rval[2]`, so the natural 64-bit return path is `_SYSCALL_RET_UINT64_T`, which packs one 64-bit value across those two 32-bit cells.

## Why The Historical Design Was Wrong

### Old idea

- Historical notes described a cave that:
  - recovered a pointer from `[sp,#0x40]`
  - treated that pointer as `{ target, arg0..arg9, out_regs... }`
  - called the target with `BLR`
  - wrote many registers back to the same buffer
  - returned `0`

### Problems

- The syscall ABI never passes a userspace request buffer via `[sp,#0x40]`.
- arm64 XNU does not provide a 10-argument Unix syscall ABI.
- `uu_arg` only holds 8 qwords, so the old cave over-read / over-wrote beyond the copied syscall arguments.
- The old design bypassed the real syscall return channel (`retval` / `uu_rval`) and therefore did not actually match how `unix_syscall()` returns results to userspace.

## Rebuilt Patch Design

### Practical decision

- A literal direct-call `kcall10` is not ABI-compatible with this kernel's Unix syscall path.
- The rebuilt patch therefore keeps the historical hook point but redefines the request format into an ABI-correct reduced form:
  - target function pointer
  - 7 direct arguments
  - 64-bit X0 return value
- This keeps the patch usable as a kernel-call bootstrap while staying within the real syscall ABI.

### New `uap` layout

The rebuilt patcher uses `sy_narg = 8`, with `x1` pointing at a copied 8-qword argument block:

```c
struct kcall10_uap_rebuilt {
    uint64_t target;
    uint64_t arg0;
    uint64_t arg1;
    uint64_t arg2;
    uint64_t arg3;
    uint64_t arg4;
    uint64_t arg5;
    uint64_t arg6;
};
```

### New semantics

- `uap[0]` = target function pointer
- `uap[1..7]` = arguments loaded into `x0..x6`
- `x7` is forced to zero in the cave
- target return `x0` is stored to `retval`
- `sysent[439].sy_return_type` is set to `_SYSCALL_RET_UINT64_T`
- userspace receives one 64-bit return value in `x0`

## Python Implementation

The dedicated patcher file is now:

- `scripts/patchers/kernel_jb_patch_kcall10.py`

### What it now does

- Finds the real `sysent` table by scanning backward from a decoded `_nosys` entry.
- Locates a reusable 8-argument `sy_arg_munge32` helper from the live table and now requires that the decoded helper target be unique across all matching sysent rows.
- Allocates an executable cave sized to the emitted blob instead of relying on a fixed large reservation.
- Emits an ABI-correct cave that:
  - validates `uap`, `retval`, and `target`
  - loads `target + 7 args` from `x1`
  - performs `BLR X16`
  - stores `X0` to `x2`
  - returns `0` on success or `EINVAL` on malformed input
- Rewrites `sysent[439]` to point at the cave.
- Rewrites `sysent[439].sy_arg_munge32` to an 8-argument helper.
- Rewrites metadata to:
  - `sy_return_type = 7`
  - `sy_narg = 8`
  - `sy_arg_bytes = 0x20`

## Expected Emitted Patch Shape

The rebuilt patch should emit exactly four writes:

1. Code cave blob in `__TEXT_EXEC`
2. `sysent[439].sy_call = cave`
3. `sysent[439].sy_arg_munge32 = 8-arg munger`
4. `sysent[439].sy_return_type / sy_narg / sy_arg_bytes`

## Static Acceptance Criteria

The rebuilt patch is considered structurally correct if all of the following hold:

- `sysent[439]` still decodes as a valid auth-rebase entry after patching.
- `sy_narg == 8` and `sy_arg_bytes == 0x20`.
- No cave instruction reads from guessed caller-frame offsets like `[sp,#0x40]` to recover user arguments.
- The cave consumes the real syscall handler ABI: `(proc, uap, retval)`.
- The cave returns the 64-bit primary result through `retval` and `_SYSCALL_RET_UINT64_T`.
- The cave does not read beyond the 8 copied syscall qwords.

## Risks

- **Arbitrary kernel call surface**: this patch intentionally creates a direct kernel-call primitive from userspace; any reachable caller with sufficient privilege can invoke sensitive kernel routines with attacker-controlled arguments.
- **Target-function safety**: the cave does not validate the semantic suitability of the target function. Calling a function with the wrong prototype, wrong locking expectations, or wrong context can panic or corrupt kernel state.
- **Argument-width limit**: this rebuilt version is ABI-correct but only supports `target + 7 args -> uint64 x0`. Workflows that silently assume the old pseudo-10-arg contract will misbehave until userspace is updated.
- **Return-value limit**: only primary `x0` is surfaced through the syscall return path. Any target that needs structured outputs, out-pointers, or multiple architecturally relevant return registers still needs a higher-level descriptor / copyout design.
- **PAC / branch-context coupling**: the `sy_call` hook itself preserves the expected authenticated-call shape, but the target function call inside the cave is a plain `blr x16`. If the chosen target relies on a different authenticated entry expectation or unusual calling context, behavior may still be unsafe.
- **Scheduler impact**: re-enabling this patch in the default JB list means future aggregate dry-runs and restore tests now include it. Any regression observed after this point must consider `patch_kcall10` as part of the active set.

## Current Limits

- This rebuilt patch is ABI-correct, but it is no longer a literal “10 direct argument” trampoline.
- It provides a reduced-form direct-call primitive: `target + 7 args -> uint64 x0`.
- If a future design needs more arguments or structured output, it should move to a descriptor + `copyin/copyout` model rather than trying to extend the raw syscall ABI.

## Validation Plan

1. Keep work scoped to this single patch.
2. Run a dedicated dry-run against `ipsws/PCC-CloudOS-26.1-23B85/kernelcache.research.vphone600`.
3. Verify the emitted cave disassembly matches the rebuilt design.
4. Verify the three `sysent[439]` field writes match the intended targets and metadata.
5. Stop at dry-run validation; do not escalate to full firmware build in this step.

## Dry-Run Validation (2026-03-06)

Target image:

- `ipsws/PCC-CloudOS-26.1-23B85/kernelcache.research.vphone600`

Result:

- `method_return = True`
- `patch_count = 4`

Emitted writes:

- `0x00AB1720` — cave blob, size `0x6C`
- `0x0073E180` — `sysent[439].sy_call = cave`
- `0x0073E188` — `sysent[439].sy_arg_munge32 = 8-arg helper`
- `0x0073E190` — `sy_return_type = 7`, `sy_narg = 8`, `sy_arg_bytes = 0x20`

Exact emitted bytes:

- cave @ `0x00AB1720`:
  - `7f2303d5ffc300d1f55b00a9f35301a9fd7b02a9fd830091d3028052f40301aaf50302aa940100b4750100b4900240f9300100b4808640a9828e41a9849642a9861e40f9e7031faa00023fd6a00200f913008052e003132af55b40a9f35341a9fd7b42a9ffc30091ff0f5fd6`
- `sysent[439].sy_call` @ `0x0073E180`:
  - `2017ab00adbc1080`
- `sysent[439].sy_arg_munge32` @ `0x0073E188`:
  - `286dc600be2a2080`
- metadata @ `0x0073E190`:
  - `0700000008002000`

Decoded post-patch fields:

- `sy_call` decodes to cave file offset `0x00AB1720`
- `sy_arg_munge32` decodes to helper file offset `0x00C66D28` (chosen only after confirming the 8-arg helper target is unique across matching sysent rows)
- `sy_return_type = 7`
- `sy_narg = 8`
- `sy_arg_bytes = 0x20`

Cave disassembly summary:

- prologue: `pacibsp`, 0x30-byte stack frame, saves `x19`-`x22`, `x29`, `x30`
- validation: reject null `uap`, null `retval`, null `target` with `EINVAL`
- load path: reads target from `[x20]`, args from `[x20+0x8 .. +0x38]`
- call path: `blr x16` with `x0..x6` populated and `x7 = 0`
- return path: `str x0, [x21]`, move status into `w0`, restore callee-saved registers, `retab`
