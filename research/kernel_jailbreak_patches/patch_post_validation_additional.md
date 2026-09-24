# B5 `patch_post_validation_additional` (re-derived with static analysis)

## 1) Scope and result

- This patch is not a generic "postValidation nop"; it removes a specific SHA256-only reject gate inside AMFI's vnode signature callback flow.
- Why it matters: without this bypass, AMFI can reject otherwise-accepted code objects when hash type is not `2` (SHA256), which breaks unsigned/re-signed execution paths and dynamic loader paths used by launchd-loaded dylibs.

## 2) Re-validated artifacts

- IDA target DB: `/Users/qaq/Desktop/kernelcache.research.vphone600.macho` (already contains patched bytes at the B5 site).
- Raw unpatched cross-check (same firmware family, static patcher run): `vm/iPhone17,3_26.1_23B85_Restore/kernelcache.release.vphone600`
  - unique B5 hit found by patcher:
    - VA `0xfffffe00085bee8c`
    - original `0x7100081f` (`cmp w0, #2`)
    - patched `0x6b00001f` (`cmp w0, w0`)
- Patcher logic confirmed in `scripts/patchers/kernel_jb_patch_post_validation.py`:
  - anchor: `"AMFI: code signature validation failed"`
  - resolve caller, walk BL callees, patch `cmp w0,#imm` + `b.ne` pattern near prior BL.

## 3) IDA call trace (full picture)

- `jb_b5_supp_amfi_policy_init` at `0xfffffe0008640718` installs AMFI policy ops and writes callback pointer:
  - `0xfffffe0008640ac8`: store callback into `jb_b5_supp_ops_vnode_check_signature_ptr` (`0xfffffe0007851e40`).
  - `0xfffffe0008640c48`: register policy via `sub_FFFFFE00082CDDB0` (registration function).
- Registered callback is `jb_b5_supp_vnode_check_signature` at `0xfffffe0008641924`.
- This callback calls `jb_b5_patched_oop_jit_hash_gate` (`0xfffffe0008644564`) from 3 validation lanes:
  - trust-cache lane: `0xfffffe0008641e78`
  - can-execute-cdhash lane: `0xfffffe00086421b8`
  - dynamic/amfid lane: `0xfffffe00086428e4`

## 4) The exact reject gate that B5 neutralizes

- In `jb_b5_patched_oop_jit_hash_gate`:
  - `0xfffffe00086445a0`: `tbz w2,#0x1a,...` (gate only when bit 26 is set in flags argument)
  - `0xfffffe00086445a8`: `bl jb_b5_supp_get_cdhash_type`
  - `0xfffffe00086445ac`: **patch point** (`jb_b5_patchpt_cmp_hash_type`)
    - original logic: `cmp w0,#2`
    - patched logic: `cmp w0,w0`
  - `0xfffffe00086445b0`: `b.ne jb_b5_patchpt_hash_type_reject`
- Reject branch (`0xfffffe000864466c`) logs:
  - `"%s: Hash type is not SHA256 (%u) but %u"`
  - then returns `0` (failure path).

## 5) Why this blocks unsigned binaries and launchd dylib flow

- In `jb_b5_supp_vnode_check_signature`, trust-cache success sets bit 26 before calling this gate:
  - `0xfffffe0008641df8`: `orr w8,w8,#0x4000000`
- After each gate call, return value is inverted into failure state:
  - `v27 = gate_ret ^ 1` (decompiler view in all 3 lanes).
  - failure path emits `"AMFI: code signature validation failed.\n"` and marks image untrusted.
- Therefore, unpatched behavior is:
  - non-SHA256 hash type + bit26-set context -> forced reject.
- Why this hits jailbreak userland:
  - unsigned/re-signed binaries and injected dylibs depend on trustcache/dynamic AMFI acceptance lanes;
  - this extra SHA256-only gate can still kill them after earlier acceptance.
  - the same gate is reached from the dynamic lane, so launchd-loaded dylib validation can be blocked there as well.

## 6) IDA labels added (requested grouping)

- `supplement` group:
  - `0xfffffe0008640718` -> `jb_b5_supp_amfi_policy_init`
  - `0xfffffe0008641924` -> `jb_b5_supp_vnode_check_signature`
  - `0xfffffe0007f828f4` -> `jb_b5_supp_get_cdhash_type`
  - `0xfffffe0007851e40` -> `jb_b5_supp_ops_vnode_check_signature_ptr`
  - `0xfffffe0008638190` -> `jb_b5_supp_slot_hash_size_from_type`
  - `0xfffffe00071fe1a0` -> `jb_b5_supp_hash_type_size_table`
- `patched function` group:
  - `0xfffffe0008644564` -> `jb_b5_patched_oop_jit_hash_gate`
  - `0xfffffe00086445ac` -> `jb_b5_patchpt_cmp_hash_type`
  - `0xfffffe000864466c` -> `jb_b5_patchpt_hash_type_reject`

## 7) Net effect and risk

- Effect: B5 specifically disables the SHA256-type reject edge while keeping surrounding OOP-JIT entitlement checks in place.
- Risk: hash-type strictness in this lane is removed, so non-SHA256 code objects can pass this post-acceptance gate.
- Assessment: patch is required in this JB flow because it removes a late AMFI reject condition that otherwise defeats unsigned/re-signed binary and dynamic dylib execution paths.

## Symbol Consistency Audit (2026-03-05)

- Status: `partial`
- AMFI-related symbols are only partially recovered for this call chain.
- Patch-point semantics in this doc are primarily instruction/path validated, not fully symbol-resolved.

## Patch Metadata

