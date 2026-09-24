# B6 `patch_proc_security_policy` (re-validated)

## What was re-checked

- Re-done from static analysis in IDA MCP only (no trust in previous notes).
- Verified call graph, callers, argument flow, and failure mode for wrong target.
- Marked IDA names in two groups:
  - **patched function group**:
    - `0xFFFFFE0008067148` -> `jb_patched_proc_security_policy`
    - `0xFFFFFE000806714C` -> `jb_patchpoint_B6_ret0_step2`
  - **supplement group**:
    - `0xFFFFFE0008064034` -> `jb_supp_proc_info_syscall_entry_args`
    - `0xFFFFFE0008064078` -> `jb_supp_proc_info_syscall_mux`
    - `0xFFFFFE0008064A30` -> `jb_supp_proc_info_core_switch`
    - `0xFFFFFE0008065540` -> `jb_supp_proc_listpids_handler`
    - `0xFFFFFE0008065F6C` -> `jb_supp_proc_pidinfo_handler`
    - `0xFFFFFE0008066624` -> `jb_supp_proc_setcontrol_handler`
    - `0xFFFFFE0008066C9C` -> `jb_supp_proc_pidfdinfo_handler` (label in mux body)
    - `0xFFFFFE00082D5104` -> `jb_supp_mac_proc_check_proc_info`
    - `0xFFFFFE00082ED7B8` -> `jb_supp_priv_check_cred`
    - `0xFFFFFE00082EDA8C` -> `jb_supp_priv_check_cred_visible`
    - `0xFFFFFE0007C4DD48` -> `jb_supp_copyio_common_helper`

## Real patch target and bytes

- Target: `jb_patched_proc_security_policy` (`VA 0xFFFFFE0008067148`, file `0x1063148`, size `0x134`).
- Patch action: overwrite function entry with:
  - `mov x0, #0`
  - `ret`
- Effect: force this policy routine to return success immediately.

## Full static call trace (why this function is reached)

1. Syscall table data entry points to `jb_supp_proc_info_syscall_entry_args` (`xrefs @ 0xFFFFFE00077417D8`).
2. `jb_supp_proc_info_syscall_entry_args` forwards to `jb_supp_proc_info_syscall_mux`.
3. Mux dispatches to proc-info family handlers; those call `jb_patched_proc_security_policy` before serving data:
   - `jb_supp_proc_info_core_switch` callsites:
     - `0xFFFFFE0008064BD4`: args `(proc, 2, flavor, 0/1)`
     - `0xFFFFFE0008065098`: args `(proc, 3, 1, flag)`
   - `jb_supp_proc_listpids_handler` @ `0xFFFFFE0008065658`: `(proc, 3, list_flavor, 1)`
   - `jb_supp_proc_pidinfo_handler` @ `0xFFFFFE0008066248`: `(proc, 6, pidinfo_flavor, 1)`
   - `jb_supp_proc_setcontrol_handler` @ `0xFFFFFE0008066678`: `(proc, 9, selector, 1)`
   - mux-internal path @ `0xFFFFFE0008066CE4`: `(proc, 0xD, 0, 1)`
4. Non-zero return from `jb_patched_proc_security_policy` branches directly to error paths in these handlers.

## What `jb_patched_proc_security_policy` enforces (unpatched behavior)

Unpatched flow (from disasm/decompile):

1. Calls `jb_supp_mac_proc_check_proc_info(caller_cred, target_proc, policy_class, flavor)`.
   - If non-zero, returns that error.
2. If arg4/check flag is zero, returns success.
3. Otherwise compares caller and target identities (uid field compare).
4. If identities differ, enforces privilege gate with constant `0x3EA` (1002):
   - `jb_supp_priv_check_cred(caller_cred, 1002)`
   - and conditional `jb_supp_priv_check_cred_visible(caller_cred, 1002)` path.
5. Any failure returns denial to caller.

## Why this patch is required for unsigned binaries and launchd dylib workflow

Static facts:

