# B16 `patch_load_dylinker`

## How the patch works
- Source: `scripts/patchers/kernel_jb_patch_load_dylinker.py`.
- Locator strategy:
  1. Try symbol `_load_dylinker`.
  2. Otherwise find function with repeated PAC triplets:
     - `tst xN, #0x40000000000000`
     - `b.eq ...`
     - `movk xN, #0xc8a2`
     - repeated >= 3 times, usually in a function with no direct BL callers.
- Patch action:
  - Replace the **last** `tst` with unconditional branch to the `b.eq` target.

## Expected outcome
- Always skip selected PAC re-sign/check path in chained-fixup rebase flow.

## Target
- PAC decision branch in `_load_dylinker`-related fixup path.

## IDA MCP evidence (current state)
- No direct stable string/symbol anchor for this stripped build.
- The patch design is pattern-based and function-profile-based; exact static site remains pending additional scripted narrowing.

## Risk
- PAC bypass in dylinker/fixup path is security-sensitive and can alter pointer-auth assumptions globally.
