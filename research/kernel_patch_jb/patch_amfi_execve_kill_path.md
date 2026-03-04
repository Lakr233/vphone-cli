# A2 `patch_amfi_execve_kill_path` (currently commented as PANIC in the main flow)

## 1) How the Patch Is Applied
- Source implementation: `scripts/patchers/kernel_jb_patch_amfi_execve.py`
- Match strategy:
  - String anchor: `"AMFI: hook..execve() killing"` (fallback: `"execve() killing"`).
  - After finding the function that references this string, scan its early region for **two** `BL + (cbz/cbnz w0,...)` check sites.
- Rewrite: replace both `BL` instructions with `mov x0, #0` (direct success-result semantics).

## 2) Expected Behavior
- Short-circuit failure decisions in the AMFI execve kill helper and avoid entering the kill path.

## 3) Target
- Target function: execve-related AMFI helper (log string indicates the `hook..execve() killing ...` path).
- Security objective: relax execution-path checks and reduce termination on unsigned/invalid signatures.

## 4) IDA MCP Binary Evidence
- String hits (examples):
  - `0xfffffe00071f71c2` `AMFI: hook..execve() killing ... unsigned code ...`
  - `0xfffffe00071f73b8` `... Legacy VPN Plugin ...`
  - `0xfffffe00071f740b` `... dyld signature cannot be verified ...`
- Xrefs for these strings all land in the same function:
  - xref: `0xfffffe000863fcfc / 0xfffffe000863feb4 / 0xfffffe000863fef4`
  - function start: `0xfffffe000863fc6c`

## 5) Risks and Side Effects
- This patch is already commented as `PANIC` in `find_all()`, indicating known stability risk on the current sample.
- Flattening two check return values may break downstream assumptions (for example, uninitialized state being treated as success).