- Patch document: `patch_post_validation_additional.md` (B5).
- Primary patcher module: `scripts/patchers/kernel_jb_patch_post_validation.py`.
- Analysis mode: static binary analysis (IDA-MCP + disassembly + recovered symbols), no runtime patch execution.

## Patch Goal

Neutralize AMFI's SHA256-only post-validation reject gate in vnode signature processing.

## Target Function(s) and Binary Location

- Primary target: AMFI hash-type gate helper at `0xfffffe0008644564`.
- Patchpoint: `0xfffffe00086445ac` (`cmp w0,#2` -> `cmp w0,w0`).

## Kernel Source File Location

- Component: AMFI vnode-signature validation helper in kernel collection (private).
- Related open-source entry context: `bsd/kern/mach_loader.c` + MAC vnode checks.
- Confidence: `medium`.

## Function Call Stack

- Primary traced chain (from `3) IDA call trace (full picture)`):
- `jb_b5_supp_amfi_policy_init` at `0xfffffe0008640718` installs AMFI policy ops and writes callback pointer:
- `0xfffffe0008640ac8`: store callback into `jb_b5_supp_ops_vnode_check_signature_ptr` (`0xfffffe0007851e40`).
- `0xfffffe0008640c48`: register policy via `sub_FFFFFE00082CDDB0` (registration function).
- Registered callback is `jb_b5_supp_vnode_check_signature` at `0xfffffe0008641924`.
- This callback calls `jb_b5_patched_oop_jit_hash_gate` (`0xfffffe0008644564`) from 3 validation lanes:
- The upstream entry(s) and patched decision node are linked by direct xref/callsite evidence in this file.

## Patch Hit Points

- Patch hitpoint is selected by contextual matcher and verified against local control-flow.
- Before/after instruction semantics are captured in the patch-site evidence above.

## Current Patch Search Logic

- Implemented in `scripts/patchers/kernel_jb_patch_post_validation.py`.
- Site resolution uses anchor + opcode-shape + control-flow context; ambiguous candidates are rejected.
- The patch is applied only after a unique candidate is confirmed in-function.
- anchor: `"AMFI: code signature validation failed"`
- Uses string anchors + instruction-pattern constraints + structural filters (for example callsite shape, branch form, register/imm checks).

## Pseudocode (Before)

```c
hash_type = get_cdhash_type(...);
if (hash_type != 2) {
    return 0;
}
```

## Pseudocode (After)

```c
hash_type = get_cdhash_type(...);
if (hash_type != hash_type) {
    return 0;
}
```

## Validation (Static Evidence)

- Verified with IDA-MCP disassembly/decompilation, xrefs, and callgraph context for the selected site.
- Cross-checked against recovered symbols in `research/kernel_symbols/json/kernelcache.research.vphone600.bin.symbols.json`.
- Address-level evidence in this document is consistent with patcher matcher intent.

## Expected Failure/Panic if Unpatched

- AMFI hash-type gate can reject non-SHA256 cases after earlier acceptance, producing late signature-validation failures.

## Risk / Side Effects

- This patch weakens a kernel policy gate by design and can broaden behavior beyond stock security assumptions.
- Potential side effects include reduced diagnostics fidelity and wider privileged surface for patched workflows.

## Symbol Consistency Check

- Recovered-symbol status in `kernelcache.research.vphone600.bin.symbols.json`: `partial`.
- Canonical symbol hit(s): none (alias-based static matching used).
- Where canonical names are absent, this document relies on address-level control-flow and instruction evidence; analyst aliases are explicitly marked as aliases.
- IDA-MCP lookup snapshot (2026-03-05): `0xfffffe00085bee8c` currently resolves to `sub_FFFFFE00085BECD8` (size `0x470`).

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
- IDA function sample: `sub_FFFFFE00086406F0`
- Chain function sample: `sub_FFFFFE00086406F0`
- Caller sample: none
- Callee sample: `sub_FFFFFE0007C2A218`, `sub_FFFFFE0007F8C72C`, `sub_FFFFFE0007F8C800`, `sub_FFFFFE00086406F0`
- Verdict: `valid`
- Recommendation: Keep enabled for this kernel build; continue monitoring for pattern drift.
- Policy note: method is in the low-risk optimized set (validated hit on this kernel).
- Key verified points:
- `0xFFFFFE0008640760` (`sub_FFFFFE00086406F0`): cmp w0,w0 [postValidation additional fallback] | `1f000071 -> 1f00006b`
- Artifacts: `research/kernel_jailbreak_patches/runtime_verification/runtime_verification_report.json`
- Artifacts: `research/kernel_jailbreak_patches/runtime_verification/ida_runtime_patch_points.json`
- Artifacts: `research/kernel_jailbreak_patches/runtime_verification/ida_patch_chain_report.json`
- Artifacts: `research/kernel_jailbreak_patches/runtime_verification/ida_patch_chain_report.md`
<!-- END_RUNTIME_IDA_VERIFICATION_2026_03_05 -->

## 2026-03-06 Upstream Rework Review

- `patch_fw.py` patches the SHA256-only reject compare at `0x016405AC`; release lands at `0x015BAE8C`. The current matcher still lands on exactly those sites.
- In this pass the runtime reveal was tightened to a single string-backed path: `"AMFI: code signature validation failed"` -> caller -> BL target -> unique `cmp w0,#imm ; b.ne` reject gate.
- The old broad fallback (`first cmp w0,#imm in AMFI text`) was removed because it was not a justified cross-build matcher under the current rules.
- Focused dry-run (`2026-03-06`): research `0x016405AC`; release `0x015BAE8C`.
