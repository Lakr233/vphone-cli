# A1 `patch_amfi_cdhash_in_trustcache`

## 1) Scope and Re-validation Method

- Prior notes were treated as untrusted.
- All conclusions below were rebuilt with static analysis from IDA MCP on:
  - kernel image: `vm/iPhone17,3_26.1_23B85_Restore/kernelcache.research.vphone600`
  - IDA DB: `/Users/qaq/Desktop/kernelcache.research.vphone600.macho`

## 2) Exact Patchpoint and Semantics

- Patcher source: `scripts/patchers/kernel_jb_patch_amfi_trustcache.py`.
- Unique semantic match resolves to:
  - `0xfffffe0008637880` -> `jb_a1_patched_amfi_is_cdhash_in_trustcache`
- Original function behavior (before patch):
  - forwards request to `jb_a1_supp_txm_sel14_query_cdhash_trustcache` (`0xfffffe0007FFCA08`)
  - returns boolean success (`v4 == 0`)
  - optionally writes result metadata through out pointer.
- Patched entry stub (4 instructions):
  1. `mov x0, #1`
  2. `cbz x2, +8`
  3. `str x0, [x2]`
  4. `ret`
- Net effect: trustcache membership query is forced to "present" for every caller.

## 3) Full Call Trace (Static)

### 3.1 Downstream (what is bypassed)

- `jb_a1_patched_amfi_is_cdhash_in_trustcache` (`0x8637880`)
  -> `jb_a1_supp_txm_sel14_query_cdhash_trustcache` (`0x7FFCA08`)
  -> `sub_FFFFFE0007FFE5CC` (`TXM selector 14 path`).
- After patch, this TXM trustcache check path is no longer reached from A1 callers.

### 3.2 Upstream into AMFI policy

- Kernel MAC dispatch:
  - `jb_a1_supp_mac_vnode_check_signature` (`0x82DC0E0`, policy_ops+`0x980` dispatch)
  - callback pointer registered by `jb_a1_supp_amfi_register_mac_policy` (`0x8640718`, store at `0x8640ac8`).
- AMFI callback:
  - `jb_b5_supp_vnode_check_signature` (`0x8641924`)
  - trustcache gate at `0x8641de4` calls `jb_a1_supp_check_cdhash_any_trustcache_type` (`0x863F9FC`)
  - helper calls `jb_a1_patched_amfi_is_cdhash_in_trustcache` with classes 1/2/3.
- Main image validation path into MAC gate:
  - `jb_a1_supp_mach_loader_process_signature` (`0x805620C`, `mach_loader.c` reference)
    -> `jb_a1_supp_cs_blob_validate_image` (`0x8022130`)
    -> `jb_a1_supp_mac_vnode_check_signature` (`0x82DC0E0`).
- Exec activation path also re-enters this checker:
  - `jb_b16_supp_exec_activate_image` (`0x7FAD47C`)
    -> `jb_a1_supp_exec_handle_signature_enforcement` (`0x7FAC6FC`)
    -> call at `0x7FACFAC` into `jb_a1_supp_mach_loader_process_signature`.

## 4) Why This Is Required for "Unsigned" Binary Execution

- Important distinction from static flow:
  - **Completely unsigned** (no code signature blob) is still killed earlier by `jb_a1_supp_execve_cred_label_update` (`0x863FC6C`) with log path at `0x863fcfc`; A1 does not bypass that.
  - Practical jailbreak case is **ad-hoc/re-signed non-Apple** code: has CDHash, but not in Apple trustcache.
- For that practical case, A1 is decisive because:
  - `jb_b5_supp_vnode_check_signature` trust path depends on `jb_a1_supp_check_cdhash_any_trustcache_type`.
  - Without A1, non-trustcached CDHash falls into non-trusted paths and may end in denial/untrusted handling.
  - With A1, trust path is forced (`0x8641df8` sets `csflags |= 0x04000000`; optional `0x2200` at `0x8641e18`), enabling the in-kernel trust-cache acceptance path.

## 5) Why It Matters for launchd dylib Work

- Same signature gate is reused in exec image activation and subsequent image signature handling (call at `0x7FACFAC` -> `jb_a1_supp_mach_loader_process_signature` -> MAC vnode signature callback chain).
- Therefore, a launchd-related injected/re-signed dylib that is not in trustcache hits the same CDHash trustcache gate.
- A1 forces this gate open, so launchd-associated non-Apple dylib image checks can proceed through the trusted branch instead of failing trustcache membership checks.
- Inference (from static flow + shared gate usage): this is why A1 is a prerequisite for reliable launchd dylib workflows in this JB chain.

## 6) IDA Naming Work (Requested Two Groups)

### 6.1 Patched-function group

- `0xfffffe0008637880` -> `jb_a1_patched_amfi_is_cdhash_in_trustcache`
- Patchpoint comment added at function entry:
  - `[PATCHED GROUP] A1 patchpoint: force trustcache success...`

