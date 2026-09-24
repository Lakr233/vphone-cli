# TXM Selector 24 — Full Chain Analysis

## Overview

This document maps the complete TXM code signature validation chain for selector 24,
from the top-level entry point down to the hash extraction functions. IDA base for
this analysis: `0xfffffff017020000` (VA = raw_offset + `0xfffffff017004000`).

## Return Code Convention

TXM uses a multi-byte return code convention:

| Byte    | Purpose                                          |
| ------- | ------------------------------------------------ |
| Byte 0  | Check identity (e.g., `0xA1` = check_hash_flags) |
| Byte 1  | Error indicator: `0x00` = pass, non-zero = fail  |
| Byte 2+ | Additional error info                            |

The caller checks `(result & 0xFF00) == 0` — if byte 1 is zero, the check passed.

**Important**: The previous `txm_selector24_analysis.md` had SUCCESS/ERROR labels
**swapped**. Corrected mappings:

| Return Value | Byte 1 | Meaning in Caller | Description               |
| ------------ | ------ | ----------------- | ------------------------- |
| `0xA1`       | `0x00` | **PASS**          | Hash check passed         |
| `0x130A1`    | `0x30` | **FAIL**          | Hash consistency mismatch |
| `0x22DA1`    | `0x2D` | **FAIL**          | Hash flags type violation |

The panic log `selector: 24 | 0xA1 | 0x30 | 1` decodes to return code `0x130A1`.

---

## Full Call Chain

```
cs_evaluate (0xfffffff017024834)
  |
  +-- cs_blob_init (0xfffffff0170356D8)
  |     Parse CS blob, extract hash, setup entitlements
  |
  +-- cs_determine_selector (0xfffffff0170358C0)
  |     Determine selector byte (written to ctx+161)
  |     Also calls hash_flags_extract internally
  |
  +-- cs_selector24_validate (0xfffffff0170359E0)
        Sequential validation chain (8 checks + type switch):
        |
        |  Each check returns low-byte-only (0xNN) on PASS,
        |  multi-byte (0xNNNNN) on FAIL. Chain stops on first FAIL.
        |
        +-- [1] check_library_validation  (0x...5594)  ret 0xA9 on pass
        +-- [2] check_runtime_flag        (0x...552C)  ret 0xA8 on pass
        +-- [3] check_jit_entitlement     (0x...5460)  ret 0xA0 on pass
        +-- [4] check_hash_flags          (0x...5398)  ret 0xA1 on pass  <<<< PATCH TARGET
        +-- [5] check_team_id             (0x...52F4)  ret 0xA2 on pass
        +-- [6] check_srd_entitlement     (0x...5254)  ret 0xAA on pass
        +-- [7] check_extended_research   (0x...51D8)  ret 0xAB on pass
        +-- [8] check_hash_type           (0x...5144)  ret 0xAC on pass
        |
        +-- switch(selector_type):
              case 1: sub_...4FC4
              case 2: sub_...4E60
              case 3: sub_...4D60
              case 4: sub_...4CC4
              case 5: (no additional check)
              case 6-10: sub_...504C
```

---

## Check #4: check_hash_flags (0xfffffff017035398)

**This is the function containing both JB patch sites.**

### IDA Addresses → Raw File Offsets

| IDA VA               | Raw Offset | Content                          |
| -------------------- | ---------- | -------------------------------- |
| `0xfffffff017035398` | `0x31398`  | Function start (PACIBSP)         |
| `0xfffffff0170353B0` | `0x313B0`  | `mov x19, x1` (after prologue)   |
| `0xfffffff0170353CC` | `0x313CC`  | PATCH 1: `ldr x1, [x20, #0x38]`  |
| `0xfffffff0170353D4` | `0x313D4`  | PATCH 2: `bl hash_flags_extract` |
| `0xfffffff017035418` | `0x31418`  | `mov w0, #0x30A1; movk ...#1`    |
| `0xfffffff017035420` | `0x31420`  | Exit path (LDP epilogue)         |
| `0xfffffff017035454` | `0x31454`  | `mov w0, #0x2DA1; movk ...#2`    |

### Decompiled Pseudocode

