# B20 `patch_thid_should_crash`

## How the patch works
- Source: `scripts/patchers/kernel_jb_patch_thid_crash.py`.
- Locator strategy:
  1. Try symbol `_thid_should_crash`.
  2. Fallback by locating `"thid_should_crash"` sysctl-name string in data.
  3. Walk nearby sysctl-related data entries to recover the backing variable pointer.
- Patch action:
  - Write `0x00000000` to the resolved global int variable.

## Expected outcome
- Disable crash behavior controlled by `_thid_should_crash` flag.

## Target
- Global data variable (not code) backing the `thid_should_crash` sysctl path.

## IDA MCP evidence
- String: `0xfffffe0009790bc0` (`"thid_should_crash"`)
- data xref nearby: `0xfffffe0009790bd8`
- This matches patch design: derive writable flag address from adjacent sysctl metadata.

## Risk
- Directly mutating global crash-control flags can hide error paths expected during diagnostics.
