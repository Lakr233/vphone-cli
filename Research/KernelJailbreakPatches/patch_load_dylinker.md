# B16 `patch_load_dylinker`

## Patch Goal

Bypass the strict `LC_LOAD_DYLINKER` path string gate so the loader does not reject when the dyld path check fails.

## Binary Targets (IDA + Recovered Symbols)

- Recovered symbol: `load_dylinker` at `0xfffffe000805fe44`.
- Dyld path anchor string: `"/usr/lib/dyld"` at `0xfffffe0007089e2c`.
- String xref in target function: `0xfffffe000805fec4`.

## Call-Stack Analysis

- Static caller of `load_dylinker`:
  - `sub_FFFFFE000805DF38` (xref at `0xfffffe000805ebec`).
- This function is in the Mach-O load command handling pipeline and is reached from parse/load stages before later AMFI checks.

## Patch-Site / Byte-Level Change

Validated gate in `load_dylinker`:

- `0xfffffe000805fec4`: `ADRL X1, "/usr/lib/dyld"`
- `0xfffffe000805fecc`: `MOV X0, X20`
- `0xfffffe000805fed0`: `BL sub_FFFFFE0007C2A218`
- `0xfffffe000805fed4`: `CBZ W0, loc_FFFFFE000805FF14`
- `0xfffffe000805fed8`: `MOV W0, #2`

Patch operation:

- Replace `BL` at `0xfffffe000805fed0` with unconditional branch to allow target `0xfffffe000805ff14`.

Bytes:

- before (`BL`): `D2 28 EF 97`
- after (`B #0x44`): `11 00 00 14`

## Pseudocode (Before)

```c
ok = dyld_path_check(candidate_path, "/usr/lib/dyld");
if (ok == 0) {
    goto allow;
}
return 2;
```

## Pseudocode (After)

```c
/* dyld string verification call is skipped */
ok = 0;
if (ok == 0) {
    goto allow;
}
```

## Why This Matters

This gate executes early in image loading. Without bypassing it, binaries can fail before downstream jailbreak-oriented relaxations are even relevant.

## Symbol Consistency Audit (2026-03-05)

- Status: `match`
- Function symbol, string anchor, and patch-site control-flow all agree on `load_dylinker`.

## Patch Metadata

- Patch document: `patch_load_dylinker.md` (B16).
- Primary patcher module: `scripts/patchers/kernel_jb_patch_load_dylinker.py`.
- Analysis mode: static binary analysis (IDA-MCP + disassembly + recovered symbols), no runtime patch execution.

## Target Function(s) and Binary Location

- Primary target: recovered symbol `load_dylinker` and strict dylinker-string enforcement branch.
- Patchpoint: conditional check rewritten to branch-over deny path.

## Kernel Source File Location

- Expected XNU source: `bsd/kern/mach_loader.c` (`load_dylinker` path).
- Confidence: `high`.

## Function Call Stack

- Primary traced chain (from `Call-Stack Analysis`):
- Static caller of `load_dylinker`:
- `sub_FFFFFE000805DF38` (xref at `0xfffffe000805ebec`).
- This function is in the Mach-O load command handling pipeline and is reached from parse/load stages before later AMFI checks.
- The upstream entry(s) and patched decision node are linked by direct xref/callsite evidence in this file.

## Patch Hit Points

- Key patchpoint evidence (from `Patch-Site / Byte-Level Change`):
- `0xfffffe000805fec4`: `ADRL X1, "/usr/lib/dyld"`
- `0xfffffe000805fecc`: `MOV X0, X20`
- `0xfffffe000805fed0`: `BL sub_FFFFFE0007C2A218`
- `0xfffffe000805fed4`: `CBZ W0, loc_FFFFFE000805FF14`
- `0xfffffe000805fed8`: `MOV W0, #2`
- Replace `BL` at `0xfffffe000805fed0` with unconditional branch to allow target `0xfffffe000805ff14`.
- The before/after instruction transform is constrained to this validated site.

## Current Patch Search Logic

- Implemented in `scripts/patchers/kernel_jb_patch_load_dylinker.py`.
- Site resolution uses anchor + opcode-shape + control-flow context; ambiguous candidates are rejected.
- The patch is applied only after a unique candidate is confirmed in-function.
- Dyld path anchor string: `"/usr/lib/dyld"` at `0xfffffe0007089e2c`.
- Function symbol, string anchor, and patch-site control-flow all agree on `load_dylinker`.

