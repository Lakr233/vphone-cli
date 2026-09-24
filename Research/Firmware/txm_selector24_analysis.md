# TXM Selector24 CS Hash Extraction — Patch Analysis

## Problem

Original JB TXM patches (2 NOPs in selector24 handler) cause kernel panic:

```
TXM [Error]: CodeSignature: selector: 24 | 0xA1 | 0x30 | 1
panic: unexpected SIGKILL of init with reason -- namespace 9 code 0x1
```

Both patches individually cause the panic. With both disabled (= dev only), boot succeeds.

## The Function

- Raw offset: `0x031398`
- IDA address (base `0xFFFFFFF017004000`): `0xFFFFFFF017035398`

Selector24 CS hash-flags validation function. Takes a context struct (x0) and a hash type (x1).

### Disassembly

```
0x031398:  pacibsp
0x03139C:  sub        sp, sp, #0x40
0x0313A0:  stp        x22, x21, [sp, #0x10]
0x0313A4:  stp        x20, x19, [sp, #0x20]
0x0313A8:  stp        x29, x30, [sp, #0x30]
0x0313AC:  add        x29, sp, #0x30
0x0313B0:  mov        x19, x1              ; x19 = hash_type arg
0x0313B4:  mov        x20, x0              ; x20 = context struct
0x0313B8:  ldr        x8, [x0]             ; x8 = ctx->chain_ptr
0x0313BC:  ldr        x21, [x8]            ; x21 = *ctx->chain_ptr
0x0313C0:  str        xzr, [sp, #8]        ; local_hash_result = 0
0x0313C4:  str        wzr, [sp, #4]        ; local_flags = 0
0x0313C8:  ldr        x0, [x0, #0x30]      ; x0 = ctx->cs_blob         (a1[6])
0x0313CC:  ldr        x1, [x20, #0x38]     ; x1 = ctx->cs_blob_size    (a1[7])
0x0313D0:  add        x2, sp, #4           ; x2 = &local_flags
0x0313D4:  bl         #0x2f5d8             ; hash_flags_extract(blob, size, &flags)
0x0313D8:  ldp        x0, x1, [x20, #0x30] ; reload blob + size
0x0313DC:  add        x2, sp, #8           ; x2 = &local_hash_result
0x0313E0:  bl         #0x2f6f8             ; cs_blob_get_hash(blob, size, &result)
0x0313E4:  ldr        w8, [sp, #4]         ; w8 = flags
0x0313E8:  cmp        w19, #6              ; if hash_type >= 6 ...
0x0313EC:  b.lo       #0x31400
0x0313F0:  ldr        x9, [x21, #8]        ;   check table->field_8
0x0313F4:  cbz        x9, #0x31400         ;   if field_8 != 0:
0x0313F8:  mov        w0, #0xa1            ;     RETURN 0xa1 (ERROR!)
0x0313FC:  b          #0x31420
0x031400:  and        w8, w8, #2           ; flags_bit1 = flags & 2
0x031404:  ldr        x9, [sp, #8]         ; hash_result
0x031408:  cmp        x9, #0
0x03140C:  cset       w9, ne               ; has_result = (hash_result != 0)
0x031410:  cmp        w9, w8, lsr #1       ; if has_result == flags_bit1:
0x031414:  b.ne       #0x31434
0x031418:  mov        w0, #0x30a1          ;   RETURN 0x130a1 (SUCCESS)
0x03141C:  movk       w0, #1, lsl #16
0x031420:  ldp        x29, x30, [sp, #0x30]
0x031424:  ldp        x20, x19, [sp, #0x20]
0x031428:  ldp        x22, x21, [sp, #0x10]
0x03142C:  add        sp, sp, #0x40
0x031430:  retab
0x031434:  cmp        w19, #5              ; further checks based on type
0x031438:  b.hi       #0x313f8             ; type > 5 → return 0xa1
0x03143C:  sub        w9, w19, #1
0x031440:  cmp        w9, #1
0x031444:  b.hi       #0x31450             ; type > 2 → goto other
0x031448:  cbnz       w8, #0x313f8         ; type 1-2: flags_bit1 set → 0xa1
0x03144C:  b          #0x31454
0x031450:  cbz        w8, #0x313f8         ; type 3-5: flags_bit1 clear → 0xa1
0x031454:  mov        w0, #0x2da1          ; RETURN 0x22da1 (SUCCESS variant)
0x031458:  movk       w0, #2, lsl #16
0x03145C:  b          #0x31420
```

### IDA Pseudocode

