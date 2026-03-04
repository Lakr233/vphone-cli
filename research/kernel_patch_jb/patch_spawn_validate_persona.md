# B14 `patch_spawn_validate_persona`

## How the patch works
- Source: `scripts/patchers/kernel_jb_patch_spawn_persona.py`.
- Locator strategy:
  1. Try symbol `_spawn_validate_persona`.
  2. Fallback pattern match: `ldr wN, [xN, #0x600]` with nearby `tbnz wN, #1`.
- Patch action:
  - NOP the `ldr` and the matched `tbnz` site.

## Expected outcome
- Disable persona validation decision branch in spawn path.

## Target
- Persona-flag load/check pair in `_spawn_validate_persona` flow.

## IDA MCP evidence (current state)
- No direct string anchor and no symbol names in this stripped IDB.
- Pattern-level behavior is clear from patch code, but this pass did not isolate one unique static address pair under MCP short execution windows.
- Status: semantics confirmed; concrete offsets pending longer scripted sweep.

## Risk
- Persona checks are part of process-creation security model; bypass can relax intended privilege boundaries.
