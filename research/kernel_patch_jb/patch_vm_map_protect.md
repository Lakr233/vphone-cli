# B10 `patch_vm_map_protect`

## 2026-03-06 PCC 26.1 Rework Status

- Preferred upstream reference: `/Users/qaq/Desktop/patch_fw.py`.
- Final status on PCC 26.1 research: **match upstream**.
- Upstream patch site: file offset `0x00BC024C` (`patch(0xBC024C, 0x1400000A)`).
- Final JB patcher site: file offset `0x00BC024C`, VA `0xfffffe0007bc424c`.
- Repo drift removed: the previous repo-only `0x00BC012C` / `TBNZ X24,#0x20` site is no longer accepted because it does **not** match the known-good upstream gate and is not the correct XNU-backed write-downgrade decision point for PCC 26.1 research.

## Preferred Design Target Check

- **Match vs upstream:** `match`.
- **Why this is the preferred gate:** upstream patches the `B.NE` that skips the block clearing `VM_PROT_WRITE` from combined read+write requests. IDA on PCC 26.1 research shows the same local block still exists unchanged.
- **Red-flag review result:** the earlier repo drift to `0x00BC012C` was a real divergence from upstream. It was removed rather than justified, because IDA + XNU semantics point back to the upstream gate.

## Final Patch Site (PCC 26.1 Research)

- Function anchor: the in-image panic string `"vm_map_protect(%p,0x%llx,0x%llx) new=0x%x wired=%x @%s:%d"`, whose xref lands inside the same `vm_map_protect` body.
- Patched instruction: `0xfffffe0007bc424c` / file offset `0x00BC024C`.
- Before: `b.ne #0xbc0274`.
- After: `b #0xbc0274`.
- Nearby validated block in IDA:
  - `mov w9, #6`
  - `bics wzr, w9, w20`
  - `b.ne #0xbc0274` ← patched
  - `tbnz w8, #0x16, #0xbc0274`
  - ...
  - `and w20, w20, #0xfffffffb`

## Why This Gate Is Correct

- **Fact (IDA):** the branch at `0x00BC024C` skips a small block whose only semantic effect on the requested protection register is `and w20, w20, #0xfffffffb`, i.e. clear bit `0x4` (`VM_PROT_WRITE`).
- **Fact (XNU):** `research/reference/xnu/osfmk/vm/vm_map.c` contains the corresponding logic:
  - `if ((~v5 & 6) == 0 && (v22 & 0x400000) == 0) { ... v5 &= ~4u; }`
- **Inference:** on PCC 26.1 research, `w20` is the local requested-protection value and this block is still the write-downgrade path that upstream intended to bypass.
- **Conclusion:** rewriting the first skip branch to unconditional `b` preserves the known-good upstream behavior: always bypass the downgrade block, instead of patching an earlier unrelated status-bit test.

## Reveal Procedure Used In The Reworked Matcher

1. Recover the function containing the in-image `vm_map_protect(` panic string.
2. Scan only within that function.
3. Find the unique local sequence:
   - `mov wMask, #6`
   - `bics wzr, wMask, wProt`
   - `b.ne skip`
   - `tbnz wEntryFlags, #22, skip`
   - later in the skipped block: `and wProt, wProt, #~VM_PROT_WRITE`
4. Rewrite only that `b.ne` to an unconditional branch to the same target.

## Focused Validation (2026-03-06)

- Research kernel used: extracted raw Mach-O `/tmp/vphone-kcache-research-26.1.raw`.
- Research outcome: `hit` at `0x00BC024C`.
- Research emitted patch: `b #0x28 [_vm_map_protect]`.
- Release kernel used: extracted raw Mach-O `/tmp/vphone-kcache-release-26.1.raw`.
- Release outcome: `hit` at `0x00B8424C`.
- Release emitted patch: `b #0x28 [_vm_map_protect]`.
- Method: focused `KernelJBPatcher.patch_vm_map_protect()` dry-runs, in the Python environment this repository had on that date. Both the Python patcher and that environment are gone; the port is `sources/FirmwarePatcher/Kernel/JBPatches/`.
- Result: the reworked matcher hits the same semantic gate on both PCC 26.1 research and PCC 26.1 release, and the research hit **matches upstream exactly**.

## Why This Should Generalize Beyond The Current Research Image

- The matcher does **not** key on a hardcoded offset, a specific file-layout delta, or a single fragile operand string.
- It anchors on an in-image `vm_map_protect(` panic string that is tied to the same core VM function across variants.
- Inside that function it requires a compact semantic micro-CFG, not a single mnemonic:
  - `mov wMask, #6` (combined read+write test)
  - `bics wzr, wMask, wProt`
  - `b.ne skip`
  - `tbnz wEntryFlags, #22, skip`
  - later `and wProt, wProt, #~VM_PROT_WRITE`