- This function is the shared gate for `proc_info`/`proc_listpids`/`proc_pidinfo`/`proc_setcontrol` style paths.
- Those paths are widely used by libproc-driven process enumeration/introspection/control.
- Cross-identity queries require passing the 1002 privilege gate above.

Inference from those facts:

- Unsigned/non-platform processes (including early injected launchd hook context) are much more likely to fail this gate, especially on cross-uid targets.
- When that happens, proc-info-family syscalls return denial, which breaks process introspection/control flows needed by jailbreak userland and launchd hook behavior.
- Stubbing this function to return 0 removes that choke point and lets those flows proceed.

## Why previous wrong patch caused launchd exec failure

- Wrong target was `jb_supp_copyio_common_helper` (`VA 0xFFFFFE0007C4DD48`, file `0xC49D48`, size `0x28C`, **619 xrefs**).
- In `_proc_info` BL-count scan, copyio appears 4 times vs policy function 2 times.
- Patching copyio globally breaks copyin/copyout semantics across kernel paths.
- Static proof: launchd bootstrap path (`sub_FFFFFE0007FADC68`) directly uses `jb_supp_copyio_common_helper` while preparing `/sbin/launchd`, and contains log string:
  - `"Process 1 exec of %s failed, errno %d @%s:%d"`
- So the old false hit explains the observed launchd exec failure.

## Practical patcher implications

- Do not pick target by BL frequency alone inside `jb_supp_proc_info_core_switch`.
- Required disambiguation is validated:
  - same anchor (`sub wN,wM,#1; cmp wN,#0x21`)
  - count BLs after switch dispatch
  - size gate excludes copyio (`0x28C`) and keeps policy target (`0x134`)
  - optionally require xref set to proc-info-family handlers only.

## Symbol Consistency Audit (2026-03-05)

- Status: `partial`
- Direct recovered symbol `proc_security_policy` is not present in current `kernel_symbols` JSON.
- However, anchor-chain symbols `proc_info` (`0xfffffe000806d4dc`) and `proc_info_internal` (`0xfffffe000806d520`) are recovered and consistent with this document's call-path placement.
- Function labels in this doc remain analyst-derived for the inner policy helper layer.

## Patch Metadata

- Patch document: `patch_proc_security_policy.md` (B6).
- Primary patcher module: `scripts/patchers/kernel_jb_patch_proc_security.py`.
- Analysis mode: static binary analysis (IDA-MCP + disassembly + recovered symbols), no runtime patch execution.

## Patch Goal

Stub proc-security policy helper to success to avoid proc-info/proc-control authorization denials.

## Target Function(s) and Binary Location

- Primary target: policy helper at `0xfffffe0008067148` (analyst label `jb_patched_proc_security_policy`).
- Patchpoint: function entry overwritten with `mov x0,#0; ret`.

## Kernel Source File Location

- Expected XNU source family: `bsd/kern/proc_info.c` / proc-info authorization helpers.
- Confidence: `medium`.

## Function Call Stack

- Primary traced chain (from `Full static call trace (why this function is reached)`):
- 1. Syscall table data entry points to `jb_supp_proc_info_syscall_entry_args` (`xrefs @ 0xFFFFFE00077417D8`).
- 2. `jb_supp_proc_info_syscall_entry_args` forwards to `jb_supp_proc_info_syscall_mux`.
- 3. Mux dispatches to proc-info family handlers; those call `jb_patched_proc_security_policy` before serving data:
- `jb_supp_proc_info_core_switch` callsites:
- `0xFFFFFE0008064BD4`: args `(proc, 2, flavor, 0/1)`
- The upstream entry(s) and patched decision node are linked by direct xref/callsite evidence in this file.

## Patch Hit Points

- Key patchpoint evidence (from `Real patch target and bytes`):
- Target: `jb_patched_proc_security_policy` (`VA 0xFFFFFE0008067148`, file `0x1063148`, size `0x134`).
- The before/after instruction transform is constrained to this validated site.

## Current Patch Search Logic

