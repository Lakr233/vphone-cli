# C22 `patch_syscallmask_apply_to_proc`

## How the patch works
- Source: `scripts/patchers/kernel_jb_patch_syscallmask.py`.
- Locator strategy:
  1. Try symbol `_syscallmask_apply_to_proc`.
  2. Fallback string anchor `syscallmask.c`.
  3. Resolve helper targets (`zalloc_ro_mut`, `proc_set_syscall_filter_mask`) from local call graph.
- Patch action:
  - Inject large shellcode into cave:
    - build/adjust syscall filter mask,
    - call allocator helper,
    - tail-branch to original filter-setter path.
  - Patch original function to jump into cave after register setup.

## Expected outcome
- Replace default syscall mask application behavior with custom filter handling logic.

## Target
- `_syscallmask_apply_to_proc` body entry-side injection point and cave redirection.

## IDA MCP evidence
- Anchor string: `0xfffffe00075fcec6` (`"syscallmask.c"`)
- Sample xrefs/function starts:
  - `0xfffffe0009399600` -> `0xfffffe00093995b4`
  - `0xfffffe00093adb6c` -> `0xfffffe00093ac964`
- Additional related string: `sandbox.syscallmasks` present in IDB.

## Risk
- Large cave shellcode with multiple helper calls increases compatibility and control-flow risk.
