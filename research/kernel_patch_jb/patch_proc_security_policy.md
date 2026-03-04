# B6 `patch_proc_security_policy`

## How the patch works
- Source: `scripts/patchers/kernel_jb_patch_proc_security.py`.
- Locator strategy:
  1. Try symbol `_proc_security_policy`.
  2. If stripped, locate `_proc_info` by a switch-shape signature (`sub wN, wM, #1` + `cmp wN, #0x21`).
  3. Inside that function, count BL targets and pick the most-called one as `_proc_security_policy`.
- Patch action: overwrite target function entry with:
  - `mov x0, #0`
  - `ret`

## Expected outcome
- Force `proc_security_policy` checks to return success.

## Target
- Targeted logic is the centralized process-security policy gate used by `proc_info` family paths.

## IDA MCP evidence (current state)
- This patch is mainly pattern-driven and symbol-first; this IDB is stripped.
- I validated related immediate patterns and candidate comparison sites in kernel text, but did not obtain a single uniquely provable `_proc_info -> most-called callee` chain within MCP single-call time limits.
- Status: behavior-level analysis confirmed from patch code; exact final function address is pending a longer multi-pass IDA sweep.

## Risk
- Turning this policy function into unconditional success can over-broaden process introspection and privilege surfaces.
