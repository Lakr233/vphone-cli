# B9 `patch_vm_fault_enter_prepare`

## How the patch works
- Source: `scripts/patchers/kernel_jb_patch_vm_fault.py`.
- Locator strategy:
  1. Try symbol `_vm_fault_enter_prepare`.
  2. Fallback string anchor: `"vm_fault_enter_prepare"`.
  3. Find a `BL` to a rarely-called function, followed within 4 instructions by `TBZ/TBNZ w0`.
- Patch action:
  - NOP the selected `BL` site.

## Expected outcome
- Skip a PMAP-related check helper invocation in vm fault preparation path.

## Target
- A specific check call inside `vm_fault_enter_prepare` path that gates later behavior via `w0` bit test branch.

## IDA MCP evidence
- String: `0xfffffe0007048b3f` (`"vm_fault_enter_prepare"`)
- xrefs:
  - `0xfffffe0007badae8`
  - `0xfffffe0007bae6d0`
- containing function start: `0xfffffe0007bada3c`

## Risk
- Bypassing vm fault guard logic can destabilize memory-management safety paths and produce hard-to-debug faults.
