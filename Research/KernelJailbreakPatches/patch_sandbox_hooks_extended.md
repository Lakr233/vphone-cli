# A4 `patch_sandbox_hooks_extended`

## Patch Goal

Bulk-stub extended sandbox MAC hooks to success-return stubs (`mov x0,#0 ; ret`).

## Binary Targets (IDA + Recovered Symbols)

- Seatbelt policy config region:
  - `mpc_name` -> `"Sandbox"`
  - `mpc_fullname` -> `"Seatbelt sandbox policy"`
  - `mpc_ops` table at `0xfffffe0007a66d20`
- Extended indices patched: 36 total (`201..210`, `245`, `249`, `250`, ..., `316`).
- Example resolved entries:
  - idx201 -> `0xfffffe00093a654c`
  - idx245 -> `0xfffffe00093b9110`
  - idx258 -> `0xfffffe00093b68ec`
  - idx316 -> `0xfffffe00093b3b18`

## Call-Stack Analysis

- These are data-dispatch hooks in `mac_policy_ops`.
- Runtime path is indirect:
  - MAC check site -> policy dispatch -> `ops[index]` hook target.
- Direct BL callers are not expected for most entries.

## Patch-Site / Byte-Level Change

For each resolved hook entry `H`:

- `H + 0x0`:
  - before: usually `PACIBSP`
  - after bytes: `00 00 80 D2` (`mov x0, #0`)
- `H + 0x4`:
  - before: original prologue instruction
  - after bytes: `C0 03 5F D6` (`ret`)

## Pseudocode (Before)

```c
int hook_X(args...) {
    // full sandbox policy logic
    return policy_result;
}
```

## Pseudocode (After)

```c
int hook_X(args...) {
    return 0;
}
```

## Symbol Consistency

- `mac_policy_ops` structural recovery is consistent.
- Individual hook names are index-mapped from patcher policy list, not fully recovered symbol names for every entry.

## Patch Metadata

- Patch document: `patch_sandbox_hooks_extended.md` (A4).
- Primary patcher module: `scripts/patchers/kernel_jb_patch_sandbox_extended.py`.
- Analysis mode: static binary analysis (IDA-MCP + disassembly + recovered symbols), no runtime patch execution.

## Target Function(s) and Binary Location

- Primary target set: extended sandbox MACF ops table hooks (30+ entries).
- Hit points are per-hook function entries rewritten to `mov x0,#0; ret`.

## Kernel Source File Location

- Component: Sandbox MAC policy callbacks (Seatbelt/private KC component).
- Related open-source interface: `security/mac_policy.h` callback table shape.
- Confidence: `medium`.

## Function Call Stack

- Primary traced chain (from `Call-Stack Analysis`):
- These are data-dispatch hooks in `mac_policy_ops`.
- Runtime path is indirect:
- MAC check site -> policy dispatch -> `ops[index]` hook target.
- Direct BL callers are not expected for most entries.
- The upstream entry(s) and patched decision node are linked by direct xref/callsite evidence in this file.

## Patch Hit Points

- Key patchpoint evidence (from `Patch-Site / Byte-Level Change`):
- `H + 0x0`:
- before: usually `PACIBSP`
- after bytes: `00 00 80 D2` (`mov x0, #0`)
- `H + 0x4`:
- before: original prologue instruction
- after bytes: `C0 03 5F D6` (`ret`)
- The before/after instruction transform is constrained to this validated site.

## Current Patch Search Logic

- Implemented in `scripts/patchers/kernel_jb_patch_sandbox_extended.py`.
- Site resolution uses anchor + opcode-shape + control-flow context; ambiguous candidates are rejected.
- The patch is applied only after a unique candidate is confirmed in-function.
- Uses string anchors + instruction-pattern constraints + structural filters (for example callsite shape, branch form, register/imm checks).

## Validation (Static Evidence)

