# A3 `patch_task_conversion_eval_internal`

## Patch Goal

Neutralize a task-conversion compare guard by replacing `cmp Xn, x0` with `cmp xzr, xzr` at the validated guard site.

## Binary Targets (IDA + Recovered Symbols)

- High-confidence control function (IPC/task conversion cluster):
  - `sub_FFFFFE0007B10334` (contains `ipc_tt.c` + pineapple assertion path)
- Validated compare site:
  - `0xfffffe0007b10400`: `CMP X9, X0`

## Call-Stack Analysis

Representative callers of `sub_FFFFFE0007B10334`:

- `sub_FFFFFE0007B10118`
- `sub_FFFFFE0007B109C0`
- `sub_FFFFFE0007B10E70`
- `sub_FFFFFE0007B11B1C`
- `sub_FFFFFE0007B12200`

Local control motif at patch site:

- `LDR X9, [...]`
- `CMP X9, X0`
- `B.EQ ...`
- `CMP X9, X1`
- `B.EQ ...`
- downstream call + `CBZ/CBNZ W0`

## Patch-Site / Byte-Level Change

- Patch site: `0xfffffe0007b10400`
- Before:
  - bytes: `3F 01 00 EB`
  - asm: `CMP X9, X0`
- After:
  - bytes: `FF 03 1F EB`
  - asm: `CMP XZR, XZR`

## Pseudocode (Before)

```c
if (ref == task0) goto allow;
if (ref == task1) goto allow_alt;
```

## Pseudocode (After)

```c
if (true) goto allow;   // compare neutralized
```

## Symbol Consistency

- Exact symbol name `task_conversion_eval_internal` is not recovered.
- Function behavior and string context (`ipc_tt.c` / task-thread assertion text) are consistent with task-conversion guard semantics.

## Patch Metadata

- Patch document: `patch_task_conversion_eval_internal.md` (A3).
- Primary patcher module: `scripts/patchers/kernel_jb_patch_task_conversion.py`.
- Analysis mode: static binary analysis (IDA-MCP + disassembly + recovered symbols), no runtime patch execution.

## Target Function(s) and Binary Location

- Primary target: recovered symbol `task_conversion_eval_internal`.
- Patchpoint: comparison check rewritten to `cmp xzr,xzr` to force allow semantics.

## Kernel Source File Location

- Expected XNU source: `osfmk/kern/task.c`.
- Confidence: `high`.

## Function Call Stack

- Primary traced chain (from `Call-Stack Analysis`):
- Representative callers of `sub_FFFFFE0007B10334`:
- `sub_FFFFFE0007B10118`
- `sub_FFFFFE0007B109C0`
- `sub_FFFFFE0007B10E70`
- `sub_FFFFFE0007B11B1C`
- The upstream entry(s) and patched decision node are linked by direct xref/callsite evidence in this file.

## Patch Hit Points

- Key patchpoint evidence (from `Patch-Site / Byte-Level Change`):
- Patch site: `0xfffffe0007b10400`
- Before:
- bytes: `3F 01 00 EB`
- asm: `CMP X9, X0`
- After:
- bytes: `FF 03 1F EB`
- The before/after instruction transform is constrained to this validated site.

## Current Patch Search Logic

- Implemented in `scripts/patchers/kernel_jb_patch_task_conversion.py`.
- Site resolution uses anchor + opcode-shape + control-flow context; ambiguous candidates are rejected.
- The patch is applied only after a unique candidate is confirmed in-function.
- Uses string anchors + instruction-pattern constraints + structural filters (for example callsite shape, branch form, register/imm checks).

## Validation (Static Evidence)

- Verified with IDA-MCP disassembly/decompilation, xrefs, and callgraph context for the selected site.
- Cross-checked against recovered symbols in `research/kernel_symbols/json/kernelcache.research.vphone600.bin.symbols.json`.
- Address-level evidence in this document is consistent with patcher matcher intent.

## Expected Failure/Panic if Unpatched

- Task conversion checks keep rejecting conversions, blocking task port and privilege escalation paths.

## Risk / Side Effects

- This patch weakens a kernel policy gate by design and can broaden behavior beyond stock security assumptions.
- Potential side effects include reduced diagnostics fidelity and wider privileged surface for patched workflows.

