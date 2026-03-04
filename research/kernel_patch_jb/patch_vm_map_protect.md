# B10 `patch_vm_map_protect`

## How the patch works
- Source: `scripts/patchers/kernel_jb_patch_vm_protect.py`.
- Locator strategy:
  1. Try symbol `_vm_map_protect`.
  2. Fallback string anchor: `"vm_map_protect("`.
  3. In function body, find forward `TBNZ` with high bit test (`bit >= 24`) used as guard.
- Patch action:
  - Rewrite that conditional `TBNZ` into unconditional `B target`.

## Expected outcome
- Force bypass of a protection-check branch in `vm_map_protect` flow.

## Target
- High-bit permission/attribute guard branch in vm_map_protect path.

## IDA MCP evidence
- String: `0xfffffe0007049ab7` (`"vm_map_protect(%p,...)"`)
- xref: `0xfffffe0007bc4680`
- containing function start: `0xfffffe0007bc405c`

## Risk
- This may allow mapping/protection transitions that original VM policy intended to reject.
