# B20 `patch_thid_should_crash`

## Revalidated patch target (IDA static, rebuilt from scratch)

- Patch mixin: `scripts/patchers/kernel_jb_patch_thid_crash.py` → `KernelJBPatchThidCrashMixin.patch_thid_should_crash`.
- Real patch point is global byte `jb20_patchpoint_thid_should_crash`:
  - VA: `0xfffffe0007682b50`
  - file offset: `0x67EB50`
  - default bytes: `01 00 00 00 ...` (flag enabled by default).
- Sysctl metadata linkage:
  - name string: `jb20_supp_str_thid_should_crash` at `0xfffffe0009790bc0`
  - sysctl oid/name ptr: `jb20_supp_sysctl_oid_thid_should_crash_name` at `0xfffffe0009790bd8`
  - sysctl data ptr: `jb20_supp_sysctl_oid_thid_should_crash_ptr` at `0xfffffe0009790be0` → points to `0xfffffe0007682b50`.

## Patched function semantics (actual gate logic)

- Patched function: `jb20_patch_target_set_exception_thid_gate` (`0xfffffe0007b08178`).
- Key logic:
  1. Load `jb20_patchpoint_thid_should_crash` byte.
  2. If bit0 is set, call `jb20_supp_debug_exception_enqueue` (`0xfffffe0007b53fcc`) with tag `0x2000000600000000`.
  3. Always emit `"com.apple.xnu.set_exception"` event payload.
  4. Return `1 & ~thid_should_crash` (`BIC W0, W19, W8`).
- Therefore:
  - flag `1` => return `0`
  - flag `0` => return `1`.

## Why this blocks unsigned bootstrap / launchd-dylib flow

- Common gate function `jb20_supp_set_exception_ports_common` (`0xfffffe0007b07ed4`) calls the patched function at `0xfffffe0007b08094`.
- Immediate mapping in caller:
  - gate return `0` => returns `53` (`KERN_NOT_SUPPORTED`)
  - gate return non-zero => returns `0` (`KERN_SUCCESS`).
- Because default flag is `1`, this path rejects set-exception-port operations through this shared code path.
- This shared gate is reached from host/task/thread exception-port APIs (see trace below), so bootstrap code that depends on successful exception-port registration (including launchd-side exception wiring used during unsigned bring-up) will fail until this flag is forced to `0`.
- The patch is therefore not just "disable crash"; it flips a global policy gate from "reject + enqueue debug exception" to "allow".

## Full static trace (entry points -> common gate -> patch point)

- Host path:
  - `jb20_supp_mig_host_set_exception_ports` -> `jb20_supp_host_set_exception_ports_core`
  - `jb20_supp_mig_host_swap_exception_ports` -> `jb20_supp_host_swap_exception_ports_core`
  - both enter `jb20_supp_set_exception_ports_common`.
- Task path:
  - `jb20_supp_mig_task_set_exception_ports` -> `jb20_supp_task_set_exception_ports_core`
  - enters `jb20_supp_set_exception_ports_common`.
- Thread path:
  - `jb20_supp_mig_thread_set_exception_ports` -> `jb20_supp_thread_set_exception_ports_core`
  - `jb20_supp_mig_thread_set_exception_alt` -> `jb20_supp_thread_set_exception_alt_core`
  - both enter `jb20_supp_set_exception_ports_common`.
- Final gate:
  - `jb20_supp_set_exception_ports_common` -> `jb20_patch_target_set_exception_thid_gate` -> `jb20_patchpoint_thid_should_crash`.

## IDA-MCP renaming done for this analysis

- `patched_function` group:
  - `jb20_patch_target_set_exception_thid_gate`
  - `jb20_patchpoint_thid_should_crash`
- `supplement` group:
  - `jb20_supp_set_exception_ports_common`
  - `jb20_supp_debug_exception_enqueue`
  - `jb20_supp_host_set_exception_ports_core`
  - `jb20_supp_host_swap_exception_ports_core`
  - `jb20_supp_task_set_exception_ports_core`
  - `jb20_supp_thread_set_exception_ports_core`
  - `jb20_supp_thread_set_exception_alt_core`
  - `jb20_supp_mig_host_set_exception_ports`
  - `jb20_supp_mig_host_swap_exception_ports`
  - `jb20_supp_mig_task_set_exception_ports`
  - `jb20_supp_mig_thread_set_exception_ports`
  - `jb20_supp_mig_thread_set_exception_alt`

## Risk

- This patch globally changes exception-port policy behavior, not only crash side effects.
- It may hide intended kernel diagnostics and alter failure semantics expected by stock userspace.

## Symbol Consistency Audit (2026-03-05)

- Status: `partial`
- Direct recovered symbol `thid_should_crash` is not present in current `kernel_symbols` JSON.
- However, related exception-port entry symbols are recovered (`_Xhost_set_exception_ports`, `_Xtask_set_exception_ports`, `_Xthread_set_exception_ports`), and they are consistent with the static call-path analyzed here.
- Sysctl-string and data-pointer analysis remain valid; target-node naming is still analyst-derived.

## Patch Metadata