```c
// IDA: check_hash_flags  @ 0xfffffff017035398
// Raw: 0x31398, Size: 0xC8
//
// a1 = CS context pointer (x0)
// a2 = selector_type (x1, from ctx+161)
//
uint32_t check_hash_flags(cs_ctx **a1, uint32_t a2) {
    void *chain = **a1;                         // 0x353B8-0x353BC

    uint32_t flags = 0;                         // 0x353C4: str wzr, [sp, #4]
    uint64_t hash_data = 0;                     // 0x353C0: str xzr, [sp, #8]

    // Extract hash flags from CS blob
    hash_flags_extract(a1[6], a1[7], &flags);   // 0x353C8-0x353D4
    //                  ^^^^   ^^^^
    //               cs_blob  cs_size
    //   PATCH 1 @ 0x353CC: loads cs_size into x1
    //   PATCH 2 @ 0x353D4: calls hash_flags_extract

    // Extract hash data pointer from CS blob
    hash_data_extract(a1[6], a1[7], &hash_data); // 0x353D8-0x353E0

    // --- Decision logic ---

    // High-type shortcut: type >= 6 with chain data → pass
    if (a2 >= 6 && *(uint64_t*)(chain + 8) != 0)
        return 0xA1;  // PASS

    // Consistency check: hash data presence vs flag bit 1
    //   flag bit 1 = "hash data exempt" (when set, no hash data expected)
    bool has_data = (hash_data != 0);
    bool exempt   = (flags >> 1) & 1;

    if (has_data == exempt)
        return 0x130A1;  // FAIL — inconsistent (data exists but exempt, or vice versa)

    // Type-specific logic
    if (a2 > 5)
        return 0xA1;  // PASS — types 6+ always pass here

    if (a2 == 1 || a2 == 2) {
        if (exempt)
            return 0xA1;   // PASS — type 1-2 with exempt flag
        return 0x22DA1;    // FAIL — type 1-2 must have exempt flag
    }

    // Types 3-5
    if (!exempt)
        return 0xA1;       // PASS — type 3-5 without exempt
    return 0x22DA1;        // FAIL — type 3-5 must not be exempt
}
```

### Assembly (Complete)

```
0x31398:  pacibsp
0x3139C:  sub   sp, sp, #0x40
0x313A0:  stp   x22, x21, [sp, #0x10]
0x313A4:  stp   x20, x19, [sp, #0x20]
0x313A8:  stp   x29, x30, [sp, #0x30]
0x313AC:  add   x29, sp, #0x30
0x313B0:  mov   x19, x1              ; x19 = selector_type
0x313B4:  mov   x20, x0              ; x20 = cs_ctx
0x313B8:  ldr   x8, [x0]             ; x8 = *ctx
0x313BC:  ldr   x21, [x8]            ; x21 = **ctx (chain)
0x313C0:  str   xzr, [sp, #8]        ; hash_data = 0
0x313C4:  str   wzr, [sp, #4]        ; flags = 0
0x313C8:  ldr   x0, [x0, #0x30]      ; x0 = ctx->cs_blob
0x313CC:  ldr   x1, [x20, #0x38]     ; x1 = ctx->cs_size      <<< PATCH 1
0x313D0:  add   x2, sp, #4           ; x2 = &flags
0x313D4:  bl    hash_flags_extract   ;                         <<< PATCH 2
0x313D8:  ldp   x0, x1, [x20, #0x30] ; reload blob + size
0x313DC:  add   x2, sp, #8           ; x2 = &hash_data
0x313E0:  bl    hash_data_extract    ;
0x313E4:  ldr   w8, [sp, #4]         ; w8 = flags
0x313E8:  cmp   w19, #6
0x313EC:  b.lo  0x31400
0x313F0:  ldr   x9, [x21, #8]
0x313F4:  cbz   x9, 0x31400
0x313F8:  mov   w0, #0xA1            ; PASS
0x313FC:  b     0x31420              ; → exit
0x31400:  and   w8, w8, #2           ; flags & 2
0x31404:  ldr   x9, [sp, #8]         ; hash_data
0x31408:  cmp   x9, #0
0x3140C:  cset  w9, ne               ; has_data = (hash_data != 0)
0x31410:  cmp   w9, w8, lsr #1       ; has_data vs exempt
0x31414:  b.ne  0x31434              ; mismatch → continue checks
0x31418:  mov   w0, #0x30A1          ; FAIL (0x130A1)
0x3141C:  movk  w0, #1, lsl #16
0x31420:  ldp   x29, x30, [sp, #0x30] ; EXIT
0x31424:  ldp   x20, x19, [sp, #0x20]
0x31428:  ldp   x22, x21, [sp, #0x10]
0x3142C:  add   sp, sp, #0x40
0x31430:  retab
0x31434:  cmp   w19, #5
0x31438:  b.hi  0x313F8              ; type > 5 → PASS
0x3143C:  sub   w9, w19, #1
0x31440:  cmp   w9, #1
0x31444:  b.hi  0x31450              ; type > 2 → check 3-5
0x31448:  cbnz  w8, 0x313F8          ; type 1-2 + exempt → PASS
0x3144C:  b     0x31454
0x31450:  cbz   w8, 0x313F8          ; type 3-5 + !exempt → PASS
0x31454:  mov   w0, #0x2DA1          ; FAIL (0x22DA1)
0x31458:  movk  w0, #2, lsl #16
0x3145C:  b     0x31420              ; → exit
```