- Implemented in `scripts/patchers/kernel_jb_patch_proc_security.py`.
- Site resolution uses anchor + opcode-shape + control-flow context; ambiguous candidates are rejected.
- The patch is applied only after a unique candidate is confirmed in-function.
- same anchor (`sub wN,wM,#1; cmp wN,#0x21`)
- However, anchor-chain symbols `proc_info` (`0xfffffe000806d4dc`) and `proc_info_internal` (`0xfffffe000806d520`) are recovered and consistent with this document's call-path placement.

## Pseudocode (Before)

```c
if (mac_proc_check_proc_info(...) != 0) return EPERM;
if (!cred_visible_or_privileged(..., 1002)) return EPERM;
return 0;
```

## Pseudocode (After)

```c
/* policy helper is stubbed */
int proc_security_policy(...) {
    return 0;
}
```

## Validation (Static Evidence)

- Verified with IDA-MCP disassembly/decompilation, xrefs, and callgraph context for the selected site.
- Cross-checked against recovered symbols in `research/kernel_symbols/json/kernelcache.research.vphone600.bin.symbols.json`.
- Address-level evidence in this document is consistent with patcher matcher intent.

## Expected Failure/Panic if Unpatched

- Proc-info/proc-control authorization stays enforced and returns denial for cross-identity operations required by tooling.

## Risk / Side Effects

- This patch weakens a kernel policy gate by design and can broaden behavior beyond stock security assumptions.
- Potential side effects include reduced diagnostics fidelity and wider privileged surface for patched workflows.

## Symbol Consistency Check

- Recovered-symbol status in `kernelcache.research.vphone600.bin.symbols.json`: `partial`.
- Canonical symbol hit(s): none (alias-based static matching used).
- Where canonical names are absent, this document relies on address-level control-flow and instruction evidence; analyst aliases are explicitly marked as aliases.
- IDA-MCP lookup snapshot (2026-03-05): `0xfffffe0008067148` currently resolves to `sub_FFFFFE0008067104` (size `0x130`).

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
- IDA function sample: `sub_FFFFFE00080705F0`
- Chain function sample: `sub_FFFFFE00080705F0`
- Caller sample: `proc_info_internal`, `sub_FFFFFE000806DED8`, `sub_FFFFFE000806E9E8`, `sub_FFFFFE000806F414`, `sub_FFFFFE000806FACC`
- Callee sample: `_enable_preemption_underflow`, `sub_FFFFFE0007B84334`, `sub_FFFFFE0007C64A3C`, `sub_FFFFFE0007FCA008`, `sub_FFFFFE00080705F0`, `sub_FFFFFE00082DD990`
- Verdict: `valid`
- Recommendation: Keep enabled for this kernel build; continue monitoring for pattern drift.
- Key verified points:
- `0xFFFFFE00080705F0` (`sub_FFFFFE00080705F0`): mov x0,#0 [_proc_security_policy] | `7f2303d5 -> 000080d2`
- `0xFFFFFE00080705F4` (`sub_FFFFFE00080705F0`): ret [_proc_security_policy] | `f85fbca9 -> c0035fd6`
- Artifacts: `research/kernel_jailbreak_patches/runtime_verification/runtime_verification_report.json`
- Artifacts: `research/kernel_jailbreak_patches/runtime_verification/ida_runtime_patch_points.json`
- Artifacts: `research/kernel_jailbreak_patches/runtime_verification/ida_patch_chain_report.json`
- Artifacts: `Research/KernelJailbreakPatches/RuntimeVerification/ida_patch_chain_report.md`
<!-- END_RUNTIME_IDA_VERIFICATION_2026_03_05 -->

## 2026-03-06 Upstream Rework Review

- `patch_fw.py` remains correct here: the function entry rewrite still lands at `0x01063148/4C` on research and `0x01027148/4C` on release.
- The reveal path remains structural from the shared `_proc_info` switch anchor into the small repeated BL target used by the switch cases. IDA/XNU review still matches `proc_security_policy()` semantics in `research/reference/xnu/bsd/kern/proc_info.c`.
- No retarget was needed in this pass; the matcher stays fail-closed and focused dry-runs remain unique on both kernels.
