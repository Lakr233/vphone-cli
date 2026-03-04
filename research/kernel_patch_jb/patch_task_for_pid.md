# B15 `patch_task_for_pid`

## How the patch works
- Source: `scripts/patchers/kernel_jb_patch_task_for_pid.py`.
- Locator strategy:
  1. Try symbol `_task_for_pid`.
  2. Otherwise scan for a trap-like function profile:
     - no direct BL callers,
     - multiple `ldadda`,
     - repeated `ldr wN, [xN, #0x490]` + `str wN, [xN, #0xc]`,
     - `movk ..., #0xc8a2`,
     - BL to high-caller target.
- Patch action:
  - NOP the second `ldr ... #0x490` (target proc security copy).

## Expected outcome
- Skip copying restrictive proc_ro security state in task_for_pid path.

## Target
- Security-copy instruction sequence in `_task_for_pid` internals.

## IDA MCP evidence (current state)
- Relevant policy strings exist (`task_for_pid-allow`, AMFI task_for_pid log), but those resolve mainly to AMFI policy handlers, not directly to the trap implementation this patch targets.
- This patch relies on multi-feature structural matching rather than a single anchor; exact final patch offset is pending deeper automated scan.

## Risk
- task_for_pid hardening bypass is high-impact and can enable broader task-port access.