- That shape is directly backed by the XNU write-downgrade logic, so it should survive ordinary offset drift between PCC 26.1 research, PCC 26.1 release, and likely nearby 26.3 release kernels unless Apple materially restructures this code path.
- If Apple does materially restructure it, the matcher fails closed by requiring a unique hit rather than guessing.

## Runtime Matcher Cost

- Search scope is limited to one recovered function body, not the whole kernel text.
- The scan is linear over that function with small fixed-width decode windows (`10` instructions for the main pattern, `1` instruction for the local write-clear search).
- This keeps the runtime cost negligible relative to the broader JB patch pass while still being much more semantic than the earlier shallow `tbnz bit>=24` heuristic.

## Superseded Earlier Analysis

The older `0x00BC012C` / `TBNZ X24,#0x20` analysis below is retained only as historical context. It is superseded by the 2026-03-06 rework above and should not be treated as the preferred patch design for PCC 26.1 research.

## Patch Goal

Bypass a high-bit protection guard by converting a `TBNZ` check into unconditional `B`.

## Binary Targets (IDA + Recovered Symbols)

- Recovered symbol: `vm_map_protect` at `0xfffffe0007bd08d8`.
- Anchor string: `"vm_map_protect(%p,0x%llx,0x%llx) new=0x%x wired=%x @%s:%d"` at `0xfffffe0007049e44`.
- Anchor xref: `0xfffffe0007bd0efc` in `vm_map_protect`.

## Call-Stack Analysis

Representative static callers of `vm_map_protect` include:

- `sub_FFFFFE0007AF3968`
- `sub_FFFFFE0007B90928`
- `sub_FFFFFE0007B9F844`
- `sub_FFFFFE0007FD6EB0`
- additional VM/subsystem callsites

## Patch-Site / Byte-Level Change

- Selected guard site: `0xfffffe0007bd09a8`
- Before:
  - bytes: `78 24 00 B7`
  - asm: `TBNZ X24, #0x20, loc_FFFFFE0007BD0E34`
- After:
  - bytes: `23 01 00 14`
  - asm: `B #0x48C` (to same target)

## Pseudocode (Before)

```c
if (test_bit(flags, 0x20)) {
    goto guarded_path;
}
```

## Pseudocode (After)

```c
goto guarded_path;   // unconditional
```

## Symbol Consistency

- Recovered symbol name and patch context are consistent.

## Patch Metadata

- Patch document: `patch_vm_map_protect.md` (B10).
- Primary patcher module: `scripts/patchers/kernel_jb_patch_vm_protect.py`.
- Analysis mode: static binary analysis (IDA-MCP + disassembly + recovered symbols), no runtime patch execution.

## Target Function(s) and Binary Location

- Primary target: recovered symbol `vm_map_protect`.
- Patchpoint: `0xfffffe0007bd09a8` (`tbnz` -> unconditional `b`).

## Kernel Source File Location

- Expected XNU source: `osfmk/vm/vm_user.c` (`vm_map_protect`).
- Confidence: `high`.

## Function Call Stack

- Primary traced chain (from `Call-Stack Analysis`):
- Representative static callers of `vm_map_protect` include:
- `sub_FFFFFE0007AF3968`
- `sub_FFFFFE0007B90928`
- `sub_FFFFFE0007B9F844`
- `sub_FFFFFE0007FD6EB0`
- The upstream entry(s) and patched decision node are linked by direct xref/callsite evidence in this file.

## Patch Hit Points

- Key patchpoint evidence (from `Patch-Site / Byte-Level Change`):
- Selected guard site: `0xfffffe0007bd09a8`
- Before:
- bytes: `78 24 00 B7`
- asm: `TBNZ X24, #0x20, loc_FFFFFE0007BD0E34`
- After:
- bytes: `23 01 00 14`
- The before/after instruction transform is constrained to this validated site.

## Current Patch Search Logic

- Implemented in `scripts/patchers/kernel_jb_patch_vm_protect.py`.
- Site resolution uses anchor + opcode-shape + control-flow context; ambiguous candidates are rejected.
- The patch is applied only after a unique candidate is confirmed in-function.
- Anchor string: `"vm_map_protect(%p,0x%llx,0x%llx) new=0x%x wired=%x @%s:%d"` at `0xfffffe0007049e44`.
- Anchor xref: `0xfffffe0007bd0efc` in `vm_map_protect`.

## Validation (Static Evidence)

- Verified with IDA-MCP disassembly/decompilation, xrefs, and callgraph context for the selected site.
- Cross-checked against recovered symbols in `research/kernel_info/json/kernelcache.research.vphone600.bin.symbols.json`.
- Address-level evidence in this document is consistent with patcher matcher intent.

