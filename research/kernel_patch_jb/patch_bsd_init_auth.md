# B13 `patch_bsd_init_auth`

## How the patch works
- Source: `scripts/patchers/kernel_jb_patch_bsd_init_auth.py`.
- Locator strategy:
  1. Try symbol `_bsd_init`.
  2. Fallback pattern search: `ldr x0, [xN, #0x2b8]` -> `cbz x0, ...` -> `bl AUTH_FUNC`.
- Patch action:
  - Replace the `BL AUTH_FUNC` with `mov x0, #0`.

## Expected outcome
- Force rootvp authentication check path to return success.

## Target
- Authentication helper call in `_bsd_init` boot path.

## IDA MCP evidence
- Related string anchor (used for cross-check): `0xfffffe000707d2fd`
  - text: `"rootvp not authenticated after mounting @%s:%d"`
- xref: `0xfffffe0007f71bd8`
- containing function start: `0xfffffe0007f70da8`

## Risk
- Early boot filesystem trust checks are security-critical; bypass can permit untrusted root volume state.
