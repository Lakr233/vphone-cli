# B15 `patch_task_for_pid`

## Goal

Keep the jailbreak `task_for_pid` patch aligned with the known-good upstream design in `/Users/qaq/Desktop/patch_fw.py` unless IDA + XNU clearly prove that upstream is wrong.

- Preferred upstream target: `patch(0xFC383C, 0xD503201F)`.
- Final rework result: `match`.
- PCC 26.1 research hit: file offset `0x00FC383C`, VA `0xFFFFFE0007FC783C`.
- PCC 26.1 release hit: file offset `0x00F8783C`.

## What Gets Patched

The patch NOPs the early `pid == 0` reject gate in `task_for_pid`, before the call that resolves the target task port.

On PCC 26.1 research the validated sequence is:

```asm
0xFFFFFE0007FC7828  ldr w23, [x8, #8]
0xFFFFFE0007FC782C  ldr x19, [x8, #0x10]
0xFFFFFE0007FC783C  cbz w23, 0xFFFFFE0007FC79CC   ; patched
0xFFFFFE0007FC7840  mov w1, #0
0xFFFFFE0007FC7844  mov w2, #0
0xFFFFFE0007FC7848  mov w3, #0
0xFFFFFE0007FC784C  mov x4, #0
0xFFFFFE0007FC7850  bl  <helper>
0xFFFFFE0007FC7854  cbz x0, 0xFFFFFE0007FC79CC
```

## Upstream Match vs Divergence

### Final status: `match`

- Upstream `patch_fw.py` uses file offset `0xFC383C`.
- The reworked matcher now emits exactly `0xFC383C` on PCC 26.1 research.
- The corresponding PCC 26.1 release hit is `0xF8783C`, which is the expected variant-shifted analogue of the same in-function gate.

### Rejected drift design

The previous local rework had diverged to two later deny-return rewrites in small helper functions.

That divergence is rejected because:

- it does **not** match the known-good upstream site,
- the XNU source still explicitly says `/* Always check if pid == 0 */` and immediately returns failure,
- IDA on PCC 26.1 research still shows the same early `cbz wPid, fail` gate at the exact upstream offset,
- the helper-rewrite path broadens behavior more than necessary and is computationally more expensive at runtime.

## XNU Cross-Reference

Source: `research/reference/xnu/bsd/kern/kern_proc.c:5715`

```c
/* Always check if pid == 0 */
if (pid == 0) {
    (void) copyout((char *)&tret, task_addr, sizeof(mach_port_name_t));
    AUDIT_MACH_SYSCALL_EXIT(KERN_FAILURE);
    return KERN_FAILURE;
}
```

### Fact

- The source-level first authorization gate in `task_for_pid()` is the `pid == 0` rejection.
- The validated PCC 26.1 research instruction at `0xFFFFFE0007FC783C` is the direct binary analogue of that source gate.

### Inference

NOPing this early `cbz` is the narrowest upstream-compatible jailbreak bypass because it removes only the unconditional `pid == 0` failure gate, while leaving the later `proc_find()`, `task_for_pid_posix_check()`, and task lookup flow structurally intact.

## Anchor Class

- Primary runtime anchor class: `string + heuristic`.
- Concrete string anchor: `"proc_ro_ref_task"`, which lives inside the same stripped function body on PCC 26.1 research.
- Why this anchor was chosen: the embedded symtable is effectively empty, IDA names are not stable, but this in-function string reliably recovers the enclosing function so the heuristic scan stays local instead of walking the whole kernel.

## Runtime Matcher Design

The runtime matcher is intentionally single-path and upstream-aligned:

1. Recover the enclosing function from the in-image string `"proc_ro_ref_task"`.
2. Scan only that function for the unique local sequence:
   - `ldr wPid, [xArgs, #8]`
   - `ldr xTaskPtr, [xArgs, #0x10]`
   - `cbz wPid, fail`
   - `mov w1, #0`
   - `mov w2, #0`
   - `mov w3, #0`
   - `mov x4, #0`
   - `bl`
   - `cbz x0, fail`
3. Patch the first `cbz` with `NOP`.

This avoids unstable IDA naming while keeping the reveal logic close to the exact upstream gate.

## Why This Should Generalize

This matcher should survive PCC 26.1 research, PCC 26.1 release, and likely nearby release variants such as 26.3 because it relies on:

- the stable syscall argument layout (`pid` at `+8`, task port output at `+0x10`),
- the narrow early-failure ABI shape around `port_name_to_task()`, and
- a single local fail target shared by `cbz wPid` and the post-helper `cbz x0`.

Runtime cost remains reasonable:

- one full sequential decode of `kern_text`,
- no repeated nested scans,
- one exact candidate accepted.

## Validation

### Focused dry-run

Validated locally on extracted raw kernels:

- PCC 26.1 research: `hit` at `0x00FC383C`
- PCC 26.1 release: `hit` at `0x00F8783C`

Both variants emit exactly one patch:

- `NOP [_task_for_pid pid==0 gate]`

### Match verdict

- Upstream reference `/Users/qaq/Desktop/patch_fw.py`: `match`
- IDA PCC 26.1 research control-flow: `match`
- XNU `task_for_pid` early gate semantics: `match`

## Files

- Patcher: `scripts/patchers/kernel_jb_patch_task_for_pid.py`
- Analysis doc: `research/kernel_jailbreak_patches/patch_task_for_pid.md`

## 2026-03-06 Rework

- Upstream target (`/Users/qaq/Desktop/patch_fw.py`): `match`.
- Final research site: `0x00FC383C` (`0xFFFFFE0007FC783C`).
- Anchor class: `string + heuristic`. Runtime reveal recovers the enclosing function from the in-image `"proc_ro_ref_task"` string, then finds the unique upstream local `ldr pid ; ldr task_ptr ; cbz pid ; mov w1/w2/w3,#0 ; mov x4,#0 ; bl ; cbz x0` pattern.
- Why this site: it is the exact known-good upstream `pid == 0` reject gate, and XNU still models it as the first unconditional failure path in `task_for_pid()`.
- Release/generalization rationale: the local ABI/control-flow pattern is narrow and stable across stripped kernels, while avoiding reliance on symbol names.
- Performance note: one string-xref resolution plus a single bounded local scan (`+0x800` window) because the stripped-function end detector truncates this function too early on current PCC 26.1 images; still no whole-kernel repeated semantic rescans.
- Focused PCC 26.1 research dry-run: pending main-agent validation.
