# B8 `patch_convert_port_to_map`

## How the patch works
- Source: `scripts/patchers/kernel_jb_patch_port_to_map.py`.
- Locator strategy:
  1. Anchor panic string: `"userspace has control access to a kernel map"`.
  2. Find xref to that string and nearby `BL _panic`.
  3. Walk backward to locate the conditional branch entering the panic block.
- Patch action:
  - Replace that conditional branch with unconditional `B` to `resume_off` (`bl_panic + 4`), so execution skips the panic call.

## Expected outcome
- Kernel no longer panics on this convert-port-to-map control-access check path.

## Target
- The panic edge in `_convert_port_to_map_with_flavor` (or equivalent stripped function), specifically the branch feeding the panic block.

## IDA MCP evidence
- Panic string: `0xfffffe0007040701`
- String xref site: `0xfffffe0007b06eac`
- Containing function start: `0xfffffe0007b06db8`

## Full call-stack sample (static, from IDA xrefs)
- This is one complete observed caller chain down to the patched function:
  1. data dispatch ref: `0xfffffe00078ee8c8` -> function `sub_FFFFFE00089B17E0` (`0xfffffe00089b17e0`)
  2. call at `0xfffffe00089b1c50`: `BL sub_FFFFFE0008A1F0A0`
  3. call at `0xfffffe0008a1f31c`: `BL sub_FFFFFE0008A19DC8`
  4. call at `0xfffffe0008a19e34`: `BL sub_FFFFFE0008A2D948`
  5. call at `0xfffffe0008a2d9a4`: `BL sub_FFFFFE0007BD2544`
  6. call at `0xfffffe0007bd2694`: `B sub_FFFFFE0007B06DB8`
  7. panic-log reference inside target function: `0xfffffe0007b06eac`

## Risk
- This converts a hard fail (panic) into continue-execution behavior; if downstream invariants were relying on panic-stop, memory safety assumptions may no longer hold.