- Patch document: `patch_thid_should_crash.md` (B20).
- Primary patcher module: `scripts/patchers/kernel_jb_patch_thid_crash.py`.
- Analysis mode: static binary analysis (IDA-MCP + disassembly + recovered symbols), no runtime patch execution.

## Patch Goal

Clear thid_should_crash policy byte so set-exception-port gate returns success instead of KERN_NOT_SUPPORTED.

## Target Function(s) and Binary Location

- Primary target: global policy byte `thid_should_crash` at `0xfffffe0007682b50` and consumer gate `0xfffffe0007b08178`.
- Patchpoint: global byte zeroed by patcher.

## Kernel Source File Location

- Expected XNU source family: `osfmk/kern/exception.c` / exception-port policy path plus private sysctl glue.
- Confidence: `medium`.

## Function Call Stack

- Primary traced chain (from `Full static trace (entry points -> common gate -> patch point)`):
- Host path:
- `jb20_supp_mig_host_set_exception_ports` -> `jb20_supp_host_set_exception_ports_core`
- `jb20_supp_mig_host_swap_exception_ports` -> `jb20_supp_host_swap_exception_ports_core`
- both enter `jb20_supp_set_exception_ports_common`.
- Task path:
- The upstream entry(s) and patched decision node are linked by direct xref/callsite evidence in this file.

## Patch Hit Points

- Patch hitpoint is selected by contextual matcher and verified against local control-flow.
- Before/after instruction semantics are captured in the patch-site evidence above.

## Current Patch Search Logic

- Implemented in `scripts/patchers/kernel_jb_patch_thid_crash.py`.
- Site resolution uses anchor + opcode-shape + control-flow context; ambiguous candidates are rejected.
- The patch is applied only after a unique candidate is confirmed in-function.
- Uses string anchors + instruction-pattern constraints + structural filters (for example callsite shape, branch form, register/imm checks).

## Pseudocode (Before)

```c
if (thid_should_crash & 1) {
    enqueue_debug_exception(...);
    return 0;
}
return 1;
```

## Pseudocode (After)

```c
thid_should_crash = 0;
return 1;
```

## Validation (Static Evidence)

- Verified with IDA-MCP disassembly/decompilation, xrefs, and callgraph context for the selected site.
- Cross-checked against recovered symbols in `research/kernel_symbols/json/kernelcache.research.vphone600.bin.symbols.json`.
- Address-level evidence in this document is consistent with patcher matcher intent.

## Expected Failure/Panic if Unpatched

- Exception-port gate returns `KERN_NOT_SUPPORTED` (53) under default flag, breaking bootstrap exception registration flow.

## Risk / Side Effects

- This patch weakens a kernel policy gate by design and can broaden behavior beyond stock security assumptions.
- Potential side effects include reduced diagnostics fidelity and wider privileged surface for patched workflows.

## Symbol Consistency Check

- Recovered-symbol status in `kernelcache.research.vphone600.bin.symbols.json`: `partial`.
- Canonical symbol hit(s): none (alias-based static matching used).
- Where canonical names are absent, this document relies on address-level control-flow and instruction evidence; analyst aliases are explicitly marked as aliases.
- IDA-MCP lookup snapshot (2026-03-05): `0xfffffe0007682b50` is a patchpoint/data-site (`Not a function`), so function naming is inferred from surrounding control-flow and xrefs.

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
- IDA mapping: `0/1` points in recognized functions; `1` points are code-cave/data-table writes.
- IDA mapping status: `ok` (IDA runtime mapping loaded.)
- Call-chain mapping status: `ok` (IDA call-chain report loaded.)
- Call-chain validation: `0` function nodes, `0` patch-point VAs.
- Verdict: `questionable`
- Recommendation: Hit is valid but patch is inactive in find_all(); enable only after staged validation.
- Key verified points:
- `0xFFFFFE000768EB48` (`code-cave/data`): zero [_thid_should_crash] | `01000000 -> 00000000`
- Artifacts: `research/kernel_jailbreak_patches/runtime_verification/runtime_verification_report.json`
- Artifacts: `research/kernel_jailbreak_patches/runtime_verification/ida_runtime_patch_points.json`
- Artifacts: `research/kernel_jailbreak_patches/runtime_verification/ida_patch_chain_report.json`
- Artifacts: `Research/KernelJailbreakPatches/RuntimeVerification/ida_patch_chain_report.md`
<!-- END_RUNTIME_IDA_VERIFICATION_2026_03_05 -->

## 2026-03-06 Upstream Rework Review

- `patch_fw.py` directly zeros `0x0067EB50`; release lands at `0x0066AB50`. The current patcher still recovers and zeros that same variable on both kernels.
- Runtime reveal remains string/data anchored (`"thid_should_crash"` -> adjacent `sysctl_oid` -> backing variable in `__DATA`/`__DATA_CONST`), which is preferable to any symbol-based path on the stripped raw kernels.
- IDA re-check (`2026-03-06`) confirms the backing variable is live and currently nonzero (`1`) before patching on research.
- Focused dry-run (`2026-03-06`): research `0x0067EB50`; release `0x0066AB50`.
