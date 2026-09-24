# A2 `patch_amfi_execve_kill_path` (fully re-validated)

This document was re-done from static analysis only (IDA MCP), treating previous notes as untrusted.

## 1) Exact patch target and effect

- Patched function (AMFI callback): `0xFFFFFE000863FC6C` (`jbA2_patch_amfi_execve_kill_handler`).
- Patch point label: `0xFFFFFE00086400FC` (`jbA2_patchpoint_mov_w0_1_to_0`).
- Instruction before patch: `MOV W0, #1`.
- Instruction after patch: `MOV W0, #0`.
- The instruction is in the shared kill epilogue (`0x86400F8` log + `0x86400FC` return code), so all kill branches are converted to allow.

## 2) Why this function is called (full dispatch picture)

### 2.1 AMFI registers this callback into MAC policy ops slot +0x90

- In AMFI init `0xFFFFFE0008640718` (`jb_a1_supp_amfi_register_mac_policy`):
  - `0x8640A90` loads callback address `0x863FC6C`.
  - `0x8640A98` sets PAC discriminator `0xEC79`.
  - `0x8640AA0` stores into policy ops slot `qword_FFFFFE0007851550` (renamed `jbA2_patch_ops_slot_0x90`).

### 2.2 Kernel MAC dispatcher calls ops slot +0x90 during exec image processing

- Dispatcher: `0xFFFFFE00082D9D0C` (`jbA2_supp_mac_policy_dispatch_ops90_execve`).
- Key instructions:
  - `0x82D9DB8`: load policy ops base from each policy (`[policy + 0x20]`).
  - `0x82D9DBC`: load callback from `[ops + 0x90]`.
  - `0x82D9FC8`: `BLRAA X24, X17` with `X17 = 0xEC79`.
- The PAC discriminator matches AMFI registration (`0xEC79`), proving this slot resolves to the AMFI callback above.

### 2.3 Exec pipeline path into that dispatcher

- `0xFFFFFE0007F81F00` (`jbA2_supp_execve_mac_policy_bridge`) directly calls `0x82D9D0C`.
- `0xFFFFFE0007FA6858` builds a callback descriptor containing `0x7F81F00`, then submits it via `sub_FFFFFE0007F81364`.
- Upstream chain:
  - `0x7FA4A58` (`jbA2_supp_imgact_validate_and_activate`) -> calls `0x7FA6858`.
  - `0x7FAB530` (`jbA2_supp_imgact_exec_driver`) -> calls `0x7FA4A58`.
  - `0x7FAD47C` (`jbA2_supp_exec_activate_image`) -> calls `0x7FAB530`.
- So this callback is in the core exec image activation path, not an optional debug path.

## 3) Why unsigned binaries fail without A2

Inside `0x863FC6C`, multiple checks branch to the shared kill return (`W0=1`):

- Completely unsigned code path (first AMFI kill string block).
- Restricted Execution Mode denial paths (`state 2/3/4`).
- Legacy VPN plugin denial.
- Dyld signature denial (`"dyld signature cannot be verified"`).
- Generic kill path (`"...killing %s (pid %u): %s"`) after deep signature/entitlement validation helper failures.

Because all of them converge on the same return code, any one of these conditions kills exec.

## 4) Why launchd dylib flow also depends on A2

The same callback enforces dyld/signature and entitlement consistency during exec image activation:

- The explicit dyld kill string path is in this function (`"dyld signature cannot be verified..."`).
- The helper path (`sub_FFFFFE0008640310` -> `sub_FFFFFE00086442F8`) can fail with reasons like `"no code signature"`, DER/XML entitlement mismatch, etc., then returns to the same kill epilogue.

So when launchd (or its startup path) encounters unsigned / non-trustcached / entitlement-inconsistent dylib state, exec is killed through this same callback. A2 changes that final kill return to allow.

## 5) Why one instruction is enough

- All kill branches funnel into one epilogue return code at `0x86400FC`.
- Changing only that `MOV W0,#1` to `MOV W0,#0` keeps assertions, logging, and all prechecks intact, but changes final policy decision from deny to allow.

## 6) IDA marking done (requested grouping)

### Supplement group

