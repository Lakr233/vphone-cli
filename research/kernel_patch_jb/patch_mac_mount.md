# B11 `patch_mac_mount`

## How the patch works
- Source: `scripts/patchers/kernel_jb_patch_mac_mount.py`.
- Locator strategy:
  1. Try symbols `___mac_mount` / `__mac_mount`.
  2. Fallback anchor string `"mount_common()"`, then inspect BL targets for MAC-check shape.
- Patch action:
  - NOP the `BL` check call followed by `CBNZ w0`.
  - Optionally force `mov x8, xzr` at nearby state setup point.

## Expected outcome
- Bypass MAC mount decision path so mount flow keeps going.

## Target
- MAC policy check branch sequence in `___mac_mount`-related path.

## IDA MCP evidence
- String: `0xfffffe0007056a9d` (`"mount_common(): ..."`)
- xref: `0xfffffe0007ca8de0`
- containing function start: `0xfffffe0007ca7868`

## Risk
- Mount authorization bypass can weaken filesystem integrity assumptions.
