# C23 `patch_hook_cred_label_update_execve`

## How the patch works
- Source: `scripts/patchers/kernel_jb_patch_hook_cred_label.py`.
- Locator strategy:
  1. Resolve `vnode_getattr` (symbol or string-near function).
  2. Find sandbox `mac_policy_ops` table from Seatbelt policy metadata.
  3. Pick cred-label execve hook entry from early ops indices by function-size heuristic.
- Patch action:
  - Inject cave shellcode that:
    - builds inline `vfs_context`,
    - calls `vnode_getattr`,
    - propagates uid/gid into new credential,
    - updates csflags,
    - jumps back to original hook.
  - Rewrite selected ops-table pointer entry to cave target (preserving auth-rebase upper bits).

## Expected outcome
- Interpose sandbox cred-label execve hook with custom ownership/credential propagation logic.

## Target
- One `mac_policy_ops` function-pointer entry plus injected hook shellcode cave.

## IDA MCP evidence
- `vnode_getattr` string-related hit:
  - xref `0xfffffe00084c08ec` -> function start `0xfffffe00084c0718`
- Seatbelt policy anchor:
  - `Seatbelt sandbox policy` @ `0xfffffe00075fd493`
  - data xref @ `0xfffffe0007a58430` (policy config region)

## Risk
- Table-entry rewrite + shellcode interposition is invasive; incorrect index/cave selection can break sandbox hook dispatch.