- Verified with IDA-MCP disassembly/decompilation, xrefs, and callgraph context for the selected site.
- Cross-checked against recovered symbols in `research/kernel_symbols/json/kernelcache.research.vphone600.bin.symbols.json`.
- Address-level evidence in this document is consistent with patcher matcher intent.

## Expected Failure/Panic if Unpatched

- Extended sandbox callbacks continue denying file/process/system operations, breaking jailbreak userland behavior.
- IOKit policy hooks (`ops[201..210]`) can surface as:
  - `IOUC ... failed MACF in process ...`
  - data-protection path failures (for example `seputil` failing to open SEP user clients).

## 2026-03-05 Update (IOKit Hook Coverage)

- Added sandbox hook coverage for `ops[201..210]` in
  `scripts/patchers/kernel_jb_patch_sandbox_extended.py`.
- Motivation: triage of `Boot task failed: data-protection` with
  `IOUC AppleSEPUserClient failed MACF ... seputil` indicated unresolved IOKit MACF
  deny path via `policy->ops + 0x648` (index `201`).
- Note: runtime verification block below reflects the pre-extension snapshot and
  should be re-generated after the next full verification pass.

## Risk / Side Effects

- This patch weakens a kernel policy gate by design and can broaden behavior beyond stock security assumptions.
- Potential side effects include reduced diagnostics fidelity and wider privileged surface for patched workflows.

## Symbol Consistency Check

- Recovered-symbol status in `kernelcache.research.vphone600.bin.symbols.json`: `partial`.
- Canonical symbol hit(s): none (alias-based static matching used).
- Where canonical names are absent, this document relies on address-level control-flow and instruction evidence; analyst aliases are explicitly marked as aliases.
- IDA-MCP lookup snapshot (2026-03-05): `0xfffffe0007a66d20` is a patchpoint/data-site (`Not a function`), so function naming is inferred from surrounding control-flow and xrefs.

## Open Questions and Confidence

- Open question: symbol recovery is incomplete for this path; aliases are still needed for parts of the call chain.
- Overall confidence for this patch analysis: `medium` (address-level semantics are stable, symbol naming is partial).

## XNU Reference Cross-Validation (2026-03-06)

What XNU confirms:

- `mac_policy_ops` includes the same hook families this patch stubs:
  - `mpo_file_check_mmap`
  - `mpo_mount_check_mount`
  - plus broader vnode/mount/iokit check vectors
  - source: `security/mac_policy.h`
- Runtime dispatch model is consistent with this document:
  - framework call -> `MAC_CHECK(...)` -> policy callback in ops table
  - examples:
    - `mac_file_check_mmap` in `security/mac_file.c`
    - `mac_mount_check_mount` in `security/mac_vfs.c`
    - mount syscall callsite in `bsd/vfs/vfs_syscalls.c`

What XNU cannot freeze:

- The exact numeric `ops[index]` mapping for this shipping kernel image.
- Private/security policy implementation details not fully represented by open-source symbols.

Interpretation:

- XNU strongly supports the architectural model (ops-table callback dispatch),
  while per-index patchpoint correctness remains IDA/runtime-byte authoritative.

## Evidence Appendix

- Detailed addresses, xrefs, and rationale are preserved in the existing analysis sections above.
- For byte-for-byte patch details, refer to the patch-site and call-trace subsections in this file.

## Runtime + IDA Verification (2026-03-05)

