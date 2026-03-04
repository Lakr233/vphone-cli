# C24 `patch_kcall10`

## How the patch works
- Source: `scripts/patchers/kernel_jb_patch_kcall10.py`.
- Locator strategy:
  1. Resolve `_nosys` (symbol or `mov w0,#0x4e; ret` pattern).
  2. Scan DATA segments for `sysent` table signature (entry decoding points to `_nosys`).
  3. Compute `sysent[439]` (`SYS_kas_info`) entry offset.
- Patch action:
  - Inject `kcall10` shellcode in code cave (argument marshalling + `blr x16` + result write-back).
  - Rewrite `sysent[439]` fields:
    - `sy_call` -> cave VA
    - `sy_munge32` -> `_munge_wwwwwwww` (if resolved)
    - return type + arg metadata.

## Expected outcome
- Replace syscall 439 handler with arbitrary 10-arg kernel call trampoline behavior.

## Target
- `sysent[439]` table entry and cave shellcode block.

## IDA MCP evidence
- Pattern `mov w0,#0x4e; ret` appears in multiple tiny stubs (expected in this build).
- One strong candidate family is around `0xfffffe00084b5d3c` (tiny nosys-like stub with many data refs), consistent with table-dispatch use.
- This matches patch design that depends on data-table discovery rather than direct named symbol.

## Risk
- Syscall table rewrite is extremely invasive; wrong table/entry decode can hard panic the kernel.