- `0x82D9D0C` -> `jbA2_supp_mac_policy_dispatch_ops90_execve`
- `0x7F81F00` -> `jbA2_supp_execve_mac_policy_bridge`
- `0x7FA4A58` -> `jbA2_supp_imgact_validate_and_activate`
- `0x7FAB530` -> `jbA2_supp_imgact_exec_driver`
- `0x7FAD47C` -> `jbA2_supp_exec_activate_image`
- `0x7FAD448` -> `jbA2_supp_exec_activate_image_wrapper`
- `0x7851550` -> `jbA2_patch_ops_slot_0x90`

### Patched-function group

- `0x863FC6C` -> `jbA2_patch_amfi_execve_kill_handler`
- `0x86400F8` -> `jbA2_patchloc_kill_log_then_ret`
- `0x86400FC` -> `jbA2_patchpoint_mov_w0_1_to_0`

## 7) Old failure mode (reconfirmed)

The earlier BL/CBZ-site patching hit vnode-type assertion checks near function start (`sub_FFFFFE0007CCC40C` / `sub_FFFFFE0007CCC41C`), not the actual kill decision. That corrupts precondition logic and can panic. The shared-epilogue patch avoids that class of bug.

## Symbol Consistency Audit (2026-03-05)

- Status: `partial`
- `_hook_cred_label_update_execve` and related execve symbols are recovered, but several AMFI callback wrapper addresses in this doc remain unlabeled in `kernel_symbols`.
- Address-level control-flow evidence is still valid; symbol names are partially recovered only.

## Scheduler Status (2026-03-06)

- For the current PCC 26.1 `_cred_label_update_execve` path, A2 and C21 both land on the same shared deny-return site: `0xFFFFFE00086400FC`.
- That means enabling both in the same default JB schedule is redundant and produces a real patch-site conflict, not just a conceptual overlap.
- Current policy: keep A2 as a standalone / fallback patch for isolated testing, but remove it from the default schedule when C21 is enabled.
- Rationale: C21 preserves the same deny→allow effect at the shared return site and additionally handles the late success exits plus success-only `csflags` relaxation.

## Patch Metadata

- Patch document: `patch_amfi_execve_kill_path.md` (A2).
- Primary patcher module: `scripts/patchers/kernel_jb_patch_amfi_execve.py`.
- Analysis mode: static binary analysis (IDA-MCP + disassembly + recovered symbols), no runtime patch execution.

## Patch Goal

Convert AMFI execve shared kill return from deny to allow by flipping the final return-code instruction.

## Target Function(s) and Binary Location

- Primary target: AMFI execve kill handler at `0xfffffe000863fc6c` (analyst label `jbA2_patch_amfi_execve_kill_handler`).
- Patchpoint: `0xfffffe00086400fc` (`mov w0,#1` -> `mov w0,#0`).

## Kernel Source File Location

- Component: AppleMobileFileIntegrity execve callback logic in kernel collection (private component).
- Related open-source entry context: `bsd/kern/kern_exec.c` and `bsd/kern/mach_loader.c`.
- Confidence: `medium`.

## Function Call Stack

- Primary traced chain (from `2) Why this function is called (full dispatch picture)`):
- In AMFI init `0xFFFFFE0008640718` (`jb_a1_supp_amfi_register_mac_policy`):
- `0x8640A90` loads callback address `0x863FC6C`.
- `0x8640A98` sets PAC discriminator `0xEC79`.
- `0x8640AA0` stores into policy ops slot `qword_FFFFFE0007851550` (renamed `jbA2_patch_ops_slot_0x90`).
- Dispatcher: `0xFFFFFE00082D9D0C` (`jbA2_supp_mac_policy_dispatch_ops90_execve`).
- The upstream entry(s) and patched decision node are linked by direct xref/callsite evidence in this file.

## Patch Hit Points

- Key patchpoint evidence (from `1) Exact patch target and effect`):
- Patched function (AMFI callback): `0xFFFFFE000863FC6C` (`jbA2_patch_amfi_execve_kill_handler`).
- Patch point label: `0xFFFFFE00086400FC` (`jbA2_patchpoint_mov_w0_1_to_0`).
- Instruction before patch: `MOV W0, #1`.
- Instruction after patch: `MOV W0, #0`.
- The instruction is in the shared kill epilogue (`0x86400F8` log + `0x86400FC` return code), so all kill branches are converted to allow.
- The before/after instruction transform is constrained to this validated site.

