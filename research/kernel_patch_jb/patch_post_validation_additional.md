# B5 `patch_post_validation_additional`

## 1) How the Patch Is Applied
- Source implementation: `scripts/patchers/kernel_jb_patch_post_validation.py`
- Match strategy:
  - Anchor string: `AMFI: code signature validation failed`
  - Find callers that reference this string, then walk their `BL` callees.
  - In the callee, locate `cmp w0, #imm` + `b.ne` patterns with a nearby preceding `bl`.
- Rewrite: change `cmp w0, #imm` to `cmp w0, w0`.

## 2) Expected Behavior
- Convert a postValidation failure comparison into an identity comparison, so `b.ne` loses its original reject semantics.

## 3) Target
- Target logic: additional reject path in AMFI code-sign post validation.
- Security objective: reduce forced rejection after signature-validation failure.

## 4) IDA MCP Binary Evidence
- String: `0xfffffe00071f80bf` `"AMFI: code signature validation failed.\n"`
- Xrefs (same function):
  - `0xfffffe0008642290`
  - `0xfffffe0008642bf0`
  - `0xfffffe0008642e98`
- Corresponding function start: `0xfffffe0008641924`

## 5) Risks and Side Effects
- Turns a post-validation error-convergence condition into one that effectively never triggers rejection.
