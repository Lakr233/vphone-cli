# B19 `patch_io_secure_bsd_root`

## How the patch works
- Source: `scripts/patchers/kernel_jb_patch_secure_root.py`.
- Locator strategy:
  1. Try symbol `_IOSecureBSDRoot`.
  2. Fallback string anchor `SecureRootName`.
  3. In target function, locate first forward conditional branch (`cbz/cbnz/tbz/tbnz`).
- Patch action:
  - Replace conditional branch with unconditional `B target`.

## Expected outcome
- Always take the forward branch and skip selected secure-root check path.

## Target
- Security decision branch inside `_IOSecureBSDRoot` flow.

## IDA MCP evidence
- `SecureRootName` occurrences:
  - `0xfffffe00070a66a5` -> xref `0xfffffe000828f444` -> function start `0xfffffe000828f42c`
  - `0xfffffe0007108f2d` -> xref `0xfffffe000836624c` -> function start `0xfffffe0008366008`
- Patch script uses first successful function resolution in scan order.

## Risk
- Secure-root checks are trust anchors; forcing the branch can weaken platform integrity assumptions.
