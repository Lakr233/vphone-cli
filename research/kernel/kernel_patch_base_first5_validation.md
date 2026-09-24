# Non-JB Kernel Patch Validation (Base #1-#5)

Date: 2026-03-05  
Target: `vm/iPhone17,3_26.1_23B85_Restore/kernelcache.research.vphone600` (clean `fw_prepare` image)  
Scope: Regular/Dev shared base kernel patches #1-#5 from `KernelPatcher.find_all()`

## Methods

1. Run patch locators on clean kernel bytes (no pre-applied patch writes).
2. Record exact match offsets/VA and before/after instruction bytes.
3. Validate control-flow semantics in IDA for each matched branch/function.
4. Confirm candidate uniqueness for each locator.

## Match Results

- Base VA: `0xFFFFFE0007004000`
- #1 `patch_apfs_root_snapshot`
  - hit: `off=0x02476964`, `va=0xFFFFFE000947A964`
  - before: `tbnz w8, #5, #0x2476b6c`
  - after: `nop`
- #2 `patch_apfs_seal_broken`
  - hit: `off=0x023CFDE4`, `va=0xFFFFFE00093D3DE4`
  - before: `tbnz w0, #0xe, #0x23cfe10`
  - after: `nop`
- #3 `patch_bsd_init_rootvp`
  - hit: `off=0x00F6D960`, `va=0xFFFFFE0007F71960`
  - before: `cbnz w0, #0xf6dbc8`
  - after: `nop`
- #4 `patch_proc_check_launch_constraints` (entry instruction 1)
  - hit: `off=0x0163863C`, `va=0xFFFFFE000863C63C`
  - before: `pacibsp`
  - after: `mov w0, #0`
- #5 `patch_proc_check_launch_constraints` (entry instruction 2)
  - hit: `off=0x01638640`, `va=0xFFFFFE000863C640`
  - before: `sub sp, sp, #0x180`
  - after: `ret`

## IDA Semantic Checks

- #1 branch target block (`0xFFFFFE000947AB6C`) is in the same APFS function and contains root-snapshot failure path ending in `BL panic`.
- #2 branch target block (`0xFFFFFE00093D3E10`) contains `"root volume seal is broken"` path ending in `BL panic`.
- #3 branch target block (`0xFFFFFE0007F71BC8`) contains `"rootvp not authenticated after mounting"` path ending in `BL panic`.
- #4/#5 string anchor `"AMFI: Validation Category info"` resolves to one AMFI function whose entry is rewritten to immediate success return (`mov w0,#0; ret`).

## Uniqueness Checks

- #1 refs: `1`, valid candidates: `1`
- #2 refs: `1`, valid candidates: `1`
- #3 refs: `1`, valid candidates: `1`
- #4 refs: `1`, unique function start: `0x0163863C`

## Verdict

For this kernel variant, base patches #1-#5 are correctly located and semantically aligned with intended bypass behavior.  
Status: **working for now**.