## Symbol Consistency Check

- Recovered-symbol status in `kernelcache.research.vphone600.bin.symbols.json`: `partial`.
- Canonical symbol hit(s): none (alias-based static matching used).
- Where canonical names are absent, this document relies on address-level control-flow and instruction evidence; analyst aliases are explicitly marked as aliases.
- IDA-MCP lookup snapshot (2026-03-05): `0xfffffe0007b10400` currently resolves to `sub_FFFFFE0007B10334` (size `0x2f0`).

## Open Questions and Confidence

- Open question: symbol recovery is incomplete for this path; aliases are still needed for parts of the call chain.
- Overall confidence for this patch analysis: `medium` (address-level semantics are stable, symbol naming is partial).

## Evidence Appendix

- Detailed addresses, xrefs, and rationale are preserved in the existing analysis sections above.
- For byte-for-byte patch details, refer to the patch-site and call-trace subsections in this file.

## Runtime + IDA Verification (2026-03-05)

- Verification timestamp (UTC): `2026-03-05T14:55:58.795709+00:00`
- Kernel input: `/Users/qaq/Documents/Firmwares/PCC-CloudOS-26.3-23D128/kernelcache.research.vphone600`
- Base VA: `0xFFFFFE0007004000`
- Runtime status: `hit` (1 patch writes, method_return=True)
- Included in `KernelJBPatcher.find_all()`: `True`
- IDA mapping: `1/1` points in recognized functions; `0` points are code-cave/data-table writes.
- IDA mapping status: `ok` (IDA runtime mapping loaded.)
- Call-chain mapping status: `ok` (IDA call-chain report loaded.)
- Call-chain validation: `1` function nodes, `1` patch-point VAs.
- IDA function sample: `sub_FFFFFE0007B10334`
- Chain function sample: `sub_FFFFFE0007B10334`
- Caller sample: `sub_FFFFFE0007B10118`, `sub_FFFFFE0007B109C0`, `sub_FFFFFE0007B10E70`, `sub_FFFFFE0007B11B1C`, `sub_FFFFFE0007B12200`, `sub_FFFFFE0007B87398`
- Callee sample: `os_ref_panic_underflow`, `sub_FFFFFE0007AE3BB8`, `sub_FFFFFE0007B0FF2C`, `sub_FFFFFE0007B10334`, `sub_FFFFFE0007B1EEE0`, `sub_FFFFFE0007B48C00`
- Verdict: `valid`
- Recommendation: Keep enabled for this kernel build; continue monitoring for pattern drift.
- Key verified points:
- `0xFFFFFE0007B10400` (`sub_FFFFFE0007B10334`): cmp xzr,xzr [_task_conversion_eval_internal] | `3f0100eb -> ff031feb`
- Artifacts: `research/kernel_jailbreak_patches/runtime_verification/runtime_verification_report.json`
- Artifacts: `research/kernel_jailbreak_patches/runtime_verification/ida_runtime_patch_points.json`
- Artifacts: `research/kernel_jailbreak_patches/runtime_verification/ida_patch_chain_report.json`
- Artifacts: `Research/KernelJailbreakPatches/RuntimeVerification/ida_patch_chain_report.md`
<!-- END_RUNTIME_IDA_VERIFICATION_2026_03_05 -->

## 2026-03-06 Upstream Rework Review

- `patch_fw.py` patches `0x00B01194`, and the current matcher still lands there on research; release lands at `0x00AC5194`.
- IDA confirms the exact upstream gate at `0xFFFFFE0007B05194`: `cmp Xn, X0 ; b.eq allow ; cmp Xn, X1 ; b.eq deny ; ... ; bl ... ; cbz w0,...`. This matches `task_conversion_eval_internal()` semantics in `research/reference/xnu/osfmk/kern/ipc_tt.c`.
- No code-path retarget was needed in this pass. The fast matcher already fails closed and the slow fallback stays disabled unless explicitly opted in with `VPHONE_TASK_CONV_ALLOW_SLOW_FALLBACK=1`.
- Focused dry-run (`2026-03-06`): research `0x00B01194`; release `0x00AC5194`.
