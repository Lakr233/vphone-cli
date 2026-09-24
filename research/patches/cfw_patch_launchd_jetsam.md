# CFW JB-1 `patch-launchd-jetsam`

## How the patch works

- Source: `scripts/patchers/cfw_patch_jetsam.py`.
- Locator strategy:
  1. Find one of these anchor strings in launchd:
     - `jetsam property category (Daemon) is not initialized`
     - `jetsam property category`
     - `initproc exited -- exit reason namespace 7 subcode 0x1`
  2. Resolve enclosing C-string start and locate `ADRP+ADD` code xref in `__TEXT,__text`.
  3. Scan backward (`0x300` bytes window) for conditional branch whose target block contains `ret/retab`.
  4. Rewrite selected conditional branch to unconditional `b <same_target>`.
- Patch action:
  - keystone compile with absolute address context:
    `asm_at("b #<target>", patch_off)`.

## Source Code Trace (Scanner)

- Entrypoint:
  - `scripts/patchers/cfw.py` -> command `patch-launchd-jetsam`
  - dispatches to `patch_launchd_jetsam(filepath)`
- Method path:
  1. `parse_macho_sections()` + `find_section("__TEXT,__text")`
  2. `_find_cstring_start()` on matched anchor
  3. `_find_adrp_add_ref()` to locate string-use site in code
  4. backward scan over conditionals (`b.*`, `cbz/cbnz/tbz/tbnz`)
  5. `_is_return_block()` filter (target block must contain `ret/retab`)
  6. `asm_at("b #target", patch_off)` and binary overwrite

## Validation Evidence (current workspace)

- Install pipeline wiring confirmed:
  - `scripts/cfw_install_jb.sh` JB-1 stage calls:
    - `inject-dylib ... /cores/launchdhook.dylib`
    - `patch-launchd-jetsam ...`
  - `scripts/cfw_install_dev.sh` also calls `patch-launchd-jetsam`.
- `git log` for patch module:
  - only refactor-origin commit history (`3bcb189`), no dedicated bug-fix trail for this patch logic.
- Local replay limitation:
  - workspace currently has no extracted iOS launchd sample binary/log artifact for deterministic offline replay.

## Risk Assessment

- Current algorithm is fully dynamic and avoids hardcoded offsets.
- But branch selection is still broad (backward window + earliest matching conditional to return block).
- Without binary-level replay evidence on current target launchd, there is residual false-hit risk.

## Status

- **Still unproven** (possible working, possible mis-hit) under strict confidence gate.

## Next Verification Step

- Obtain one actual `/mnt1/sbin/launchd.bak` sample from current target build and capture:
  - before/after patch disassembly around `patch_off`
  - matched anchor string VA + xref VA
  - final branch target basic block (`ret/retab`) confirmation.