---

## Sub-function: hash_flags_extract (0xfffffff0170335D8)

**Raw offset: 0x2F5D8, Size: 0x40**

```c
// Extracts 32-bit hash flags from CS blob at offset 0xC (big-endian)
uint32_t hash_flags_extract(uint8_t *blob, uint32_t size, uint32_t *out) {
    if (!out)
        return 0x31;  // no output pointer, noop

    if (blob + 44 <= blob + size) {
        // Blob is large enough
        *out = bswap32(*(uint32_t*)(blob + 12));  // flags at offset 0xC
        return 0x31;
    }

    // Blob too small — error
    return error_handler(25);
}
```

## Sub-function: hash_data_extract (0xfffffff0170336F8)

**Raw offset: 0x2F6F8, Size: 0xA8**

```c
// Extracts hash data pointer from CS blob
// Reads offset at blob+48 (big-endian), validates bounds, finds null-terminated data
uint32_t hash_data_extract(uint8_t *blob, uint32_t size, uint64_t *out) {
    uint8_t *end = blob + size;

    if (blob + 44 > end)
        goto bounds_error;

    // Check version field at blob+8
    if (bswap32(*(uint32_t*)(blob + 8)) >> 9 < 0x101)
        return 0x128B9;  // version too low

    if (blob + 52 > end)
        goto bounds_error;

    uint32_t offset_raw = *(uint32_t*)(blob + 48);
    if (!offset_raw)
        return 0x224B9;  // no hash data (offset = 0)

    uint32_t offset = bswap32(offset_raw);
    uint8_t *data = blob + offset;

    if (data < blob || data >= end)
        goto bounds_error;

    // Find null terminator
    uint8_t *scan = data + 1;
    while (scan <= end) {
        if (*(scan - 1) == 0) {
            *out = (uint64_t)data;
            return 0x39;
        }
        scan++;
    }

bounds_error:
    return error_handler(25);
}
```

---

## Caller: cs_selector24_validate (0xfffffff0170359E0)

```c
uint32_t cs_selector24_validate(cs_ctx *a1) {
    uint8_t selector_type = *(uint8_t*)((char*)a1 + 161);

    if (!selector_type)
        return 0x10503;  // no selector set

    if (*((uint8_t*)a1 + 162))
        return 0x23403;  // already validated

    uint32_t r;

    r = check_library_validation(*a1, selector_type);
    if ((r & 0xFF00) != 0) return r;

    r = check_runtime_flag(*a1, selector_type);
    if ((r & 0xFF00) != 0) return r;

    r = check_jit_entitlement(a1, selector_type);
    if ((r & 0xFF00) != 0) return r;

    r = check_hash_flags(a1, selector_type);   // <<<< CHECK #4
    if ((r & 0xFF00) != 0) return r;

    r = check_team_id(a1);
    if ((r & 0xFF00) != 0) return r;

    r = check_srd_entitlement(a1);
    if ((r & 0xFF00) != 0) return r;

    r = check_extended_research(a1);
    if ((r & 0xFF00) != 0) return r;

    r = check_hash_type(a1);
    if ((r & 0xFF00) != 0) return r;

    // All pre-checks passed — now type-specific validation
    switch (selector_type) {
        case 1: r = validate_type1(a1); break;
        case 2: r = validate_type2(a1); break;
        case 3: r = validate_type3(a1); break;
        case 4: r = validate_type4(a1); break;
        case 5: /* no extra check */ break;
        case 6..10: r = validate_type6_10(a1, selector_type); break;
        default: return 0x40103;
    }

    if ((r & 0xFF00) != 0) return r;

    // Mark as validated
    *((uint8_t*)a1 + 162) = selector_type;
    return 3;  // success
}
```

---

## Top-level: cs_evaluate (0xfffffff017024834)

```c
uint64_t cs_evaluate(cs_session *session) {
    update_state(session, 1, 0);

    if (session->flags & 1) {
        log_error(80, 0);
        goto fatal;
    }

    cs_ctx *ctx = &session->ctx;

    uint32_t r = cs_blob_init(ctx);
    if (BYTE1(r)) goto handle_error;

    r = cs_determine_selector(ctx, NULL);
    if (BYTE1(r)) goto handle_error;

    r = cs_selector24_validate(ctx);
    if (!BYTE1(r)) {
        // Success — return 0
        finalize(session, 1);
        return 0 | (packed_status);
    }
    // ... error handling ...
}
```

---

## Validation Sub-check Details

### [1] check_library_validation (ret 0xA9)

Checks library validation flag. If `*(*a1 + 5) & 1` and selector not in [7..10], returns `0x130A9` (fail).

### [2] check_runtime_flag (ret 0xA8)

