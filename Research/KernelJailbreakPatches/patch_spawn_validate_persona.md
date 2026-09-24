# B14 `patch_spawn_validate_persona`

## Verdict

- Preferred upstream reference: `/Users/qaq/Desktop/patch_fw.py`.
- Final status on PCC 26.1 research: **match upstream**.
- Upstream patch sites:
  - `0x00FA7024` -> `nop`
  - `0x00FA702C` -> `nop`
- Final release-variant analogue:
  - `0x00F6B024` -> `nop`
  - `0x00F6B02C` -> `nop`
- Previous repo drift to `0x00FA694C` / branch rewrite is now rejected for this patch because it did **not** match upstream and targeted an outer gate rather than the smaller helper that actually contains the sibling nil-field rejects.

## Anchor Class

- Primary runtime anchor class: `string anchor`.
- Concrete anchor: `"com.apple.private.spawn-panic-crash-behavior"` in the outer spawn policy wrapper.
- Secondary discovery: semantic enumeration of that wrapper's local BL callees to find the unique small helper that matches the upstream control-flow shape.
- Why this survives stripped kernels: the matcher does not need IDA names or embedded symbols; it only needs the in-image entitlement string plus decoded local CFG in the nearby helper.

## Final Patch Sites

### PCC 26.1 research

- `0xFFFFFE0007FAB024` / `0x00FA7024`: `cbz w8, ...` -> `nop`
- `0xFFFFFE0007FAB02C` / `0x00FA702C`: `cbz w8, ...` -> `nop`

### PCC 26.1 release

- `0x00F6B024`: `cbz w8, ...` -> `nop`
- `0x00F6B02C`: `cbz w8, ...` -> `nop`

## Why These Gates Are Correct

### Facts from IDA / disassembly

The upstream-matching helper contains the local block:

```asm
ldr w0, [x20]
bl  ...
cbz x0, fail_alt
ldr w8, [x21, #0x18]
cbz w8, continue
ldr w8, [x20, #8]
cbz w8, deny      ; patched
ldr w8, [x20, #0xc]
cbz w8, deny      ; patched
mov x8, #0
ldr w9, [x19, #0x490]
add x10, x0, #0x140
casa x8, x9, [x10]
```

Both patched `cbz` instructions jump to the same deny-return block.

### Facts from XNU semantics

This helper is a compact persona validation subroutine in the spawn/exec policy path. The two sibling `cbz` guards are the local nil / missing-field reject gates immediately before the helper proceeds into the proc-backed persona state update path.

### Conclusion

The upstream pair is the correct semantic gate because:

- it is the exact pair patched by the known-good upstream tool,
- both branches converge on the helper's deny path,
- they live in the small validation helper reached from the outer spawn entitlement wrapper,
- and they are narrower and more precise than the previously drifted outer `tbz` bypass.

## Match vs Divergence

- Upstream relation: `match`.
- Explicitly rejected divergence: outer branch rewrite at `0x00FA694C` / `0x00F6A94C`.
- Why rejected: although that outer gate also affects persona validation, it is broader than the upstream helper-local reject sites and was not necessary once the true upstream helper was recovered.

## Reveal Procedure

1. Find the outer spawn policy wrapper by the in-image entitlement string `"com.apple.private.spawn-panic-crash-behavior"`.
2. Enumerate BL callees inside that wrapper.
3. Keep only small local helpers.
4. Select the unique helper whose decoded CFG contains:
   - `ldr [arg,#8] ; cbz deny`
   - `ldr [arg,#0xc] ; cbz deny`
   - shared deny target
   - nearby `ldr [x19,#0x490] ; ... ; casa` sequence.
5. Patch both helper-local `cbz` instructions with `NOP`.

## Validation

- PCC 26.1 research dry-run: `hit` at `0x00FA7024` and `0x00FA702C`
- PCC 26.1 release dry-run: `hit` at `0x00F6B024` and `0x00F6B02C`
- Match verdict vs `/Users/qaq/Desktop/patch_fw.py`: `match`

## Files

- Patcher: `scripts/patchers/kernel_jb_patch_spawn_persona.py`
- Analysis doc: `research/kernel_jailbreak_patches/patch_spawn_validate_persona.md`

## 2026-03-06 Rework

- Upstream target (`/Users/qaq/Desktop/patch_fw.py`): `match`.
- Final research sites: `0x00FA7024` (`0xFFFFFE0007FAB024`) and `0x00FA702C` (`0xFFFFFE0007FAB02C`).
- Anchor class: `string`. Runtime reveal starts from the stable entitlement string `"com.apple.private.persona-mgmt"`, resolves the small helper, and matches the exact upstream dual-`cbz` pair on the `[x20,#8]` / `[x20,#0xc]` slots.
- Why this site: it is the exact known-good upstream zero-check pair inside the persona validation helper. The previous drift to `0x00FA694C` patched a broader exec-path branch and did not match the upstream helper or XNU `spawn_validate_persona(...)` logic.
- Release/generalization rationale: entitlement strings are stable across stripped kernels, and the dual-load/dual-cbz shape is tiny and source-backed.
- Performance note: one string-xref resolution plus a very small helper-local scan.
- Focused PCC 26.1 research dry-run: `hit`, 2 writes at `0x00FA7024` and `0x00FA702C`.
