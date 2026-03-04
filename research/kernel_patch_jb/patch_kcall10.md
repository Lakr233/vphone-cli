# C24 `patch_kcall10`

## Status: BOOT OK

Previous status: NOT_BOOT (timeout, no panic).

## How the patch works
- Source: `scripts/patchers/kernel_jb_patch_kcall10.py`.
- Locator strategy:
  1. Resolve `_nosys` (symbol or `mov w0,#0x4e; ret` pattern).
  2. Scan DATA segments for first entry whose decoded pointer == `_nosys`.
  3. **Scan backward** in 24-byte steps from the match to find the real table start
     (entry 0 is the indirect syscall handler, NOT `_nosys`).
  4. Compute `sysent[439]` (`SYS_kas_info`) entry offset from the real base.
- Patch action:
  - Inject `kcall10` shellcode in code cave (argument marshalling + `BLR X16` + result write-back).
  - Rewrite `sysent[439]` fields using **proper chained fixup encoding**:
    - `sy_call` → auth rebase pointer to cave (diversity=0xBCAD, key=IA, addrDiv=0)
    - `sy_munge32` → `_munge_wwwwwwww` (if resolved, same encoding)
    - return type + arg metadata (non-pointer fields, written directly).

## Root cause analysis (completed)

Three bugs were identified, all contributing to the NOT_BOOT failure:

### Bug 1: Wrong sysent table base (CRITICAL)

The old code searched DATA segments for the first entry whose decoded pointer matched
`_nosys` and treated that as `sysent[0]`. But in XNU, entry 0 is the **indirect syscall
handler** (`sub_FFFFFE00080073B0`, calls audit then returns ENOSYS) — NOT the simple
`_nosys` function (`sub_FFFFFE0007F6901C`, just returns 78).

The first `_nosys` match appeared **428 entries** into the table:
- Old (wrong) sysent base: file 0x73E078, VA 0xFFFFFE0007742078
- Real sysent base: file 0x73B858, VA 0xFFFFFE000773F858

This meant the patcher was writing to `sysent[439+428] = sysent[867]`, which is way
past the end of the 558-entry table. The patcher was corrupting unrelated DATA.

**Verification via IDA:**
- Syscall dispatch function `sub_FFFFFE00081279E4` uses `off_FFFFFE000773F858` as
  the sysent base: `v26 = &off_FFFFFE000773F858[3 * v25]` (3 qwords = 24 bytes/entry).
- Dispatch caps syscall number at 0x22E (558 entries max).
- Real `sysent[439]` at VA 0xFFFFFE0007742180 has `sy_call` = `sub_FFFFFE0008077978`
  (returns 45 / ENOTSUP = `kas_info` stub).

**Fix:** After finding any `_nosys` match, scan backward in 24-byte steps. Each step
validates: (a) `sy_call` decodes to a code range, (b) metadata fields are reasonable
(`narg ≤ 12`, `arg_bytes ≤ 96`). Stop when validation fails or segment boundary reached.
Limited to 558 entries max to prevent runaway scanning.

### Bug 2: Raw VA written to chained fixup pointer (CRITICAL)

The old code wrote `struct.pack("<Q", cave_va)` — a raw 8-byte virtual address — to
`sysent[439].sy_call`. On arm64e kernelcaches, DATA segment pointers use **chained fixup
encoding**, not raw VAs:

```
DYLD_CHAINED_PTR_64_KERNEL_CACHE auth rebase:
  bit[63]:     isAuth = 1
  bits[62:51]: next (12 bits, 4-byte stride delta to next fixup)
  bits[50:49]: key (0=IA, 1=IB, 2=DA, 3=DB)
  bit[48]:     addrDiv (1 = address-diversified)
  bits[47:32]: diversity (16-bit PAC discriminator)
  bits[31:30]: cacheLevel (0 for single-level)
  bits[29:0]:  target (file offset)
```

Writing a raw VA (e.g., `0xFFFFFE0007AB5720`) produces:
- `isAuth=1` (bit63 of kernel VA is 1)
- `next`, `key`, `addrDiv`, `diversity` = **garbage** from VA bits
- `target` = bits[31:0] of VA = wrong file offset

This corrupts the chained fixup chain from `sysent[439]` onward, silently breaking
all subsequent syscall entries. This explains the NOT_BOOT timeout: no panic because
the corruption doesn't hit early boot syscalls, but init and daemons use corrupted
handlers.

**Fix:** Implemented `_encode_chained_auth_ptr()` that properly encodes:
- `target` = cave file offset (bits[29:0])
- `diversity` = 0xBCAD (bits[47:32])
- `key` = 0/IA (bits[50:49])
- `addrDiv` = 0 (bit[48])
- `next` = preserved from original entry (bits[62:51])
- `isAuth` = 1 (bit[63])

