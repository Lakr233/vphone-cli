# B12 `patch_dounmount`

## Goal

Keep the jailbreak `dounmount` patch aligned with the known-good upstream design in `/Users/qaq/Desktop/patch_fw.py`.

- Preferred upstream target: `patch(0xCA8134, 0xD503201F)`.
- Current rework result: `match`.
- PCC 26.1 research hit: file offset `0x00CA8134`, VA `0xFFFFFE0007CAC134`.
- PCC 26.1 release hit: file offset `0x00C6C134`.

## What Gets Patched

The patch NOPs the first BL in the `coveredvp` success-tail cleanup sequence inside `dounmount`:

```asm
mov x0, coveredvp_reg
mov w1, #0
mov w2, #0
mov w3, #0
bl  <target>        ; patched to NOP
mov x0, coveredvp_reg
bl  <target>
```

On PCC 26.1 research the validated sequence is:

```asm
0xFFFFFE0007CAC124  mov x0, x26
0xFFFFFE0007CAC128  mov w1, #0
0xFFFFFE0007CAC12C  mov w2, #0
0xFFFFFE0007CAC130  mov w3, #0
0xFFFFFE0007CAC134  bl  #0xC92AD8   ; patched
0xFFFFFE0007CAC138  mov x0, x26
0xFFFFFE0007CAC13C  bl  #0xC947E8
```

## Upstream Match vs Divergence

### Final status: `match`

- Upstream `patch_fw.py` uses file offset `0xCA8134`.
- The reworked matcher now emits exactly `0xCA8134` on PCC 26.1 research.
- The corresponding PCC 26.1 release hit is `0xC6C134`, which is the expected variant-shifted analogue of the same in-function sequence.

### Rejected drift site

The previous repo matcher had drifted to `0xCA81FC` on research.

That drift was treated as a red flag because:

- it did **not** match upstream,
- it matched a later teardown sequence with shape `mov x0, #0 ; mov w1, #0x10 ; mov x2, #0 ; bl ...`,
- that later sequence does **not** correspond to the upstream `coveredvp` cleanup gate in either IDA or XNU source structure.

Conclusion: the drifted site was incorrect and has been removed.

## Why This Site Is Correct

### Facts from XNU

From `research/reference/xnu/bsd/vfs/vfs_syscalls.c`, the successful `coveredvp != NULLVP` tail of `dounmount()` is:

```c
if (!error) {
    if ((coveredvp != NULLVP)) {
        vnode_getalways(coveredvp);

        mount_dropcrossref(mp, coveredvp, 0);
        if (!vnode_isrecycled(coveredvp)) {
            pvp = vnode_getparent(coveredvp);
            ...
        }

        vnode_rele(coveredvp);
        vnode_put(coveredvp);
        coveredvp = NULLVP;

        if (pvp) {
            lock_vnode_and_post(pvp, NOTE_WRITE);
            vnode_put(pvp);
        }
    }
    ...
}
```

### Facts from IDA / disassembly

Inside the `dounmount` function recovered from the in-function panic anchor `"dounmount: no coveredvp"`, the validated research sequence is:

- optional call on the same `coveredvp` register just before the patch site,
- `mov x0, coveredvp_reg ; mov w1,#0 ; mov w2,#0 ; mov w3,#0 ; bl`,
- immediate follow-up `mov x0, coveredvp_reg ; bl`,
- optional parent-vnode post path immediately after.

This is the exact control-flow shape expected for the source-level `vnode_rele(coveredvp); vnode_put(coveredvp);` pair.

### Inference

The first BL is the upstream gate worth neutralizing because it is the only BL in that local cleanup pair that takes the covered vnode plus three zeroed scalar arguments, immediately followed by a second BL on the same vnode register. That shape matches the source-level release/put tail and matches the known-good upstream patch location.

## Anchor Class

- Primary runtime anchor class: `string anchor`.
- Concrete anchor: `"dounmount: no coveredvp"`.
- Why this anchor was chosen: the embedded symbol table is effectively empty on the local stripped payloads, IDA names are not stable, and this panic string lives inside the target function on both current research and release images.
- Release-kernel survivability: the patcher does not require recovered names or repo-exported symbol JSON at runtime; it only needs the in-image string reference plus the surrounding decoded control-flow shape.

## Runtime Matcher Design

The runtime matcher is intentionally single-path and source-backed:

1. Find the panic string `"dounmount: no coveredvp"`.
2. Recover the containing function (`dounmount`) from its string xref.
3. Scan only that function for the unique 8-instruction sequence:
   - `mov x0, <reg>`
   - `mov w1, #0`
   - `mov w2, #0`
   - `mov w3, #0`
   - `bl`
   - `mov x0, <same reg>`
   - `bl`
   - `cbz x?, ...`
4. Patch the first `bl` with `NOP`.

The matcher now also fixes the ABI argument registers exactly (`x0`, `w1`, `w2`, `w3`) instead of accepting arbitrary zeroing moves, which makes the reveal path closer to the upstream call shape without depending on unstable symbol names.

## Why This Should Generalize

This matcher should survive PCC 26.1 research, PCC 26.1 release, and likely later close variants such as 26.3 release because it anchors on:

- an in-function panic string that is tightly coupled to `dounmount`, and
- a local cleanup sequence derived from stable VFS semantics (`coveredvp` release then put),
- using decoded register/immediate/control-flow structure rather than fixed offsets.

The pattern is also cheap:

- one string lookup,
- one xref-to-function recovery,
- one linear scan over a single function body,
- one 7-instruction decode window per candidate.

So it remains robust without becoming an expensive whole-image search.

## Validation

### Focused dry-run

Validated locally on extracted raw kernels:

- PCC 26.1 research: `hit` at `0x00CA8134`
- PCC 26.1 release: `hit` at `0x00C6C134`

Both variants emit exactly one patch:

- `NOP [_dounmount upstream cleanup call]`

### Match verdict

- Upstream reference `/Users/qaq/Desktop/patch_fw.py`: `match`
- IDA PCC 26.1 research control-flow: `match`
- XNU `dounmount` success-tail semantics: `match`

## Files

- Patcher: `scripts/patchers/kernel_jb_patch_dounmount.py`
- Analysis doc: `research/kernel_jailbreak_patches/patch_dounmount.md`

## 2026-03-06 Rework

- Upstream target (`/Users/qaq/Desktop/patch_fw.py`): `match`.
- Final research site: `0x00CA8134` (`0xFFFFFE0007CAC134`).
- Anchor class: `string`. Runtime reveal starts from the in-image `"dounmount:"` panic string, resolves the enclosing function, then finds the unique near-tail `mov x0,<coveredvp> ; mov w1,#0 ; mov w2,#0 ; mov w3,#0 ; bl ; mov x0,<coveredvp> ; bl ; cbz x?` cleanup-call block.
- Why this site: it is the exact known-good upstream 4-arg zeroed callsite. The previously drifted `0x00CA81FC` call uses a different signature (`w1 = 0x10`) and a different control-flow region, so it is treated as a red-flag divergence and removed.
- Release/generalization rationale: the panic string is stable in stripped kernels, and the local 8-instruction shape is tight enough to stay cheap and robust across PCC 26.1 release / likely 26.3 release.
- Performance note: one string-xref resolution plus a single function-local linear scan.
- Focused PCC 26.1 research dry-run: `hit`, 1 write at `0x00CA8134`.