### 6.2 Supplement group

- `0xfffffe000863F9FC` -> `jb_a1_supp_check_cdhash_any_trustcache_type`
- `0xfffffe000863F984` -> `jb_a1_supp_check_cdhash_primary_or_fallback`
- `0xfffffe000863FC6C` -> `jb_a1_supp_execve_cred_label_update`
- `0xfffffe00082DC0E0` -> `jb_a1_supp_mac_vnode_check_signature`
- `0xfffffe0008022130` -> `jb_a1_supp_cs_blob_validate_image`
- `0xfffffe000805620C` -> `jb_a1_supp_mach_loader_process_signature`
- `0xfffffe0007FAC6FC` -> `jb_a1_supp_exec_handle_signature_enforcement`
- `0xfffffe0007FFCA08` -> `jb_a1_supp_txm_sel14_query_cdhash_trustcache`
- `0xfffffe0007FFCAAC` -> `jb_a1_supp_txm_sel15_query_cdhash_restriction`
- `0xfffffe0008640718` -> `jb_a1_supp_amfi_register_mac_policy`
- `0xfffffe00086346D0` -> `jb_a1_supp_restricted_exec_mode_cdhash_gate`
- Supplement comments added at key trace points (`0x8641de4`, `0x8641df8`, `0x8641e0c`, `0x82dc374`, `0x8640ac8`, `0x863fef4`, `0x7facfac`).

## 7) Risk / Side Effects

- This is a global trust decision bypass for CDHash membership.
- Any policy branch depending on "not in trustcache" no longer behaves normally.
- Security impact is high by design: trustcache origin distinction is removed for this path.

## Symbol Consistency Audit (2026-03-05)

- Status: `partial`
- `kernel_symbols` contains AMFI/trustcache symbols, but not all analysis labels used in this doc.
- This doc uses analyst labels (`jb_*`) for readability; those labels should be treated as local reverse-engineering aliases unless explicitly present in recovered symbol JSON.

## Patch Metadata

- Patch document: `patch_amfi_cdhash_in_trustcache.md` (A1).
- Primary patcher module: `scripts/patchers/kernel_jb_patch_amfi_trustcache.py`.
- Analysis mode: static binary analysis (IDA-MCP + disassembly + recovered symbols), no runtime patch execution.

## Patch Goal

Force AMFI trustcache membership checks to succeed so non-Apple CDHashes can pass downstream signature policy lanes.

## Target Function(s) and Binary Location

- Primary target: `AMFIIsCDHashInTrustCache` replacement body at `0xfffffe0008637880` (analyst label `jb_a1_patched_amfi_is_cdhash_in_trustcache`).
- Patchpoint: function entry stub (`mov x0,#1; cbz x2,...; str x0,[x2]; ret`).

## Kernel Source File Location

- Component: AppleMobileFileIntegrity logic in the kernel collection (private; not fully available in open-source XNU).
- Related open-source call-path reference: `bsd/kern/mach_loader.c` (`load_machfile`/exec signature flow).
- Confidence: `medium`.

## Function Call Stack

- Primary traced chain (from `3) Full Call Trace (Static)`):
- `jb_a1_patched_amfi_is_cdhash_in_trustcache` (`0x8637880`)
- > `jb_a1_supp_txm_sel14_query_cdhash_trustcache` (`0x7FFCA08`)
- > `sub_FFFFFE0007FFE5CC` (`TXM selector 14 path`).
- After patch, this TXM trustcache check path is no longer reached from A1 callers.
- Kernel MAC dispatch:
- The upstream entry(s) and patched decision node are linked by direct xref/callsite evidence in this file.

## Patch Hit Points

- Key patchpoint evidence (from `2) Exact Patchpoint and Semantics`):
- `0xfffffe0008637880` -> `jb_a1_patched_amfi_is_cdhash_in_trustcache`
- Original function behavior (before patch):
- forwards request to `jb_a1_supp_txm_sel14_query_cdhash_trustcache` (`0xfffffe0007FFCA08`)
- The before/after instruction transform is constrained to this validated site.

## Current Patch Search Logic

- Implemented in `scripts/patchers/kernel_jb_patch_amfi_trustcache.py`.
- Site resolution uses anchor + opcode-shape + control-flow context; ambiguous candidates are rejected.
- The patch is applied only after a unique candidate is confirmed in-function.
- Uses string anchors + instruction-pattern constraints + structural filters (for example callsite shape, branch form, register/imm checks).

## Pseudocode (Before)

```c
int ok = txm_query_cdhash(hash, type, out_meta);
return ok == 0;
```

## Pseudocode (After)

```c
if (out_meta) *out_meta = 1;
return 1;
```

## Validation (Static Evidence)

