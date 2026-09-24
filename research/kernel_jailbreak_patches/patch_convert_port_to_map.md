# B8 `patch_convert_port_to_map`

## Patch Goal

Disable the panic path when userspace-controlled conversion reaches `kernel_map`, by forcing execution into the normal non-panic branch.

## Binary Targets (IDA + Recovered Symbols)

- Recovered symbol: `convert_port_to_map_with_flavor` at `0xfffffe0007b12024`.
- Panic string: `"userspace has control access to a kernel map %p through task %p @%s:%d"` at `0xfffffe0007040a32`.
- String xref: `0xfffffe0007b12118` in `sub_FFFFFE0007B12024`.

## Call-Stack Analysis

- Representative static callers of `convert_port_to_map_with_flavor`:
  - `sub_FFFFFE0007B89228`
  - `sub_FFFFFE0007B89F5C`
  - `sub_FFFFFE0007B8F2D0`
  - plus many IPC/task-port callsites
- In-function control flow:
  - map pointer PAC/auth checks
  - compare against `kernel_map`
  - conditional branch to safe path vs panic formatting + `_panic`.

## Patch-Site / Byte-Level Change

- Patch site: `0xfffffe0007b12100`
- Before:
  - bytes: `A1 02 00 54`
  - asm: `B.NE loc_FFFFFE0007B12154`
- After:
  - bytes: `09 00 00 14`
  - asm: `B #0x24` (to same safe target)

## Pseudocode (Before)

```c
if (map != kernel_map) {
    goto normal_path;
}
panic("userspace has control access to a kernel map ...");
```

## Pseudocode (After)

```c
goto normal_path;   // unconditional branch
```

## Symbol Consistency

- Recovered symbol name and disassembly semantics are consistent.

## Patch Metadata

- Patch document: `patch_convert_port_to_map.md` (B8).
- Primary patcher module: `scripts/patchers/kernel_jb_patch_port_to_map.py`.
- Analysis mode: static binary analysis (IDA-MCP + disassembly + recovered symbols), no runtime patch execution.

## Target Function(s) and Binary Location

- Primary target: `convert_port_to_map_with_flavor` path (symbol recovery + matcher-resolved helper).
- Patchpoint and branch-skip address are documented in the existing patch-site section.

## Kernel Source File Location

- Likely XNU source family: `osfmk/vm/vm_map.c` (port-to-map conversion helpers).
- Confidence: `medium`.

## Function Call Stack

- Primary traced chain (from `Call-Stack Analysis`):
- Representative static callers of `convert_port_to_map_with_flavor`:
- `sub_FFFFFE0007B89228`
- `sub_FFFFFE0007B89F5C`
- `sub_FFFFFE0007B8F2D0`
- plus many IPC/task-port callsites
- The upstream entry(s) and patched decision node are linked by direct xref/callsite evidence in this file.

## Patch Hit Points

- Key patchpoint evidence (from `Patch-Site / Byte-Level Change`):
- Patch site: `0xfffffe0007b12100`
- Before:
- bytes: `A1 02 00 54`
- asm: `B.NE loc_FFFFFE0007B12154`
- After:
- bytes: `09 00 00 14`
- The before/after instruction transform is constrained to this validated site.

## Current Patch Search Logic

- Implemented in `scripts/patchers/kernel_jb_patch_port_to_map.py`.
- Site resolution uses anchor + opcode-shape + control-flow context; ambiguous candidates are rejected.
- The patch is applied only after a unique candidate is confirmed in-function.
- Uses string anchors + instruction-pattern constraints + structural filters (for example callsite shape, branch form, register/imm checks).

## Validation (Static Evidence)

- Verified with IDA-MCP disassembly/decompilation, xrefs, and callgraph context for the selected site.
- Cross-checked against recovered symbols in `research/kernel_symbols/json/kernelcache.research.vphone600.bin.symbols.json`.
- Address-level evidence in this document is consistent with patcher matcher intent.

## Expected Failure/Panic if Unpatched

- Invalid/strict map-flavor checks can hit the kernel panic/deny path in convert-port-to-map flow.

## Risk / Side Effects

- This patch weakens a kernel policy gate by design and can broaden behavior beyond stock security assumptions.
- Potential side effects include reduced diagnostics fidelity and wider privileged surface for patched workflows.

## Symbol Consistency Check

- Recovered-symbol status in `kernelcache.research.vphone600.bin.symbols.json`: `match`.
- Canonical symbol hit(s): `convert_port_to_map_with_flavor`.
- Where canonical names are absent, this document relies on address-level control-flow and instruction evidence; analyst aliases are explicitly marked as aliases.
- IDA-MCP lookup snapshot (2026-03-05): `convert_port_to_map_with_flavor` -> `convert_port_to_map_with_flavor` at `0xfffffe0007b12024`.

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
- Included in `KernelJBPatcher.find_all()`: `True`
- IDA mapping: `1/1` points in recognized functions; `0` points are code-cave/data-table writes.
- IDA mapping status: `ok` (IDA runtime mapping loaded.)
- Call-chain mapping status: `ok` (IDA call-chain report loaded.)
- Call-chain validation: `1` function nodes, `1` patch-point VAs.
- IDA function sample: `convert_port_to_map_with_flavor`
- Chain function sample: `convert_port_to_map_with_flavor`
- Caller sample: `_X_map_exec_lockdown`, `_X_task_wire`, `_Xbehavior_set`, `_Xcopy`, `_Xmach_vm_behavior_set`, `_Xmach_vm_copy`
- Callee sample: `convert_port_to_map_with_flavor`, `sub_FFFFFE0007AE3BB8`, `sub_FFFFFE0007B10E70`, `sub_FFFFFE0007B1EEE0`, `sub_FFFFFE0007BCB274`, `sub_FFFFFE0007C54FD8`
- Verdict: `valid`
- Recommendation: Keep enabled for this kernel build; continue monitoring for pattern drift.
- Key verified points:
- `0xFFFFFE0007B12100` (`convert_port_to_map_with_flavor`): b 0xB0E154 [_convert_port_to_map skip panic] | `a1020054 -> 15000014`
- Artifacts: `research/kernel_jailbreak_patches/runtime_verification/runtime_verification_report.json`
- Artifacts: `research/kernel_jailbreak_patches/runtime_verification/ida_runtime_patch_points.json`
- Artifacts: `research/kernel_jailbreak_patches/runtime_verification/ida_patch_chain_report.json`
- Artifacts: `research/kernel_jailbreak_patches/runtime_verification/ida_patch_chain_report.md`
<!-- END_RUNTIME_IDA_VERIFICATION_2026_03_05 -->

## 2026-03-06 Upstream Rework Review

- `patch_fw.py` targets the kernel-map panic bypass at `0x00B02E94`; release lands at `0x00AC6E94`. The current string-backed matcher still lands on those exact branch sites.
- IDA confirms the upstream block shape at `0xFFFFFE0007B06E94`: `cmp X16, X8 ; b.ne normal ; ... panic("userspace has control access to a kernel map...")`. This matches the kernel-map panic path in `research/reference/xnu/osfmk/kern/ipc_tt.c`.
- No code change was needed in this pass. Focused dry-run (`2026-03-06`): research `0x00B02E94`; release `0x00AC6E94`.