```c
__int64 __fastcall sub_FFFFFFF017035398(__int64 **a1, unsigned int a2)
{
  __int64 v4; // x21
  int v6; // [xsp+4h] [xbp-2Ch] BYREF   — flags
  __int64 v7; // [xsp+8h] [xbp-28h] BYREF — hash_result

  v4 = **a1;
  v7 = 0;
  v6 = 0;
  sub_FFFFFFF0170335D8(a1[6], a1[7], &v6);   // hash_flags_extract
  sub_FFFFFFF0170336F8(a1[6], a1[7], &v7);   // cs_blob_get_hash
  if ( a2 >= 6 && *(_QWORD *)(v4 + 8) )
    return 161;                               // 0xA1 — ERROR
  if ( (v7 != 0) == (unsigned __int8)(v6 & 2) >> 1 )
    return 77985;                             // 0x130A1 — SUCCESS
  if ( a2 > 5 )
    return 161;
  if ( a2 - 1 <= 1 )
  {
    if ( (v6 & 2) == 0 )
      return 142753;                          // 0x22DA1 — SUCCESS variant
    return 161;
  }
  if ( (v6 & 2) == 0 )
    return 161;
  return 142753;
}
```

### Annotated Pseudocode

```c
// selector24 handler: validates CS blob hash flags consistency
int selector24_validate(struct cs_context **ctx, uint32_t hash_type) {
    void *table = **ctx;
    int flags = 0;
    int64_t hash_ptr = 0;

    void *cs_blob    = ctx[6];   // ctx + 0x30
    uint32_t cs_size = ctx[7];   // ctx + 0x38

    // ① Extract hash flags from CS blob offset 0xC (big-endian)
    hash_flags_extract(cs_blob, cs_size, &flags);

    // ② Get hash data pointer from CS blob
    cs_blob_get_hash(cs_blob, cs_size, &hash_ptr);

    // ③ type >= 6 with table data → PASS (early out)
    if (hash_type >= 6 && *(table + 8) != 0)
        return 0xA1;               // PASS (byte 1 = 0)

    // ④ Core consistency: hash existence must match flags bit 1
    bool has_hash  = (hash_ptr != 0);
    bool flag_bit1 = (flags & 2) >> 1;

    if (has_hash == flag_bit1)
        return 0x130A1;            // FAIL (byte 1 = 0x30) ← panic trigger!

    // ⑤ Inconsistent — type-specific handling
    if (hash_type > 5)  return 0xA1;      // PASS
    if (hash_type == 1 || hash_type == 2) {
        if (!(flags & 2)) return 0x22DA1;  // FAIL (byte 1 = 0x2D)
        return 0xA1;                       // PASS
    }
    // type 3-5
    if (flags & 2) return 0x22DA1;          // FAIL
    return 0xA1;                            // PASS
}
```

## hash_flags_extract (0x02F5D8 / IDA 0xFFFFFFF0170335D8)

```
0x02F5D8:  bti        c
0x02F5DC:  cbz        x2, #0x2f5fc         ; if out_ptr == NULL, skip
0x02F5E0:  add        x8, x0, w1, uxtw     ; end = blob + size
0x02F5E4:  add        x9, x0, #0x2c        ; min_end = blob + 0x2c
0x02F5E8:  cmp        x9, x8               ; if blob too small:
0x02F5EC:  b.hi       #0x2f604             ;   goto error
0x02F5F0:  ldr        w8, [x0, #0xc]       ; raw_flags = blob[0xc] (big-endian)
0x02F5F4:  rev        w8, w8               ; flags = bswap32(raw_flags)
0x02F5F8:  str        w8, [x2]             ; *out_ptr = flags
0x02F5FC:  mov        w0, #0x31            ; return 0x31 (success)
0x02F600:  ret
```

Reads a 32-bit big-endian flags field from cs_blob offset 0xC, byte-swaps, stores to output.

## cs_blob_get_hash (0x02F6F8 / IDA 0xFFFFFFF0170336F8)