### Bug 3: Missing PAC signing parameters

The syscall dispatch at `0xFFFFFE0008127CC8`:
```asm
MOV  X17, #0xBCAD
BLRAA X8, X17        ; PAC-authenticated indirect call
```

ALL syscall `sy_call` pointers are called via `BLRAA X8, X17` with fixed discriminator
`X17 = 0xBCAD`. The chained fixup resolver PAC-signs each pointer during boot according
to its metadata (diversity, key, addrDiv). For the dispatch to authenticate correctly:
- `diversity` must be `0xBCAD`
- `key` must be `0` (IA, matching BLRAA = key A)
- `addrDiv` must be `0` (fixed discriminator, not address-blended)

The old code didn't set any of these — the raw VA had garbage metadata, so the
fixup resolver would PAC-sign with wrong parameters, causing BLRAA to fail at runtime.

**Fix:** `_encode_chained_auth_ptr()` sets all three fields correctly.

### Non-issue: BLR X16 in shellcode

The shellcode uses `BLR X16` (raw indirect branch without PAC authentication) to call
the user-provided kernel function pointer. This is correct:
- `BLR Xn` strips PAC bits and branches to the resulting address
- It does NOT authenticate — so it works regardless of whether the pointer is PAC-signed
- The kernel function pointer is provided from userspace (raw VA), so no PAC involved

### Note: Missing `_munge_wwwwwwww`

The symbol `_munge_wwwwwwww` was not found in this kernelcache. Without the munge
function, the kernel won't marshal 32-bit userspace arguments for this syscall.
This is only relevant for 32-bit callers; 64-bit callers pass arguments directly
and should work fine. The `sy_munge32` field is left unpatched (original value).

## Sysent table structure
```
struct sysent {
    sy_call_t   *sy_call;        // +0:  function pointer (8 bytes, chained fixup)
    munge_t     *sy_arg_munge32; // +8:  argument munge function (8 bytes, chained fixup)
    int32_t      sy_return_type; // +16: return type (4 bytes, plain int)
    int16_t      sy_narg;        // +20: number of arguments (2 bytes, plain int)
    uint16_t     sy_arg_bytes;   // +22: argument byte count (2 bytes, plain int)
};  // total: 24 bytes per entry, max 558 entries (0x22E)
```

## Key addresses (corrected)
- Dispatch function: VA 0xFFFFFE00081279E4 (`sub_FFFFFE00081279E4`)
- Real sysent base: file 0x73B858, VA 0xFFFFFE000773F858 (`off_FFFFFE000773F858`)
- Old (wrong) sysent base: file 0x73E078, VA 0xFFFFFE0007742078 (428 entries in)
- Real sysent[439]: file 0x73E180, VA 0xFFFFFE0007742180
  - Original `sy_call` = `sub_FFFFFE0008077978` (returns 45/ENOTSUP = kas_info stub)
- Old (wrong) sysent[439]: file 0x7409A0, VA 0xFFFFFE00077449A0 (actually entry 867)
- Code cave: file 0xAB1720, VA 0xFFFFFE0007AB5720 (in __TEXT_EXEC)
- `_nosys`: `sub_FFFFFE0007F6901C` (file offset 0xF6501C), returns 78/ENOSYS

## Chained fixup data (from IDA analysis)
```
Dispatch sysent[0]:   sy_call = sub_FFFFFE00080073B0 (indirect syscall, audit+ENOSYS)
                      sy_munge32 = NULL, ret=1, narg=0, bytes=0
Dispatch sysent[1]:   sy_call = sub_FFFFFE0007FB0B6C (exit)
                      sy_munge32 = sub_FFFFFE0007C6AC2C, ret=0, narg=1, bytes=4
Dispatch sysent[439]: sy_call = sub_FFFFFE0008077978 (kas_info, returns ENOTSUP)
                      sy_munge32 = sub_FFFFFE0007C6AC4C, ret=1, narg=3, bytes=12
```

## Expected outcome
- Replace syscall 439 handler with arbitrary 10-arg kernel call trampoline.
- Proper chained fixup encoding preserves the fixup chain for all subsequent entries.
- PAC signing with diversity=0xBCAD matches the dispatch's BLRAA authentication.

## Risk
- Syscall table rewrite is invasive, but proper chained fixup encoding and chain
  preservation should make it safe.
- Code cave in __TEXT_EXEC is within the KTRR-protected region — already validated
  as executable in C23 testing.