- Verification timestamp (UTC): `2026-03-05T14:55:58.795709+00:00`
- Kernel input: `/Users/qaq/Documents/Firmwares/PCC-CloudOS-26.3-23D128/kernelcache.research.vphone600`
- Base VA: `0xFFFFFE0007004000`
- Runtime status: `hit` (52 patch writes, method_return=True)
- Included in `KernelJBPatcher.find_all()`: `True`
- IDA mapping: `52/52` points in recognized functions; `0` points are code-cave/data-table writes.
- IDA mapping status: `ok` (IDA runtime mapping loaded.)
- Call-chain mapping status: `ok` (IDA call-chain report loaded.)
- Call-chain validation: `14` function nodes, `52` patch-point VAs.
- IDA function sample: `_hook_vnode_check_create`, `_hook_vnode_check_exec`, `_hook_vnode_check_unlink`, `sub_FFFFFE00093B3B18`, `sub_FFFFFE00093B711C`, `sub_FFFFFE00093B7404`
- Chain function sample: `_hook_vnode_check_create`, `_hook_vnode_check_exec`, `_hook_vnode_check_unlink`, `sub_FFFFFE00093B3B18`, `sub_FFFFFE00093B711C`, `sub_FFFFFE00093B7404`
- Caller sample: `_hook_vnode_check_create`, `_hook_vnode_check_rename`, `sub_FFFFFE00093B39C0`, `sub_FFFFFE00093B711C`, `sub_FFFFFE00093B7404`, `sub_FFFFFE00093B7560`
- Callee sample: `_hook_vnode_check_clone`, `_hook_vnode_check_create`, `_hook_vnode_check_exec`, `_hook_vnode_check_unlink`, `_link_privilege_escalation_check`, `_rootless_forbid_xattr`
- Verdict: `valid`
- Recommendation: Keep enabled for this kernel build; continue monitoring for pattern drift.
- Key verified points:
- `0xFFFFFE00093B3B18` (`sub_FFFFFE00093B3B18`): mov x0,#0 [_hook_vnode_check_fsgetpath] | `7f2303d5 -> 000080d2`
- `0xFFFFFE00093B3B1C` (`sub_FFFFFE00093B3B18`): ret [_hook_vnode_check_fsgetpath] | `f44fbea9 -> c0035fd6`
- `0xFFFFFE00093B5100` (`_hook_vnode_check_unlink`): mov x0,#0 [_hook_vnode_check_unlink] | `7f2303d5 -> 000080d2`
- `0xFFFFFE00093B5104` (`_hook_vnode_check_unlink`): ret [_hook_vnode_check_unlink] | `e923ba6d -> c0035fd6`
- `0xFFFFFE00093B53D8` (`_hook_vnode_check_unlink`): mov x0,#0 [_hook_vnode_check_truncate] | `7f2303d5 -> 000080d2`
- `0xFFFFFE00093B53DC` (`_hook_vnode_check_unlink`): ret [_hook_vnode_check_truncate] | `fc6fbea9 -> c0035fd6`
- Artifacts: `research/kernel_jailbreak_patches/runtime_verification/runtime_verification_report.json`
- Artifacts: `research/kernel_jailbreak_patches/runtime_verification/ida_runtime_patch_points.json`
- Artifacts: `research/kernel_jailbreak_patches/runtime_verification/ida_patch_chain_report.json`
- Artifacts: `Research/KernelJailbreakPatches/RuntimeVerification/ida_patch_chain_report.md`
<!-- END_RUNTIME_IDA_VERIFICATION_2026_03_05 -->

## 2026-03-06 Upstream Rework Review

- This patch was materially reworked in this pass to match `/Users/qaq/Desktop/patch_fw.py`: it now rewrites the `mac_policy_ops` entries directly instead of patching each hook body.
- Runtime reveal is still string-backed (`"Sandbox"` + `"Seatbelt sandbox policy"` -> `mac_policy_conf` -> `mpc_ops`), but the final writes now land on the table entries themselves, matching upstream semantics and offsets.
- The shared allow target is recovered structurally from Sandbox text as the higher-address `mov x0,#0 ; ret` stub (`0x023B73BC` research, `0x022A78BC` release), matching the stub used by upstream `patch_fw.py`.
- Focused dry-run (`2026-03-06`): research now emits 36 `ops[idx] -> allow stub` writes at the upstream table-entry offsets (for example `0x00A54C30`, `0x00A54C50`, `0x00A54CE0`, `0x00A54E68`); release emits the analogous table-entry writes (`0x00A1C0B0`, `0x00A1C0D0`, `0x00A1C160`, `0x00A1C2E8`).
- This supersedes the earlier repo-local body-stub strategy for A4.