- Verified with IDA-MCP disassembly/decompilation, xrefs, and callgraph context for the selected site.
- Cross-checked against recovered symbols in `research/kernel_symbols/json/kernelcache.research.vphone600.bin.symbols.json`.
- Address-level evidence in this document is consistent with patcher matcher intent.

## Expected Failure/Panic if Unpatched

- Non-trustcached CDHash flows fall back to deny/untrusted branches in AMFI vnode-signature handling; launch-critical binaries/dylibs can be rejected.

## Risk / Side Effects

- This patch weakens a kernel policy gate by design and can broaden behavior beyond stock security assumptions.
- Potential side effects include reduced diagnostics fidelity and wider privileged surface for patched workflows.

## Symbol Consistency Check

- Recovered-symbol status in `kernelcache.research.vphone600.bin.symbols.json`: `partial`.
- Canonical symbol hit(s): none (alias-based static matching used).
- Where canonical names are absent, this document relies on address-level control-flow and instruction evidence; analyst aliases are explicitly marked as aliases.
- IDA-MCP lookup snapshot (2026-03-05): analyzed body at `0xfffffe0008637880` is currently named `_ACMKernGlobalContextVerifyPolicyAndCopyRequirementEx__FFFFFE0008637840` in IDA, so function semantics are validated by control-flow/patch bytes rather than symbol text.

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
- Runtime status: `hit` (4 patch writes, method_return=True)
- Included in `KernelJBPatcher.find_all()`: `True`
- IDA mapping: `4/4` points in recognized functions; `0` points are code-cave/data-table writes.
- IDA mapping status: `ok` (IDA runtime mapping loaded.)
- Call-chain mapping status: `ok` (IDA call-chain report loaded.)
- Call-chain validation: `1` function nodes, `4` patch-point VAs.
- IDA function sample: `sub_FFFFFE0008645B10`
- Chain function sample: `sub_FFFFFE0008645B10`
- Caller sample: `__Z14tokenIsTrusted13audit_token_t`, `__Z29isConstraintCategoryEnforcing20ConstraintCategory_t`, `__ZL15_policy_syscallP4prociy__FFFFFE00086514F8`, `__ZL22_vnode_check_signatureP5vnodeP5labeliP7cs_blobPjS5_ijPPcPm`, `__ZN24AppleMobileFileIntegrity27submitAuxiliaryInfoAnalyticEP5vnodeP7cs_blob`, `sub_FFFFFE000864DC14`
- Callee sample: `sub_FFFFFE0008006344`, `sub_FFFFFE0008645B10`, `sub_FFFFFE0008659D48`
- Verdict: `valid`
- Recommendation: Keep enabled for this kernel build; continue monitoring for pattern drift.
- Key verified points:
- `0xFFFFFE0008645B10` (`sub_FFFFFE0008645B10`): mov x0,#1 [AMFIIsCDHashInTrustCache] | `7f2303d5 -> 200080d2`
- `0xFFFFFE0008645B14` (`sub_FFFFFE0008645B10`): cbz x2,+8 [AMFIIsCDHashInTrustCache] | `ffc300d1 -> 420000b4`
- `0xFFFFFE0008645B18` (`sub_FFFFFE0008645B10`): str x0,[x2] [AMFIIsCDHashInTrustCache] | `f44f01a9 -> 400000f9`
- `0xFFFFFE0008645B1C` (`sub_FFFFFE0008645B10`): ret [AMFIIsCDHashInTrustCache] | `fd7b02a9 -> c0035fd6`
- Artifacts: `research/kernel_jailbreak_patches/runtime_verification/runtime_verification_report.json`
- Artifacts: `research/kernel_jailbreak_patches/runtime_verification/ida_runtime_patch_points.json`
- Artifacts: `research/kernel_jailbreak_patches/runtime_verification/ida_patch_chain_report.json`
- Artifacts: `research/kernel_jailbreak_patches/runtime_verification/ida_patch_chain_report.md`
<!-- END_RUNTIME_IDA_VERIFICATION_2026_03_05 -->

## 2026-03-06 Upstream Rework Review

- `patch_fw.py` target remains authoritative here: research rewrites the function entry at `0x01633880` (`mov x0,#1 ; cbz x2,+8 ; str x0,[x2] ; ret`), and release lands at `0x015AE160`.
- IDA on `kernelcache.research.vphone600` confirms that `0xFFFFFE0008637880` is the entry of the tiny AMFI trustcache helper and that the first 12 bytes match the upstream patch body exactly.
- Runtime matcher stays structural instead of string-anchored because this helper does not expose a stable in-function string anchor on the stripped raw kernel. The retained reveal uses a tight in-function instruction shape inside `AppleMobileFileIntegrity::__text`, and focused dry-runs on both PCC 26.1 research/release remain unique.
- Focused dry-run (`2026-03-06`): research hits `0x01633880/84/88/8C`; release hits `0x015AE160/64/68/6C`.
