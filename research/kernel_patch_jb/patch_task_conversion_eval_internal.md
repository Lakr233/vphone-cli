# A3 `patch_task_conversion_eval_internal`

## 1) How the Patch Is Applied
- Source implementation: `scripts/patchers/kernel_jb_patch_task_conversion.py`
- Match strategy: pure instruction-semantic matching (no string anchor):
  - `ldr Xn, [Xn]`
  - `cmp Xn, x0`
  - `b.eq ...`
  - `cmp Xn, x1`
  - `b.eq ...`
- Rewrite: change `cmp Xn, x0` to `cmp xzr, xzr` (identity compare, effectively making the equal-path reachable unconditionally).

## 2) Expected Behavior
- Relax the internal guard in task conversion so later comparison branches are more likely to take the allow path.

## 3) Target
- Target logic: core identity/relationship check point inside `_task_conversion_eval_internal`.
- Security objective: reduce task-conversion denial rate to support task-related privilege escalation chains.

## 4) IDA MCP Binary Evidence
- This patch has no stable string anchor, and the current IDB is stripped (no symbols).
- Pattern-level scans via IDA MCP were attempted (`cmp` + double `b.eq` structure), but did not converge to a unique address within the MCP single-run 15s limit.
- Conclusion: keep this document in "pattern confirmed, address pending" state for now.

## 5) Risks and Side Effects
- This kind of `cmp` short-circuit affects task security boundaries. If the hit point is wrong, it can cause permission-model corruption or panic.
