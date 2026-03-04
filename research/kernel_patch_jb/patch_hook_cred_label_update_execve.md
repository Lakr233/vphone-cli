# C23 `patch_hook_cred_label_update_execve`

## 1) How the Patch Works
- Source: `scripts/patchers/kernel_jb_patch_hook_cred_label.py`.
- Locator strategy:
  1. Resolve `vnode_getattr` (symbol or string-near function).
  2. Find sandbox `mac_policy_ops` table from Seatbelt policy metadata.
  3. Pick cred-label execve hook entry from early ops indices by function-size heuristic.
- Patch action:
  - Inject cave shellcode that:
    - builds inline `vfs_context` via `mrs tpidr_el1` (current_thread),
    - calls `vnode_getattr`,
    - propagates uid/gid into new credential,
    - updates csflags with CS_VALID,
    - jumps back to original hook.
  - Rewrite selected ops-table pointer entry to cave target (preserving auth-rebase upper bits).

## 2) Expected Outcome
- Interpose sandbox cred-label execve hook with custom ownership/credential propagation logic.

## 3) Target
- Ops table: `mac_policy_ops` at `0xFFFFFE0007A58488` (discovered via mac_policy_conf)
- Hook index: 18 (largest function in ops[0:29], 4208 bytes)
  - Original hook: `sub_FFFFFE00093BDB64` (Sandbox `hook..execve()` handler)
  - Contains: sandbox profile evaluation, container assignment, entitlement processing
- One `mac_policy_ops` function-pointer entry + injected hook shellcode cave.

## 4) IDA MCP Evidence

### Ops table structure
- `mac_policy_conf` at `0xFFFFFE0007A58428`:
  - +0: `0xFE00075FF33D` → "Sandbox" (mpc_name)
  - +8: `0xFE00075FD493` → "Seatbelt sandbox policy" (mpc_fullname)
  - +32: `0xFE0007A58488` → mpc_ops (ops table pointer)
- Ops table entries (non-null in first 30):
  - [6]: `0xFE00093BDB58` (12 bytes)
  - [7]: `0xFE00093B0C04` (36 bytes)
  - [11]: `0xFE00093B0B68` (156 bytes)
  - [13]: `0xFE00093B0B5C` (12 bytes)
  - [18]: `0xFE00093BDB64` (4208 bytes) ← **selected by size heuristic**
  - [19]: `0xFE00093B0AE8` (116 bytes)
  - [29]: `0xFE00093B0830` (696 bytes)

### vnode_getattr
- String-related hit: xref `0xFE00084C08EC` → function start `0xFE00084C0718`

### Chained fixup format
- Ops table entries use auth rebase (bit63=1):
  - Upper 32 bits: diversity(16) + addrDiv(1) + key(2) + next(12) + auth(1)
  - Lower 32 bits: target file offset
- The rewrite preserves upper bits and replaces lower 32 with cave file offset.
- Kernel loader re-signs the new target with the same PAC key/diversity → valid PAC pointer.

## 5) Previous Bug (PANIC root cause)
The code cave was allocated in `__PRELINK_TEXT` segment. While marked R-X in the
Mach-O, this segment is **non-executable at runtime** on ARM64e due to
KTRR (Kernel Text Read-only Region) enforcement. The cave ended up at a low
file offset (e.g. 0x5440) in __PRELINK_TEXT padding, which at runtime maps to a
non-executable page.

**Panic**: "Kernel instruction fetch abort at pc 0xfffffe004761d440"
- The 0x47 in the upper nibble (instead of expected 0x07) indicates PAC poisoning:
  the CPU attempted to branch through the ops table pointer, PAC auth succeeded,
  but the target address was in a non-executable region → instruction fetch fault.

## 6) Fix Applied
- Modified `_find_code_cave()` in `kernel_jb_base.py` to only search `__TEXT_EXEC`
  and `__TEXT_BOOT_EXEC` segments.
- `__PRELINK_TEXT` is now explicitly excluded since KTRR makes it non-executable
  at runtime despite the Mach-O R-X flags.
- Verified __TEXT_EXEC has sufficient padding at segment end (0x1A10+ bytes of zeros
  at `0xFE00095C25F0`) for the 180-byte shellcode.

## 7) Risk Assessment
- **Medium-High**: Table-entry rewrite + shellcode interposition is invasive.
  Incorrect index selection or shellcode bugs can break sandbox hook dispatch.
- Mitigated by: dynamic function-size heuristic for index detection, PAC-aware
  chained fixup pointer rewrite, and __TEXT_EXEC-restricted code cave.