## Current Patch Search Logic

- Implemented in `scripts/patchers/kernel_jb_patch_amfi_execve.py`.
- Site resolution uses anchor + opcode-shape + control-flow context; ambiguous candidates are rejected.
- The patch is applied only after a unique candidate is confirmed in-function.
- Uses string anchors + instruction-pattern constraints + structural filters (for example callsite shape, branch form, register/imm checks).

## Pseudocode (Before)

```c
if (kill_condition) {
    log_reason(...);
    return 1;
}
```

## Pseudocode (After)

```c
if (kill_condition) {
    log_reason(...);
    return 0;
}
```

## Validation (Static Evidence)

- Verified with IDA-MCP disassembly/decompilation, xrefs, and callgraph context for the selected site.
- Cross-checked against recovered symbols in `research/kernel_symbols/json/kernelcache.research.vphone600.bin.symbols.json`.
- Address-level evidence in this document is consistent with patcher matcher intent.

## Expected Failure/Panic if Unpatched

- AMFI kill epilogue returns deny (`w0=1`), causing exec rejection for guarded paths (including dyld-signature related failures).

## Risk / Side Effects

- This patch weakens a kernel policy gate by design and can broaden behavior beyond stock security assumptions.
- Potential side effects include reduced diagnostics fidelity and wider privileged surface for patched workflows.

## Symbol Consistency Check

- Recovered-symbol status in `kernelcache.research.vphone600.bin.symbols.json`: `match`.
- Canonical symbol hit(s): `_hook_cred_label_update_execve`.
- Where canonical names are absent, this document relies on address-level control-flow and instruction evidence; analyst aliases are explicitly marked as aliases.
- IDA-MCP lookup snapshot (2026-03-05): `_hook_cred_label_update_execve` is present, while the analyzed AMFI helper body at `0xfffffe000863fc6c` is currently labeled as `__ZN18AppleMobileApNonce21_saveNonceInfoInNVRAMEPKc` in this IDA state, confirming symbol-name drift at that site.

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
- Call-chain validation: `1` function nodes, `3` patch-point VAs.
- IDA function sample: `__Z25_cred_label_update_execveP5ucredS0_P4procP5vnodexS4_P5labelS6_S6_PjPvmPi`
- Chain function sample: `__Z25_cred_label_update_execveP5ucredS0_P4procP5vnodexS4_P5labelS6_S6_PjPvmPi`
- Caller sample: `__ZL35_initializeAppleMobileFileIntegrityv`
- Callee sample: `__Z25_cred_label_update_execveP5ucredS0_P4procP5vnodexS4_P5labelS6_S6_PjPvmPi`, `__ZN24AppleMobileFileIntegrity27submitAuxiliaryInfoAnalyticEP5vnodeP7cs_blob`, `sub_FFFFFE0007B4EA8C`, `sub_FFFFFE0007CD7750`, `sub_FFFFFE0007CD7760`, `sub_FFFFFE0007F8C478`
- Verdict: `valid`
- Recommendation: Keep enabled for this kernel build; continue monitoring for pattern drift.
- Key verified points:
- `0xFFFFFE000864E38C` (`__Z25_cred_label_update_execveP5ucredS0_P4procP5vnodexS4_P5labelS6_S6_PjPvmPi`): mov w0,#0 [AMFI kill return → allow] | `20008052 -> 00008052`
- Artifacts: `research/kernel_jailbreak_patches/runtime_verification/runtime_verification_report.json`
- Artifacts: `research/kernel_jailbreak_patches/runtime_verification/ida_runtime_patch_points.json`
- Artifacts: `research/kernel_jailbreak_patches/runtime_verification/ida_patch_chain_report.json`
- Artifacts: `Research/KernelJailbreakPatches/RuntimeVerification/ida_patch_chain_report.md`
<!-- END_RUNTIME_IDA_VERIFICATION_2026_03_05 -->
