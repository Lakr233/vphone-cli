# B18 `patch_nvram_verify_permission`

## How the patch works
- Source: `scripts/patchers/kernel_jb_patch_nvram.py`.
- Locator strategy:
  1. Try NVRAM verifyPermission symbol.
  2. Fallback string anchor `krn.` and scan backward from its load site for nearby `tbz/tbnz` guard.
  3. Secondary fallback: entitlement string `com.apple.private.iokit.nvram-write-access`.
- Patch action:
  - NOP selected `tbz/tbnz` permission guard.

## Expected outcome
- Bypass NVRAM permission gating in verifyPermission path.

## Target
- Bit-test branch enforcing write permission policy in IONVRAM permission checks.

## IDA MCP evidence
- `krn.` anchor string: `0xfffffe0007156000`
  - xrefs: `0xfffffe00084c2608`, `0xfffffe00084cd92c`
- entitlement anchor string: `0xfffffe00070a238f`
  - xref: `0xfffffe000823810c` (function start `0xfffffe0008237ee8`)

## Risk
- NVRAM permission bypass can enable persistent config tampering.