For selector <= 5: checks runtime hardened flag via function pointer at `a1[1]()`.
Returns `0x130A8` if runtime enabled and runtime flag set.

### [3] check_jit_entitlement (ret 0xA0)

Checks `com.apple.developer.cs.allow-jit` and `com.apple.developer.web-browser-engine.webcontent`
entitlements. For selector <= 5, also checks against a list of 4 platform entitlements.

### [4] check_hash_flags (ret 0xA1) — PATCH TARGET

See detailed analysis above.

### [5] check_team_id (ret 0xA2)

Checks team ID against 6 known Apple team IDs using entitlement lookup functions.

### [6] check_srd_entitlement (ret 0xAA)

Checks `com.apple.private.security-research-device` entitlement.

### [7] check_extended_research (ret 0xAB)

Checks `com.apple.private.security-research-device.extended-research-mode` entitlement.

### [8] check_hash_type (ret 0xAC)

Re-extracts hash data and validates hash algorithm type via `sub_FFFFFFF01702EDF4`.

---

## Why the NOP Patches Failed

### Test results:

| Patch 1 (NOP LDR) | Patch 2 (NOP BL) | Result    |
| ----------------- | ---------------- | --------- |
| OFF               | OFF              | **Boots** |
| ON                | OFF              | Panic     |
| OFF               | ON               | Panic     |
| ON                | ON               | Panic     |

### Root cause analysis:

**With no patches (dev-only)**: The function runs normally. For our binaries:

- `hash_flags_extract` returns proper flags from CS blob
- `hash_data_extract` returns the hash data pointer
- The consistency check `has_data == exempt` evaluates to `1 == 0` (has data, not exempt) → **mismatch** → passes (B.NE taken)
- The type-specific logic returns 0xA1 (pass)

**NOP LDR only (Patch 1)**: `x1` retains the value of `a2` (selector type, a small number like 5 or 10) instead of `cs_size` (the actual blob size). When `hash_flags_extract` runs, the bounds check `blob + 44 <= blob + size` uses the wrong size. If `a2 < 44`, the check fails → error path → `flags` stays 0. Then `exempt = 0`, and if `has_data = 1` → mismatch passes, but later type-specific logic with `(flags & 2) == 0` may return `0x22DA1` (FAIL) depending on selector type.

**NOP BL only (Patch 2)**: `hash_flags_extract` never runs → `flags = 0` (initialized to 0). So `exempt = 0`. If hash data exists (`has_data = 1`), consistency check passes (mismatch: `1 != 0`). But then:

- For type 1-2: `(flags & 2) == 0` → returns `0x22DA1` **FAIL**
- For type 3-5: `(flags & 2) == 0` → returns `0xA1` **PASS**
- For type > 5: returns `0xA1` **PASS**

So if the binary's selector type is 1 or 2, NOP'ing the BL causes failure.

**Both patches**: Similar to NOP BL — `hash_flags_extract` is NOP'd so flags=0, but NOP LDR also corrupts x1 (which is unused since BL is also NOP'd, so no effect). Net result same as NOP BL only.

**Conclusion**: The patches were **counterproductive**. The function already returns PASS for legitimately signed binaries with dev patches. The NOPs corrupt state and cause it to FAIL.

---

## Correct Patch Strategy (for future unsigned code)

When JB payloads run unsigned/modified code, `check_hash_flags` may legitimately fail.
The correct fix is to make it always return `0xA1` (PASS).

### Recommended: Early-return after prologue

Patch 2 instructions at raw offset `0x313B0`:

```
BEFORE:
  0x313B0:  mov x19, x1          (E1 03 17 AA → actually this encodes to different bytes)
  0x313B4:  mov x20, x0

AFTER:
  0x313B0:  mov w0, #0xa1        (20 14 80 52)
  0x313B4:  b   +0x6C            (1B 00 00 14)  → jumps to exit at 0x31420
```

The prologue (0x31398-0x313AC) has already saved all callee-saved registers.
The exit path at 0x31420 restores them and does RETAB. This is safe.

### Alternative: Patch error returns to PASS

Replace both error-returning MOVs with the PASS value:

```
0x31418:  mov w0, #0xA1    (20 14 80 52)     was: mov w0, #0x30A1
0x3141C:  nop              (1F 20 03 D5)     was: movk w0, #1, lsl #16
0x31454:  mov w0, #0xA1    (20 14 80 52)     was: mov w0, #0x2DA1
0x31458:  nop              (1F 20 03 D5)     was: movk w0, #2, lsl #16
```

This preserves the original logic flow but makes all paths return PASS.

---

## Current Status

The 2 JB TXM patches (`patch_selector24_hash_extraction_nop`) are **disabled** (commented out in `txm_jb.py`). The JB variant now boots identically to dev for TXM validation. When unsigned code execution is needed, apply one of the recommended patches above.
