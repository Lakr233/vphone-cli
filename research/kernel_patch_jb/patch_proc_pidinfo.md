# B7 `patch_proc_pidinfo`

## How the patch works
- Source: `scripts/patchers/kernel_jb_patch_proc_pidinfo.py`.
- Locator strategy:
  1. Try symbol `_proc_pidinfo`.
  2. Otherwise, re-find `_proc_info` using the same switch-pattern heuristic (`... #0x21`).
  3. In early prologue window, collect first two `cbz/cbnz` guards (pid-0 / null-proc style guards).
- Patch action: NOP the first two guard branches.

## Expected outcome
- Bypass early pid/proc guard branches so pidinfo flow continues instead of early rejection.

## Target
- The early guard checks in `_proc_pidinfo` path (or the equivalent early guard sequence reached from `_proc_info`).

## IDA MCP evidence (current state)
- No stable symbol names are present in this stripped IDB.
- I validated that this patch is branch-guard NOP logic driven by pattern matching, but a unique static address pair was not resolved yet in short MCP windows.
- Status: patch semantics confirmed; exact two branch offsets pending extended automated sweep.

## Risk
- Removing these guards can expose process metadata paths that were expected to fail for invalid or restricted pid/proc states.
