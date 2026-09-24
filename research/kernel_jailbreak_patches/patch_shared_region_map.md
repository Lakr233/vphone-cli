# B17 `patch_shared_region_map`

## Goal

Keep the jailbreak `shared_region_map` patch aligned with the known-good upstream design in `/Users/qaq/Desktop/patch_fw.py` unless IDA + XNU clearly prove upstream is wrong.

- Preferred upstream target: `patch(0x10729cc, 0xeb00001f)`.
- Final rework result: `match`.
- PCC 26.1 research hit: file offset `0x010729CC`, VA `0xFFFFFE00080769CC`.
- PCC 26.1 release hit: file offset `0x010369CC`.

## What Gets Patched

The patch rewrites the first mount-comparison gate in `shared_region_map_and_slide_setup()` so the shared-cache vnode is treated as if it were already on the process root mount:

```asm
cmp mount_reg, root_mount_reg   ; patched to cmp x0, x0
b.eq skip_preboot_lookup
str xzr, [state,...]
adrp/add ... "/private/preboot/Cryptexes"
```

On PCC 26.1 research the validated sequence is:

```asm
0xFFFFFE00080769CC  cmp x8, x16          ; patched
0xFFFFFE00080769D0  b.eq 0xFFFFFE0008076A98
0xFFFFFE00080769D4  str xzr, [x23,#0x1d0]
0xFFFFFE00080769DC  adrl x0, "/private/preboot/Cryptexes"
0xFFFFFE00080769F0  bl  <vnode_lookup-like helper>
0xFFFFFE00080769F4  cbnz w0, 0xFFFFFE0008076D84
```

## Upstream Match vs Divergence

### Final status: `match`

- Upstream `patch_fw.py` uses file offset `0x10729CC`.
- The reworked matcher now emits exactly `0x10729CC` on PCC 26.1 research.
- The corresponding PCC 26.1 release hit is `0x10369CC`, the expected variant-shifted analogue of the same first-compare gate.

### Rejected drift site

The older local analysis focused on a later fallback compare after the preboot lookup succeeded.

That older focus is rejected because:

- it did **not** match the known-good upstream site,
- XNU source first checks `srfmp->vp->v_mount != rdir_vp->v_mount` before any preboot lookup,
- IDA on PCC 26.1 research still shows that first root-vs-process-root compare exactly at the upstream offset,
- matching the first compare is both narrower and more faithful to the upstream patch semantics.

## XNU Cross-Reference

Source: `research/reference/xnu/bsd/vm/vm_unix.c:1472`

```c
assert(rdir_vp != NULL);
if (srfmp->vp->v_mount != rdir_vp->v_mount) {
    vnode_t preboot_vp = NULL;
    error = vnode_lookup(PREBOOT_CRYPTEX_PATH, 0, &preboot_vp, vfs_context_current());
    if (error || srfmp->vp->v_mount != preboot_vp->v_mount) {
        error = EPERM;
        ...
        goto done;
    }
}
```

### Fact

- The first policy gate is the direct root-mount comparison.
- Only if that comparison fails does the code fall into the `PREBOOT_CRYPTEX_PATH` lookup and later preboot-mount comparison.
- The validated PCC 26.1 research instruction at `0xFFFFFE00080769CC` is the binary analogue of the first `srfmp->vp->v_mount != rdir_vp->v_mount` check.

### Inference

Patching the first compare to `cmp x0, x0` is the narrowest upstream-compatible bypass because it skips the entire fallback preboot lookup path while leaving the rest of the shared-region setup logic intact.

## Anchor Class

- Primary runtime anchor class: `string + local CFG`.
- Concrete string anchor: `"/private/preboot/Cryptexes"`.
- Why this anchor was chosen: the embedded symtable is effectively empty on stripped kernels, but this path string lives inside the exact helper that contains the mount-origin policy.
- Why the local CFG matters: the runtime matcher selects the compare immediately preceding the Cryptexes lookup block by requiring `cmp reg,reg ; b.eq forward ; str xzr, [...]` right before the string reference.

## Runtime Matcher Design

The runtime matcher is intentionally single-path and upstream-aligned:

1. Recover the helper from the in-image string `"/private/preboot/Cryptexes"`.
2. Find the string reference(s) inside that function.
3. For the local window immediately preceding the string reference, match:
   - `cmp x?, x?`
   - `b.eq forward`
   - `str xzr, [...]`
4. Patch that `cmp` to `cmp x0, x0`.

This reproduces the exact upstream site without relying on IDA names or runtime symbol tables.

## Why This Should Generalize

This matcher should survive PCC 26.1 research, PCC 26.1 release, and likely nearby stripped releases such as 26.3 because it relies on:

- a stable embedded preboot-Cryptexes path string,
- the source-backed control-flow shape directly before that lookup,
- a local window rather than a whole-kernel heuristic scan.

Runtime cost remains modest:

- one string lookup,
- one xref-to-function recovery,
- one very small local scan around the string reference.

## Validation

### Focused dry-run

Validated locally on extracted raw kernels:

- PCC 26.1 research: `hit` at `0x010729CC`
- PCC 26.1 release: `hit` at `0x010369CC`

Both variants emit exactly one patch:

- `cmp x0,x0 [_shared_region_map_and_slide_setup]`

### Match verdict

- Upstream reference `/Users/qaq/Desktop/patch_fw.py`: `match`
- IDA PCC 26.1 research control-flow: `match`
- XNU shared-region mount-origin semantics: `match`

## Files

- Patcher: `scripts/patchers/kernel_jb_patch_shared_region.py`
- Analysis doc: `research/kernel_jailbreak_patches/patch_shared_region_map.md`

## 2026-03-06 Rework

- Upstream target (`/Users/qaq/Desktop/patch_fw.py`): `match`.
- Final research site: `0x010729CC` (`0xFFFFFE00080769CC`).
- Anchor class: `string + local CFG`. Runtime reveal starts from the in-image `"/private/preboot/Cryptexes"` string and patches the first local `cmp ... ; b.eq` mount gate immediately before the lookup block.
- Why this site: it is the exact known-good upstream root-vs-process-root compare. The older focus on the later preboot-fallback compare is treated as stale divergence and is no longer accepted.
- Release/generalization rationale: the path string and the immediate compare/branch/zero-store scaffold are source-backed and should survive stripped release kernels.
- Performance note: one string-xref resolution plus a tiny local scan near the string reference.
- Focused PCC 26.1 research dry-run: `hit`, 1 write at `0x010729CC`.
