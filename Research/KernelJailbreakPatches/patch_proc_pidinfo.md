# B7 `patch_proc_pidinfo`

## Patch Goal

NOP early pid/proc guard branches in proc-info handling to avoid early rejection.

## Binary Targets (IDA + Recovered Symbols)

- Recovered symbols:
  - `proc_info` at `0xfffffe000806d4dc`
  - `proc_info_internal` at `0xfffffe000806d520`
- Pattern anchor candidate (switch-like prologue shape) resolved in:
  - function region starting near `0xfffffe000806ded8` (inside `proc_info_internal`).
- First two early guards selected:
  - `0xfffffe000806df38`: `CBZ X0, ...`
  - `0xfffffe000806df40`: `CBZ W20, ...`

## Call-Stack Analysis

- Caller into anchored proc-info internal path:
  - `sub_FFFFFE000806D520`/internal wrapper chain (`xrefs_to` includes `sub_FFFFFE000806D520` region via `0xfffffe000806d754`).
- Both guards are in early prologue validation gates.

## Patch-Site / Byte-Level Change

- Site A `0xfffffe000806df38`:
  - before bytes: `E0 40 00 B4` (`CBZ X0, ...`)
  - after bytes: `1F 20 03 D5` (`NOP`)
- Site B `0xfffffe000806df40`:
  - before bytes: `34 41 00 34` (`CBZ W20, ...`)
  - after bytes: `1F 20 03 D5` (`NOP`)

## Pseudocode (Before)

```c
if (proc_ptr == NULL) return EINVAL;
if (pid_or_flavor_guard == 0) return EINVAL;
```

## Pseudocode (After)

```c
// both early guards removed
// continue into proc_info processing path
```

## Symbol Consistency

- `proc_info` / `proc_info_internal` recovered names align with the located anchor context.
- Exact `proc_pidinfo` symbol itself is not recovered, but behavior-level matching is consistent.

## Patch Metadata

- Patch document: `patch_proc_pidinfo.md` (B7).
- Primary patcher module: `scripts/patchers/kernel_jb_patch_proc_pidinfo.py`.
- Analysis mode: static binary analysis (IDA-MCP + disassembly + recovered symbols), no runtime patch execution.

## Target Function(s) and Binary Location

- Primary target: `proc_pidinfo` path with dual deny checks.
- Patchpoints: two conditional branches NOP-ed in proc-info gating flow.

## Kernel Source File Location

- Expected XNU source: `bsd/kern/proc_info.c`.
- Confidence: `high`.

## Function Call Stack

- Primary traced chain (from `Call-Stack Analysis`):
- Caller into anchored proc-info internal path:
- `sub_FFFFFE000806D520`/internal wrapper chain (`xrefs_to` includes `sub_FFFFFE000806D520` region via `0xfffffe000806d754`).
- Both guards are in early prologue validation gates.
- The upstream entry(s) and patched decision node are linked by direct xref/callsite evidence in this file.

## Patch Hit Points

- Key patchpoint evidence (from `Patch-Site / Byte-Level Change`):
- Site A `0xfffffe000806df38`:
- before bytes: `E0 40 00 B4` (`CBZ X0, ...`)
- after bytes: `1F 20 03 D5` (`NOP`)
- Site B `0xfffffe000806df40`:
- before bytes: `34 41 00 34` (`CBZ W20, ...`)
- after bytes: `1F 20 03 D5` (`NOP`)
- The before/after instruction transform is constrained to this validated site.

## Current Patch Search Logic

- Implemented in `scripts/patchers/kernel_jb_patch_proc_pidinfo.py`.
- Site resolution uses anchor + opcode-shape + control-flow context; ambiguous candidates are rejected.
- The patch is applied only after a unique candidate is confirmed in-function.
- Pattern anchor candidate (switch-like prologue shape) resolved in:
- Caller into anchored proc-info internal path:

## Validation (Static Evidence)

- Verified with IDA-MCP disassembly/decompilation, xrefs, and callgraph context for the selected site.
- Cross-checked against recovered symbols in `research/kernel_symbols/json/kernelcache.research.vphone600.bin.symbols.json`.
- Address-level evidence in this document is consistent with patcher matcher intent.

## Expected Failure/Panic if Unpatched

- Proc pidinfo security guards keep denying restricted targets (including pid0-related queries) used by jailbreak tooling.

## Risk / Side Effects

- This patch weakens a kernel policy gate by design and can broaden behavior beyond stock security assumptions.
- Potential side effects include reduced diagnostics fidelity and wider privileged surface for patched workflows.

## Symbol Consistency Check

- Recovered-symbol status in `kernelcache.research.vphone600.bin.symbols.json`: `partial`.
- Canonical symbol hit(s): none (alias-based static matching used).
- Where canonical names are absent, this document relies on address-level control-flow and instruction evidence; analyst aliases are explicitly marked as aliases.
- IDA-MCP lookup snapshot (2026-03-05): `0xfffffe000806d4dc` currently resolves to `proc_info` (size `0x44`).

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
- Runtime status: `hit` (2 patch writes, method_return=True)
- Included in `KernelJBPatcher.find_all()`: `True`
- IDA mapping: `2/2` points in recognized functions; `0` points are code-cave/data-table writes.
- IDA mapping status: `ok` (IDA runtime mapping loaded.)
- Call-chain mapping status: `ok` (IDA call-chain report loaded.)
- Call-chain validation: `1` function nodes, `2` patch-point VAs.
- IDA function sample: `sub_FFFFFE000806DED8`
- Chain function sample: `sub_FFFFFE000806DED8`
- Caller sample: `proc_info_internal`
- Callee sample: `kdp_lightweight_fault`, `kfree_ext`, `proc_find_zombref`, `sub_FFFFFE0007B15AFC`, `sub_FFFFFE0007B1B508`, `sub_FFFFFE0007B1C348`
- Verdict: `valid`
- Recommendation: Keep enabled for this kernel build; continue monitoring for pattern drift.
- Key verified points:
- `0xFFFFFE000806DF38` (`sub_FFFFFE000806DED8`): NOP [_proc_pidinfo pid-0 guard A] | `e04000b4 -> 1f2003d5`
- `0xFFFFFE000806DF40` (`sub_FFFFFE000806DED8`): NOP [_proc_pidinfo pid-0 guard B] | `34410034 -> 1f2003d5`
- Artifacts: `research/kernel_jailbreak_patches/runtime_verification/runtime_verification_report.json`
- Artifacts: `research/kernel_jailbreak_patches/runtime_verification/ida_runtime_patch_points.json`
- Artifacts: `research/kernel_jailbreak_patches/runtime_verification/ida_patch_chain_report.json`
- Artifacts: `Research/KernelJailbreakPatches/RuntimeVerification/ida_patch_chain_report.md`
<!-- END_RUNTIME_IDA_VERIFICATION_2026_03_05 -->

## 2026-03-06 Upstream Rework Review

- `patch_fw.py` patches the two early guards at `0x01060A90` and `0x01060A98`; release lands at `0x01024A90` and `0x01024A98`.
- In this pass the runtime matcher was tightened from “first two early CBZ/CBNZ” to the precise local shape recovered from the `_proc_info` anchor: `ldr x0, [x0,#0x18] ; cbz x0, fail ; bl ... ; cbz/cbnz wN, fail`.
- This keeps the patch on the same upstream sites but removes ambiguity for later stripped release kernels.
- Focused dry-run (`2026-03-06`): research `0x01060A90/98`; release `0x01024A90/98`.
