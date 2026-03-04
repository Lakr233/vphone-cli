# C21 `patch_cred_label_update_execve`

## How the patch works
- Source: `scripts/patchers/kernel_jb_patch_cred_label.py`.
- Locator strategy:
  1. Try symbol containing `cred_label_update_execve`.
  2. Fallback via AMFI execve-related string neighborhood.
  3. Resolve function end and final return site.
- Patch action:
  - Allocate code cave and inject shellcode that edits `cs_flags`:
    - set `CS_PLATFORM_BINARY` and selected permissive flags,
    - clear selected hard/kill bits,
    - return success.
  - Replace original function return with branch to shellcode cave.

## Expected outcome
- Force permissive credential/code-signing flags during execve cred-label update.

## Target
- Return edge of `_cred_label_update_execve`-related function (redirect to cave).

## IDA MCP evidence
- Relevant AMFI anchors used by locator:
  - `AMFI: code signature validation failed` @ `0xfffffe00071f80bf`
  - `execve() killing` strings around `0xfffffe00071f71c2` / `...73b8` / `...740b`
- These strings cluster in AMFI functions around:
  - `0xfffffe0008641924`
  - `0xfffffe000863fc6c`

## Risk
- This is a high-impact shellcode redirect patch; wrong cave/return resolution can panic.
- Direct cs_flags manipulation changes trust semantics globally for targeted execve paths.
