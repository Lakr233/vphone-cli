# B18 `patch_nvram_verify_permission`

## Patch Goal

Bypass a permission gate in NVRAM verifyPermission flow by NOP-ing a bit-test branch.

## Binary Targets (IDA + Recovered Symbols)

- Recovered symbol: `__ZL16verifyPermission16IONVRAMOperationPKhPKcbb` at `0xfffffe0008240ad8`.
- Entitlement anchor string:
  - `"com.apple.private.iokit.nvram-write-access"` at `0xfffffe00070a28b4`
  - xref in target function at `0xfffffe0008240cfc`.

## Call-Stack Analysis

- Representative callers of verifyPermission function:
  - `sub_FFFFFE0008240104`
  - `sub_FFFFFE0008240970`
  - `sub_FFFFFE0008241614`
  - `sub_FFFFFE0008243850`
  - `sub_FFFFFE000824756C`
- The function is reused across multiple NVRAM operation flows.

## Patch-Site / Byte-Level Change

- Patch site: `0xfffffe0008240b80`
- Before:
  - bytes: `88 02 00 36`
  - asm: `TBZ W8, #0, loc_FFFFFE0008240BD0`
- After:
  - bytes: `1F 20 03 D5`
  - asm: `NOP`

## Pseudocode (Before)

```c
if ((perm_flags & BIT0) == 0) {
    goto deny_path;
}
```

## Pseudocode (After)

```c
// branch removed
// fall through to permit-path logic
```

## Symbol Consistency

- Recovered symbol name and entitlement-string context are consistent.

## Patch Metadata

- Patch document: `patch_nvram_verify_permission.md` (B18).
- Primary patcher module: `scripts/patchers/kernel_jb_patch_nvram.py`.
- Analysis mode: static binary analysis (IDA-MCP + disassembly + recovered symbols), no runtime patch execution.

## Target Function(s) and Binary Location

- Primary target: NVRAM `verifyPermission` check callsite used before write/commit path.
- Patchpoint: BL/call deny gate neutralized as documented below.

## Kernel Source File Location

- Likely IOKit NVRAM component (`iokit/Kernel/IONVRAM*.cpp`) in kernel collection build.
- Confidence: `medium`.

## Function Call Stack

- Primary traced chain (from `Call-Stack Analysis`):
- Representative callers of verifyPermission function:
- `sub_FFFFFE0008240104`
- `sub_FFFFFE0008240970`
- `sub_FFFFFE0008241614`
- `sub_FFFFFE0008243850`
- The upstream entry(s) and patched decision node are linked by direct xref/callsite evidence in this file.

## Patch Hit Points

- Key patchpoint evidence (from `Patch-Site / Byte-Level Change`):
- Patch site: `0xfffffe0008240b80`
- Before:
- bytes: `88 02 00 36`
- asm: `TBZ W8, #0, loc_FFFFFE0008240BD0`
- After:
- bytes: `1F 20 03 D5`
- The before/after instruction transform is constrained to this validated site.

## Current Patch Search Logic

- Implemented in `scripts/patchers/kernel_jb_patch_nvram.py`.
- Site resolution uses anchor + opcode-shape + control-flow context; ambiguous candidates are rejected.
- The patch is applied only after a unique candidate is confirmed in-function.
- Entitlement anchor string:
- Uses string anchors + instruction-pattern constraints + structural filters (for example callsite shape, branch form, register/imm checks).

## Validation (Static Evidence)

- Verified with IDA-MCP disassembly/decompilation, xrefs, and callgraph context for the selected site.
- Cross-checked against recovered symbols in `research/kernel_symbols/json/kernelcache.research.vphone600.bin.symbols.json`.
- Address-level evidence in this document is consistent with patcher matcher intent.

## Expected Failure/Panic if Unpatched

- NVRAM writes remain denied by permission verification callback; required boot-arg/policy writes fail.

## Risk / Side Effects

- This patch weakens a kernel policy gate by design and can broaden behavior beyond stock security assumptions.
- Potential side effects include reduced diagnostics fidelity and wider privileged surface for patched workflows.

## Symbol Consistency Check

- Recovered-symbol status in `kernelcache.research.vphone600.bin.symbols.json`: `partial`.
- Canonical symbol hit(s): none (alias-based static matching used).
- Where canonical names are absent, this document relies on address-level control-flow and instruction evidence; analyst aliases are explicitly marked as aliases.
- IDA-MCP lookup snapshot (2026-03-05): `0xfffffe0008240ad8` currently resolves to `__ZL16verifyPermission16IONVRAMOperationPKhPKcbb` (size `0x438`).

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
- Included in `KernelJBPatcher.find_all()`: `False`
- IDA mapping: `1/1` points in recognized functions; `0` points are code-cave/data-table writes.
- IDA mapping status: `ok` (IDA runtime mapping loaded.)
- Call-chain mapping status: `ok` (IDA call-chain report loaded.)
- Call-chain validation: `1` function nodes, `1` patch-point VAs.
- IDA function sample: `__ZL16verifyPermission16IONVRAMOperationPKhPKcbb`
- Chain function sample: `__ZL16verifyPermission16IONVRAMOperationPKhPKcbb`
- Caller sample: `__ZN16IONVRAMV3Handler17setEntryForRemoveEP18nvram_v3_var_entryb`, `__ZN9IODTNVRAM26setPropertyWithGUIDAndNameEPKhPKcP8OSObject`, `sub_FFFFFE0008240970`, `sub_FFFFFE0008241614`, `sub_FFFFFE0008241EDC`, `sub_FFFFFE0008243850`
- Callee sample: `__ZL16verifyPermission16IONVRAMOperationPKhPKcbb`, `__ZN12IOUserClient18clientHasPrivilegeEPvPKc`, `sub_FFFFFE0007AC5830`, `sub_FFFFFE0007B840E0`, `sub_FFFFFE0007B84C5C`, `sub_FFFFFE0007C2A1E8`
- Verdict: `questionable`
- Recommendation: Hit is valid but patch is inactive in find_all(); enable only after staged validation.
- Key verified points:
- `0xFFFFFE0008240C24` (`__ZL16verifyPermission16IONVRAMOperationPKhPKcbb`): NOP [verifyPermission NVRAM] | `78151037 -> 1f2003d5`
- Artifacts: `research/kernel_jailbreak_patches/runtime_verification/runtime_verification_report.json`
- Artifacts: `research/kernel_jailbreak_patches/runtime_verification/ida_runtime_patch_points.json`
- Artifacts: `research/kernel_jailbreak_patches/runtime_verification/ida_patch_chain_report.json`
- Artifacts: `research/kernel_jailbreak_patches/runtime_verification/ida_patch_chain_report.md`
<!-- END_RUNTIME_IDA_VERIFICATION_2026_03_05 -->

## 2026-03-06 Upstream Rework Review

- `patch_fw.py` patches the NVRAM gate at `0x01234034`; release lands at `0x011F8034`.
- In this pass the runtime reveal was tightened to enumerate all `"krn."` refs and require a unique preceding `tbz/tbnz` gate, instead of trusting the first ref only.
- IDA still confirms the patched site as the early verifyPermission guard immediately before the `"krn."` key-prefix check.
- Focused dry-run (`2026-03-06`): research `0x01234034`; release `0x011F8034`.