## Validation (Static Evidence)

- Verified with IDA-MCP disassembly/decompilation, xrefs, and callgraph context for the selected site.
- Cross-checked against recovered symbols in `research/kernel_symbols/json/kernelcache.research.vphone600.bin.symbols.json`.
- Address-level evidence in this document is consistent with patcher matcher intent.

## Expected Failure/Panic if Unpatched

- Strict `LC_LOAD_DYLINKER == /usr/lib/dyld` gate can reject modified loader scenarios used in jailbreak bring-up.

## Risk / Side Effects

- This patch weakens a kernel policy gate by design and can broaden behavior beyond stock security assumptions.
- Potential side effects include reduced diagnostics fidelity and wider privileged surface for patched workflows.

## Symbol Consistency Check

- Recovered-symbol status in `kernelcache.research.vphone600.bin.symbols.json`: `match`.
- Canonical symbol hit(s): `load_dylinker`.
- Where canonical names are absent, this document relies on address-level control-flow and instruction evidence; analyst aliases are explicitly marked as aliases.
- IDA-MCP lookup snapshot (2026-03-05): `load_dylinker` -> `load_dylinker` at `0xfffffe000805fe44`.

## Open Questions and Confidence

- Open question: verify future firmware drift does not move this site into an equivalent but semantically different branch.
- Overall confidence for this patch analysis: `high` (symbol match + control-flow/byte evidence).

## Evidence Appendix

- Detailed addresses, xrefs, and rationale are preserved in the existing analysis sections above.
- For byte-for-byte patch details, refer to the patch-site and call-trace subsections in this file.

## Runtime + IDA Verification (2026-03-05)

- Verification timestamp (UTC): `2026-03-05T14:55:58.795709+00:00`
- Kernel input: `/Users/qaq/Documents/Firmwares/PCC-CloudOS-26.3-23D128/kernelcache.research.vphone600`
- Base VA: `0xFFFFFE0007004000`
- Runtime status: `hit` (1 patch writes, method_return=True)
- Included in `KernelJBPatcher.find_all()`: `False`
- IDA mapping: `1/1` points in recognized functions; `0` points are code-cave/data-table writes.
- IDA mapping status: `ok` (IDA runtime mapping loaded.)
- Call-chain mapping status: `ok` (IDA call-chain report loaded.)
- Call-chain validation: `1` function nodes, `1` patch-point VAs.
- IDA function sample: `load_dylinker`
- Chain function sample: `load_dylinker`
- Caller sample: `sub_FFFFFE000805DF38`
- Callee sample: `kfree_ext`, `load_dylinker`, `namei`, `sub_FFFFFE0007AC5700`, `sub_FFFFFE0007B1663C`, `sub_FFFFFE0007B80584`
- Verdict: `questionable`
- Recommendation: Hit is valid but patch is inactive in find_all(); enable only after staged validation.
- Key verified points:
- `0xFFFFFE000805FED0` (`load_dylinker`): b #0x44 [_load_dylinker policy bypass] | `d228ef97 -> 11000014`
- Artifacts: `research/kernel_jailbreak_patches/runtime_verification/runtime_verification_report.json`
- Artifacts: `research/kernel_jailbreak_patches/runtime_verification/ida_runtime_patch_points.json`
- Artifacts: `research/kernel_jailbreak_patches/runtime_verification/ida_patch_chain_report.json`
- Artifacts: `Research/KernelJailbreakPatches/RuntimeVerification/ida_patch_chain_report.md`
<!-- END_RUNTIME_IDA_VERIFICATION_2026_03_05 -->

## 2026-03-06 Upstream Rework Review

- `patch_fw.py` continues to be the right target: research patches `0x01052A28`; release patches `0x01016A28`.
- IDA still shows the same upstream gate shape in the `/usr/lib/dyld`-anchored function: `bl policy_check ; cbz w0, allow ; mov w0,#2`. The current matcher keeps this one string-backed reveal and no longer carries any symbol-first branch.
- No retarget was needed in this pass; focused dry-run (`2026-03-06`) remains exact on both kernels.