```
0x02F6F8:  pacibsp
0x02F6FC:  stp        x29, x30, [sp, #-0x10]!
0x02F700:  mov        x29, sp
0x02F704:  add        x8, x0, w1, uxtw     ; end = blob + size
0x02F708:  add        x9, x0, #0x2c        ; min_end = blob + 0x2c
0x02F70C:  cmp        x9, x8
0x02F710:  b.hi       #0x2f798             ; blob too small → error
0x02F714:  ldr        w9, [x0, #8]
0x02F718:  rev        w9, w9
0x02F71C:  lsr        w9, w9, #9
0x02F720:  cmp        w9, #0x101
0x02F724:  b.hs       #0x2f734
0x02F728:  mov        w0, #0x2839          ; version too old → error
0x02F72C:  movk       w0, #1, lsl #16
0x02F730:  b          #0x2f790
0x02F734:  add        x9, x0, #0x34
0x02F738:  cmp        x9, x8
0x02F73C:  b.hi       #0x2f798
0x02F740:  ldr        w9, [x0, #0x30]      ; hash_offset (big-endian)
0x02F744:  cbz        w9, #0x2f788         ; no hash → return special
0x02F748:  cbz        x2, #0x2f780         ; no output ptr → skip
0x02F74C:  rev        w10, w9
0x02F750:  add        x9, x0, x10          ; hash_ptr = blob + bswap(hash_offset)
0x02F754:  cmp        x9, x0               ; bounds check
0x02F758:  ccmp       x9, x8, #2, hs
0x02F75C:  b.hs       #0x2f798
0x02F760:  add        x10, x10, x0
0x02F764:  add        x10, x10, #1
0x02F768:  cmp        x10, x8
0x02F76C:  b.hi       #0x2f798
0x02F770:  ldurb      w11, [x10, #-1]      ; scan for NUL terminator
0x02F774:  add        x10, x10, #1
0x02F778:  cbnz       w11, #0x2f768
0x02F77C:  str        x9, [x2]             ; *out_ptr = hash_ptr
0x02F780:  mov        w0, #0x39            ; return 0x39 (success)
0x02F784:  b          #0x2f790
0x02F788:  mov        w0, #0x2439          ; return 0x22439 (no hash)
0x02F78C:  movk       w0, #2, lsl #16
0x02F790:  ldp        x29, x30, [sp], #0x10
0x02F794:  retab
0x02F798:  mov        w0, #0x19            ; error → panic/abort
0x02F79C:  bl         #0x25a74
```

## Why the Original NOP Patches Were Wrong

### PATCH 1 only (NOP ldr x1, [x20, #0x38]):

- x1 retains incoming arg value (hash_type) instead of cs_blob_size
- hash_flags_extract called with WRONG size → garbage flags or OOB
- Consistency check fails → 0xA1

### PATCH 2 only (NOP bl hash_flags_extract):

- flags stays 0 (initialized at 0x0313C4)
- hash_result from second BL is non-zero (valid hash exists)
- flags_bit1 = 0, has_result = 1 → mismatch
- For type > 5 → return 0xA1

### Both patches disabled:

- Function runs normally, hash_flags_extract extracts correct flags
- flags_bit1 matches has_result → returns 0x130A1 (success)
- Boot succeeds (same as dev variant)

## Return Code Semantics (CORRECTED)

The caller checks return values via `tst w0, #0xff00; b.ne <error>`:

- **0xA1** (byte 1 = 0x00) → **PASS** — `0xA1 & 0xFF00 = 0` → continues
- **0x130A1** (byte 1 = 0x30) → **FAIL** — `0x130A1 & 0xFF00 = 0x3000` → branches to error
- **0x22DA1** (byte 1 = 0x2D) → **FAIL** — `0x22DA1 & 0xFF00 = 0x2D00` → branches to error

The initial fix attempt (returning 0x130A1) was wrong — it returned a FAIL code.

### Caller context (0x031A60)

```
0x031A4C: bl         #0x31460           ; call previous validator
0x031A50: tst        w0, #0xff00        ; check byte 1
0x031A54: b.ne       #0x31b44           ; non-zero → error path
0x031A58: mov        x0, x19
0x031A5C: mov        x1, x20
0x031A60: bl         #0x31398           ; call selector24_validate (our target)
0x031A64: tst        w0, #0xff00        ; check byte 1
0x031A68: b.ne       #0x31b44           ; non-zero → error path
```

## Fix Applied

Insert `mov w0, #0xa1; b <epilogue>` after the prologue, returning PASS immediately:

```asm
;; prologue (preserved — sets up stack frame for clean epilogue)
0x031398:  pacibsp
0x03139C:  sub        sp, sp, #0x40
0x0313A0:  stp        x22, x21, [sp, #0x10]
0x0313A4:  stp        x20, x19, [sp, #0x20]
0x0313A8:  stp        x29, x30, [sp, #0x30]
0x0313AC:  add        x29, sp, #0x30

;; PATCH: early return with PASS
0x0313B0:  mov        w0, #0xa1          ; return PASS (byte 1 = 0)
0x0313B4:  b          #0x31420           ; jump to epilogue

;; epilogue (existing — restores registers and returns)
0x031420:  ldp        x29, x30, [sp, #0x30]
0x031424:  ldp        x20, x19, [sp, #0x20]
0x031428:  ldp        x22, x21, [sp, #0x10]
0x03142C:  add        sp, sp, #0x40
0x031430:  retab
```

### Patcher implementation (`txm_jb.py`)

Method `patch_selector24_force_pass()`:

- Locator: finds `mov w0, #0xa1`, walks back to PACIBSP, verifies selector24
  characteristic pattern (LDR X1,[Xn,#0x38] / ADD X2 / BL / LDP).
- Finds prologue end dynamically (`add x29, sp, #imm` → next instruction).
- Finds epilogue dynamically (scan for `retab`, walk back to `ldp x29, x30`).
- Patch: 2 instructions after prologue: `mov w0, #0xa1 ; b <epilogue>`.