## Expected Failure/Panic if Unpatched

- High-bit protect guard keeps enforcing restrictive branch, causing vm_protect denial in jailbreak memory workflows.

## Risk / Side Effects

- This patch weakens a kernel policy gate by design and can broaden behavior beyond stock security assumptions.
- Potential side effects include reduced diagnostics fidelity and wider privileged surface for patched workflows.

## Symbol Consistency Check

- Recovered-symbol status in `kernelcache.research.vphone600.bin.symbols.json`: `match`.
- Canonical symbol hit(s): `vm_map_protect`.
- Where canonical names are absent, this document relies on address-level control-flow and instruction evidence; analyst aliases are explicitly marked as aliases.
- IDA-MCP lookup snapshot (2026-03-05): `vm_map_protect` -> `vm_map_protect` at `0xfffffe0007bd08d8`.

## Open Questions and Confidence

- Open question: verify future firmware drift does not move this site into an equivalent but semantically different branch.
- Overall confidence for this patch analysis: `high` (symbol match + control-flow/byte evidence).

## Evidence Appendix

- Detailed addresses, xrefs, and rationale are preserved in the existing analysis sections above.
- For byte-for-byte patch details, refer to the patch-site and call-trace subsections in this file.

## Runtime + IDA Verification (2026-03-05, historical)

> Historical note: this older runtime-verification block is preserved for traceability only. Its `0x00BC012C` / `0xFFFFFE0007BD09A8` analysis is superseded by the 2026-03-06 upstream-aligned rework above, whose accepted site is `0x00BC024C` / `0xFFFFFE0007BC424C`.

- Verification timestamp (UTC): `2026-03-05T14:55:58.795709+00:00`
- Kernel input: `/Users/qaq/Documents/Firmwares/PCC-CloudOS-26.3-23D128/kernelcache.research.vphone600`
- Base VA: `0xFFFFFE0007004000`
- Runtime status: `hit` (1 patch writes, method_return=True)
- Included in `KernelJBPatcher.find_all()`: `False`
- IDA mapping: `1/1` points in recognized functions; `0` points are code-cave/data-table writes.
- IDA mapping status: `ok` (IDA runtime mapping loaded.)
- Call-chain mapping status: `ok` (IDA call-chain report loaded.)
- Call-chain validation: `1` function nodes, `1` patch-point VAs.
- IDA function sample: `vm_map_protect`
- Chain function sample: `vm_map_protect`
- Caller sample: `_Xmach_vm_protect`, `_Xprotect`, `__ZN27IOGuardPageMemoryDescriptor5doMapEP7_vm_mapPyjyy`, `mach_vm_protect_trap`, `mprotect`, `setrlimit`
- Callee sample: `lck_rw_done`, `pmap_protect_options`, `sub_FFFFFE0007B1D788`, `sub_FFFFFE0007B1EBF0`, `sub_FFFFFE0007B840E0`, `sub_FFFFFE0007B84C5C`
- Verdict: `questionable`
- Recommendation: Hit is valid but patch is inactive in find_all(); enable only after staged validation.
- Key verified points:
- `0xFFFFFE0007BD09A8` (`vm_map_protect`): b #0x48C [_vm_map_protect] | `782400b7 -> 23010014`
- Artifacts: `research/kernel_patch_jb/runtime_verification/runtime_verification_report.json`
- Artifacts: `research/kernel_patch_jb/runtime_verification/ida_runtime_patch_points.json`
- Artifacts: `research/kernel_patch_jb/runtime_verification/ida_patch_chain_report.json`
- Artifacts: `research/kernel_patch_jb/runtime_verification/ida_patch_chain_report.md`
<!-- END_RUNTIME_IDA_VERIFICATION_2026_03_05 -->

## 2026-03-06 Rework

- Upstream target (`/Users/qaq/Desktop/patch_fw.py`): `match`.
- Final research site: `0x00BC024C` (`0xFFFFFE0007BC424C`).
- Anchor class: `string`. Runtime reveal starts from the in-image `"vm_map_protect("` string, resolves the function, then matches the unique write-downgrade block `mov #6 ; bics wzr,mask,prot ; b.ne skip ; tbnz #22,skip ; ... and prot,#~VM_PROT_WRITE`.
- Why this site: it is the exact upstream branch gate that conditionally strips `VM_PROT_WRITE` before later VME updates. The older drift to `0x00BC012C` lands in unrelated preflight/error handling and is rejected.
- Release/generalization rationale: the panic string and the local BICS/TBNZ/write-clear shape are source-backed and should survive stripped release kernels with low matcher cost.
- Performance note: one string-xref resolution and one function-local scan with a short semantic confirmation window.
- Focused PCC 26.1 research dry-run: `hit`, 1 write at `0x00BC024C`.
