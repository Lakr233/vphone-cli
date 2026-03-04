# B12 `patch_dounmount`

## How the patch works
- Source: `scripts/patchers/kernel_jb_patch_dounmount.py`.
- Locator strategy:
  1. Try symbol `_dounmount`.
  2. Fallback anchor string `"dounmount:"` and inspect call targets.
  3. Match sequence `mov w1,#0` + `mov x2,#0` + `bl ...` (MAC check pattern).
- Patch action:
  - NOP the matched `BL` MAC-check call.

## Expected outcome
- Suppress unmount MAC check path and continue unmount operation.

## Target
- MAC authorization call site in `_dounmount` path.

## IDA MCP evidence
- String: `0xfffffe000705661c` (`"dounmount: no coveredvp ..."`)
- xref: `0xfffffe0007cac34c`
- containing function start: `0xfffffe0007cabaec`

## Risk
- Can bypass policy enforcement around unmount operations.
