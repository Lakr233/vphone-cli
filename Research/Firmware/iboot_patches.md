# iBoot Patch Analysis: iBSS / iBEC / LLB

Analysis of iBoot patches for vresearch101 from PCC-CloudOS 26.3 (23D128).

## Source Files

All six vresearch101 iBoot variants share just two unique **payload** binaries
(after IM4P decode/decompress):

| Variant       | IM4P Size | Raw Size | Payload SHA256 (first 16) | Fourcc |
| ------------- | --------- | -------- | ------------------------- | ------ |
| iBSS RELEASE  | 303068    | 605312   | `4c9e7df663af76fa`        | ibss   |
| iBEC RELEASE  | 303098    | 605312   | `4c9e7df663af76fa`        | ibec   |
| LLB RELEASE   | 303068    | 605312   | `4c9e7df663af76fa`        | illb   |
| iBSS RESEARCH | 308188    | 622512   | `8c3cc980f25f9027`        | ibss   |
| iBEC RESEARCH | 308218    | 622512   | `8c3cc980f25f9027`        | ibec   |
| LLB RESEARCH  | 308188    | 622512   | `8c3cc980f25f9027`        | illb   |

**Key finding:** This "identical" claim is strictly about the decoded payload bytes.
At the IM4P container level, iBSS/iBEC/LLB are still different files (different
fourcc and full-file hashes). Within each build variant (RELEASE or RESEARCH),
the decoded payload bytes are identical.

Mode/stage identity is therefore not encoded as different payload binaries in
these pristine IPSW extracts; it comes from how the boot chain loads and treats
each image.

`fw_patch.py` targets the RELEASE variants, matching the BuildManifest identity
(`PCC RELEASE` for LLB/iBSS/iBEC). The dynamic patcher works on both variants.

> Note: if you compare files under `vm/...` **after** running patch scripts,
> RELEASE payloads will no longer be identical (expected), because mode-specific
> patches are applied to iBEC/LLB.

## Binary Layout

Single flat ROM segment (no Mach-O, no sections):

| Property    | RELEASE           | RESEARCH          |
| ----------- | ----------------- | ----------------- |
| Base VA     | `0x7006C000`      | `0x7006C000`      |
| Size        | 605312 (591.1 KB) | 622512 (607.9 KB) |
| Compression | BVX2 (LZFSE)      | BVX2 (LZFSE)      |
| Encrypted   | No                | No                |

File offset = VA − `0x7006C000`.

## Patch Summary

### Base Patches (`fw_patch.py` via `IBootPatcher`)

| #   | Patch                  | iBSS  | iBEC  |  LLB   | Total |
| --- | ---------------------- | :---: | :---: | :----: | :---: |
| 1   | Serial labels (×2)     |  ✅   |  ✅   |   ✅   |   2   |
| 2   | image4 callback bypass |  ✅   |  ✅   |   ✅   |   2   |
| 3   | Boot-args redirect     |   —   |  ✅   |   ✅   |   3   |
| 4   | Rootfs bypass          |   —   |   —   |   ✅   |   5   |
| 5   | Panic bypass           |   —   |   —   |   ✅   |   1   |
|     | **Subtotal**           | **4** | **7** | **13** |       |

### JB Extension Patch (implemented)

| #   | Patch                               | Base | JB  |
| --- | ----------------------------------- | :--: | :-: |
| 6   | **Skip generate_nonce** (iBSS only) |  —   | ✅  |

Status: implemented in `IBootJBPatcher.patch_skip_generate_nonce()` and applied
by `fw_patch_jb.py` (JB flow). This follows the current pipeline split where
base boot patching stays minimal and nonce control is handled in JB/research flow.

## Patch Details (RELEASE variant, 26.3)

### Patch 1: Serial Labels

**Purpose:** Replace two `===...===` banner strings with descriptive labels for
serial log identification.

**Anchoring:** Find runs of ≥20 `=` characters in the binary. There are exactly
4 such runs, but only the first 2 are the banners (the other 2 are
`"Start of %s serial output"` / `"End of %s serial output"` format strings).

| Patch   | File Offset | VA           | Original   | Patched       |
| ------- | ----------- | ------------ | ---------- | ------------- |
| Label 1 | `0x084549`  | `0x700F0549` | `=====...` | `Loaded iBSS` |
| Label 2 | `0x0845F4`  | `0x700F05F4` | `=====...` | `Loaded iBSS` |

Label text changes per mode: `Loaded iBSS` / `Loaded iBEC` / `Loaded LLB`.

**Containing function:** `sub_7006F71C` (main boot function, ~0x9B4 bytes).

### Patch 2: image4_validate_property_callback

**Purpose:** Force the image4 property validation callback to always return 0
(success), bypassing signature/property verification for all image4 objects.

**Function:** `sub_70075350` (~0xA98 bytes) — the image4 property callback handler.
Dispatches on 4-char property tags (BORD, CHIP, CEPO, CSEC, DICE, BNCH, etc.)
and validates each against expected values.

**Anchoring pattern:**

1. `B.NE` followed immediately by `MOV X0, X22`
2. `CMP` within 8 instructions before the `B.NE`
3. `MOVN W22, #0` or `MOV W22, #-1` (setting error return = -1) within 64 instructions before

The `B.NE` is the stack canary check at the function epilogue. `X22` holds the
computed return value (0 = success, -1 = failure). The patch forces return 0
regardless of validation results.

| Patch       | File Offset | VA           | Original          | Patched      |
| ----------- | ----------- | ------------ | ----------------- | ------------ |
| NOP b.ne    | `0x009D14`  | `0x70075D14` | `B.NE 0x70075E50` | `NOP`        |
| Force ret=0 | `0x009D18`  | `0x70075D18` | `MOV X0, X22`     | `MOV X0, #0` |

**Context (function epilogue):**

```
70075CFC  MOV     W22, #0xFFFFFFFF      ; error return code
70075D00  LDUR    X8, [X29, #var_60]    ; load stack canary
70075D04  ADRL    X9, "160D"            ; expected canary
70075D0C  LDR     X9, [X9]
70075D10  CMP     X9, X8                ; canary check
70075D14  B.NE    loc_70075E50          ; → panic if mismatch  ← NOP
70075D18  MOV     X0, X22              ; return x22           ← MOV X0, #0
70075D1C  LDP     X29, X30, [SP, ...]  ; epilogue
...
70075D38  RETAB
```

### Patch 3: Boot-args (iBEC / LLB only)

**Purpose:** Replace the default boot-args format string `"%s"` with
`"serial=3 -v debug=0x2014e %s"` to enable serial output, verbose boot,
and debug flags.

**Anchoring:**

1. Find `"rd=md0"` string → search nearby for standalone `"%s"` (NUL-terminated)
2. Find `ADRP+ADD X2` pair referencing that `"%s"` offset
3. Write new string to a NUL-padded area, redirect ADRP+ADD to it

| Patch   | File Offset | VA           | Description            |
| ------- | ----------- | ------------ | ---------------------- |
| String  | `0x023F40`  | `0x700D5F40` | New boot-args string   |
| ADRP x2 | `0x0122E0`  | `0x700DE2E0` | Redirect to new page   |
| ADD x2  | `0x0122E4`  | `0x700DE2E4` | Redirect to new offset |

### Patch 4: Rootfs Bypass (LLB only)

**Purpose:** 5 patches that bypass root filesystem signature verification,
allowing modified rootfs to boot.

| #   | File Offset | VA           | Original      | Patched | Anchor                |
| --- | ----------- | ------------ | ------------- | ------- | --------------------- |
| 4a  | `0x02B068`  | `0x700D7068` | `CBZ W0, ...` | `B ...` | error code `0x3B7`    |
| 4b  | `0x02AD20`  | `0x700D6D20` | `B.HS ...`    | `NOP`   | `CMP X8, #0x400`      |
| 4c  | `0x02B0BC`  | `0x700D70BC` | `CBZ W0, ...` | `B ...` | error code `0x3C2`    |
| 4d  | `0x02ED6C`  | `0x700DAD6C` | `CBZ X8, ...` | `NOP`   | `LDR X8, [xN, #0x78]` |
| 4e  | `0x02EF68`  | `0x700DAF68` | `CBZ W0, ...` | `B ...` | error code `0x110`    |

**Anchoring techniques:**

- **4a, 4c, 4e:** Find unique `MOV W8, #<error>` instruction, the `CBZ` is 4 bytes
  before. Convert conditional branch to unconditional `B` (same target).
- **4b:** Find unique `CMP X8, #0x400`, NOP the `B.HS` that follows.
- **4d:** Scan backwards from error `0x110` for `LDR X8, [xN, #0x78]` + `CBZ X8`,
  NOP the `CBZ`.

### Patch 5: Panic Bypass (LLB only)

**Purpose:** Prevent panic when a specific boot check fails.

**Anchoring:** Find `MOV W8, #0x328` followed by `MOVK W8, #0x40, LSL #16`
(forming constant `0x400328`), walk forward to `BL; CBNZ W0`, NOP the `CBNZ`.

| Patch    | File Offset | VA           | Original       | Patched |
| -------- | ----------- | ------------ | -------------- | ------- |
| NOP cbnz | `0x01A038`  | `0x70086038` | `CBNZ W0, ...` | `NOP`   |

### Patch 6: Skip generate_nonce (iBSS only, JB flow)

**Purpose:** Skip nonce generation to preserve the existing AP nonce. Required for
deterministic DFU restore — without this, iBSS generates a random nonce on each
boot, which can interfere with the restore process.

**Function:** `sub_70077064` (~0x1C00 bytes) — iBSS platform initialization.

**Anchoring:** Find `"boot-nonce"` string reference via ADRP+ADD, then scan forward
for: `TBZ/TBNZ W0, #0` + `MOV W0, #0` + `BL` pattern. Convert `TBZ/TBNZ` to unconditional `B`.

| Patch      | File Offset | VA           | Original                 | Patched        |
| ---------- | ----------- | ------------ | ------------------------ | -------------- |
| Skip nonce | `0x00B7B8`  | `0x700777B8` | `TBZ W0, #0, 0x700777F0` | `B 0x700777F0` |

**Disassembly context:**

```
70077750  ADD     X8, X8, #("boot-nonce" - ...)   ; 1st ref: read nonce env var
70077754  BL      sub_70079590                     ; env_get
...
7007778C  ADRL    X8, "boot-nonce"                 ; 2nd ref: nonce generation block
70077798  ADD     X8, X8, #("dram-vendor" - ...)
7007779C  BL      sub_70079570                     ; env_set
700777A0  BL      sub_700797B4
...
700777B4  BL      sub_7009F620                     ; check if nonce needed
700777B8  TBZ     W0, #0, loc_700777F0             ; skip if bit0=0  ← patch to B
700777BC  MOV     W0, #0
700777C0  BL      sub_70087414                     ; generate_nonce(0)
700777C4  STR     X0, [SP, ...]                    ; store nonce
...
700777F0  ADRL    X8, "dram-vendor"                ; continue init
```

The `generate_nonce` function (`sub_70087414`) calls a random number generator
(`sub_70083FA4`) to create a new 64-bit nonce and stores it in the platform state.
The patch makes the `TBZ` unconditional so the nonce generation block is always
skipped, preserving whatever nonce was already set (or leaving it empty).

**Current placement (rewrite/JB path):**
This patch is intentionally kept in the JB extension path (`fw_patch_jb.py` +
`IBootJBPatcher`) so the base flow remains unchanged. Use JB flow when you need
deterministic nonce behavior for restore/research scenarios.

## RELEASE vs RESEARCH_RELEASE Variants

Both variants work with all dynamic patches. Offsets differ but the patcher
finds them by pattern matching:

| Patch                             | RELEASE offset | RESEARCH offset |
| --------------------------------- | -------------- | --------------- |
| Serial label 1                    | `0x084549`     | `0x0861C9`      |
| Serial label 2                    | `0x0845F4`     | `0x086274`      |
| image4 callback (nop)             | `0x009D14`     | `0x00A0DC`      |
| image4 callback (mov)             | `0x009D18`     | `0x00A0E0`      |
| Skip generate*nonce *(JB patch)\_ | `0x00B7B8`     | `0x00BC08`      |

`fw_patch.py` targets RELEASE, matching the BuildManifest identity
(PCC RELEASE for LLB/iBSS/iBEC). The reference script used RESEARCH_RELEASE.
Both work — the dynamic patcher is variant-agnostic.

## Cross-Version Comparison (26.1 → 26.3)

Reference hardcoded offsets (26.1 RESEARCH_RELEASE) vs dynamic patcher results
(26.3 RELEASE):

| Patch          | 26.1 (hardcoded) | 26.3 RELEASE (dynamic) | 26.3 RESEARCH (dynamic) |
| -------------- | ---------------- | ---------------------- | ----------------------- |
| Serial label 1 | `0x84349`        | `0x84549`              | `0x861C9`               |
| Serial label 2 | `0x843F4`        | `0x845F4`              | `0x86274`               |
| image4 nop     | `0x09D10`        | `0x09D14`              | `0x0A0DC`               |
| image4 mov     | `0x09D14`        | `0x09D18`              | `0x0A0E0`               |
| generate_nonce | `0x1B544`        | `0x0B7B8`              | `0x0BC08`               |

Offsets shift significantly between versions and variants, confirming that
hardcoded offsets would break. The dynamic patcher handles all combinations.

## Appendix: IDA Pseudocode / Disassembly

### A. Serial Label Banners (`ibss_main` @ `0x7006F71C`)

```
ibss_main (ROM @ 0x7006fa98):
; --- banner 1 ---
7006faa8  ADRL    X0, "\n\n=======================================\n"   ; 0x700F0546
7006fab0  BL      serial_printf
7006fab4  ADRL    X20, "::\n"
7006fabc  MOV     X0, X20
7006fac0  BL      serial_printf
...
; :: <build info lines> ::
...
7006fc30  BL      serial_printf
7006fc34  MOV     X0, X20
7006fc38  BL      serial_printf
; --- banner 2 ---
7006fc3c  ADRL    X0, "=======================================\n\n"    ; 0x700F05F3
7006fc44  BL      serial_printf
7006fc48  BL      sub_700C8674
```

Patcher writes `"Loaded iBSS"` at banner+1 (offset into the `===...===` run).

### B. image4_validate_property_callback (`0x70075350`)

**Pseudocode:**

```c
// image4_validate_property_callback — dispatches on image4 property tags.
// Returns 0 on success, -1 on failure.
// X22 accumulates the return code throughout the function.
//
// Property tags handled (FourCC → hex):
//   BORD=0x424F5244  CHIP=0x43484950  CEPO=0x4345504F  CSEC=0x43534543
//   DICE=0x45434944  EPRO=0x4550524F  ESEC=0x45534543  EKEY=0x454B4559
//   DPRO=0x4450524F  SDOM=0x53444F4D  CPRO=0x4350524F  BNCH=0x424E4348
//   pndp=0x706E6470  osev=0x6F736576  nrde=0x6E726465  slvn=0x736C766E
//   dpoc=0x64706F63  anrd=0x616E7264  exrm=0x6578726D  hclo=0x68636C6F
//   AMNM=0x414D4E4D
//
int64_t image4_validate_property_callback(tag, a2, capture_mode, a4, ...) {
    if (MEMORY[0x701004D8] != 1)
        goto dispatch;

    // Handle ASN1 types 1, 2, 4 via registered callbacks
    switch (*(_QWORD *)(a2 + 16)) {
        case 1: if (callback_bool) callback_bool(tag, capture_mode == 1, value); break;
        case 2: if (callback_int)  callback_int(tag, capture_mode == 1, value);  break;
        case 4: if (callback_data) callback_data(tag, capture_mode == 1, ptr, ptr, end, ...); break;
        default: log_printf(0, "Unknown ASN1 type %llu\n"); return -1;
    }

dispatch:
    // Main tag dispatch (capture_mode: 0=verify, 1=capture)
    if (capture_mode == 1) {
        switch (tag) {
            case 'BORD': ... // board ID
            case 'CHIP': ... // chip ID
            ...
        }
    } else if (capture_mode == 0) {
        switch (tag) {
            case 'BNCH': ... // boot nonce hash
            case 'CEPO': ... // certificate epoch
            ...
        }
    }
    // ... (21 property handlers)
    return x22;  // 0=success, -1=failure
}
```

**Epilogue disassembly (patch site):**

```
; At this point X22 = return value (0 or -1)
70075CFC  MOV     W22, #0xFFFFFFFF      ; set error return = -1
70075D00  LDUR    X8, [X29, #var_60]    ; load saved stack cookie
70075D04  ADRL    X9, "160D"            ; expected cookie value
70075D0C  LDR     X9, [X9]
70075D10  CMP     X9, X8                ; stack canary check
70075D14  B.NE    loc_70075E50          ; → stack_chk_fail   ◄── PATCH 2a: NOP
70075D18  MOV     X0, X22              ; return x22          ◄── PATCH 2b: MOV X0, #0
70075D1C  LDP     X29, X30, [SP, ...]  ; restore callee-saved
70075D20  LDP     X20, X19, [SP, ...]
70075D24  LDP     X22, X21, [SP, ...]
70075D28  LDP     X24, X23, [SP, ...]
70075D2C  LDP     X26, X25, [SP, ...]
70075D30  LDP     X28, X27, [SP, ...]
70075D34  ADD     SP, SP, #0x110
70075D38  RETAB
```

Effect: function always returns 0 (success) regardless of property validation.

### C. generate_nonce (`0x70087414`)

**Pseudocode:**

```c
// generate_nonce — creates a random 64-bit AP nonce.
// Called from platform_init when boot-nonce environment needs a new nonce.
//
uint64_t generate_nonce() {
    platform_state *ps = get_platform_state();

    if (ps->flags & 2)                     // nonce already generated?
        goto return_existing;

    uint64_t nonce = random64(0);           // generate random 64-bit value
    ps->nonce = nonce;                      // store at offset +40
    ps->flags |= 2;                         // mark nonce as valid

    if (ps->nonce_lo == 0) {                // sanity check
        get_platform_state2();
        log_assert(1630);                   // "nonce is zero" assertion
    return_existing:
        nonce = ps->nonce;
    }
    return nonce;
}
```

### D. Skip generate_nonce — `platform_init` (`0x70077064`)

**Disassembly (boot-nonce handling region):**

```
; --- Phase 1: read existing boot-nonce from env ---
70077744  ADRL    X8, "effective-security-mode-ap"
7007774C  STP     X8, X8, [SP, #var_238]
70077750  ADD     X8, X8, #("boot-nonce" - ...)    ; 1st ref to "boot-nonce"
70077754  BL      env_get                           ; read boot-nonce env var
70077758  STP     X24, X24, [SP, #var_2F0]
7007775C  ADRL    X7, ...
70077764  BL      sub_7007968C
70077768  ADD     X6, X19, #0x20
7007776C  BL      env_check_property                ; check if boot-nonce exists
70077770  TBZ     W0, #0, loc_7007778C              ; if no existing nonce, skip
70077774  BL      sub_700BF1D8                      ; get security mode
70077778  MOV     X23, X0
7007777C  BL      sub_700795D8
70077780  CCMP    X0, X2, #2, CS
70077784  B.CS    loc_70078C44                      ; error path
70077788  BL      sub_700798D0

; --- Phase 2: generate new nonce (PATCHED OUT) ---
7007778C  ADRL    X8, "boot-nonce"                  ; 2nd ref to "boot-nonce"
70077794  STP     X8, X8, [SP, #var_238]
70077798  ADD     X8, X8, #("dram-vendor" - ...)
7007779C  BL      env_set                           ; set boot-nonce env key
700777A0  BL      env_clear
700777A4  ADRL    X7, ...
700777AC  BL      sub_7007968C
700777B0  ADD     X6, X19, #0x20
700777B4  BL      env_check_property                ; check if nonce generation needed
700777B8  TBZ     W0, #0, loc_700777F0              ; ◄── PATCH 6: change to B (always skip)
700777BC  MOV     W0, #0
700777C0  BL      generate_nonce                    ; generate_nonce(0) — SKIPPED
700777C4  STR     X0, [SP, #var_190]                ; store nonce result
700777C8  BL      sub_70079680
700777CC  ADD     X8, SP, #var_190
700777D0  LDR     W9, [SP, #var_214]
700777D4  STR     X9, [SP, #var_2F0]
700777D8  ADRL    X7, ...
700777E0  ADD     X4, SP, #var_190
700777E4  ADD     X5, SP, #var_190
700777E8  ADD     X6, X8, #8
700777EC  BL      sub_700A8F24                      ; commit nonce to env

; --- Phase 3: continue with dram-vendor init ---
700777F0  ADRL    X8, "dram-vendor"                 ; ◄── branch target (skip lands here)
700777F8  STP     X8, X8, [SP, #var_238]
700777FC  ADD     X8, X8, #("dram-vendor-id" - ...)
70077800  BL      env_get
```

**Patch effect:** `TBZ W0, #0, 0x700777F0` → `B 0x700777F0`

Unconditionally skips the `generate_nonce(0)` call and all nonce storage logic,
jumping directly to the "dram-vendor" init. Preserves any existing AP nonce from
a previous boot or NVRAM.

## Appendix E: Nonce Skip — IDA Pseudocode Before/After

### generate_nonce (`sub_70087414`)

```c
unsigned __int64 generate_nonce()
{
  platform_state *ps = get_platform_state();

  if ( (ps->flags & 2) != 0 )           // nonce already generated?
    goto return_existing;

  uint64_t nonce = random64(0);          // generate random 64-bit value
  *(uint64_t *)(ps + 40) = nonce;        // store nonce
  *(uint32_t *)ps |= 2u;                // mark nonce as valid

  if ( !*(uint32_t *)(ps + 40) )         // sanity: nonce_lo == 0?
  {
    v4 = get_platform_state2();
    log_assert(v4, 1630);                // "nonce is zero" assertion
  return_existing:
    nonce = *(uint64_t *)(ps + 40);      // return existing nonce
  }
  return nonce;
}
```

### platform_init — boot-nonce region: BEFORE patch

```c
  // --- Phase 1: read existing boot-nonce from env ---
  env_get(...,                                    /*0x70077754*/
    "effective-security-mode-ap",
    "effective-security-mode-ap", ...);
  env_check_property(...);                        /*0x7007776c*/
  if ( (v271 & 1) != 0 )                         /*0x70077770*/
  {
    // existing nonce found — security mode check
    v97 = get_security_mode();                    /*0x70077778*/
    v279 = validate_security(v97);                /*0x7007777c*/
    if ( !v42 || v279 >= v280 )                   /*0x70077780*/
      goto LABEL_311;                             // error path
  }

  // --- Phase 2: set boot-nonce env, check if generation needed ---
  env_set(...,                                    /*0x7007779c*/
    "boot-nonce",
    "boot-nonce", ...);
  env_clear();                                    /*0x700777a0*/
  v290 = env_check_property(...);                 /*0x700777b4*/

  if ( (v290 & 1) != 0 )                         /*0x700777b8  ← TBZ W0, #0*/
  {
    nonce = generate_nonce();                     /*0x700777c4  ← BL generate_nonce*/
    sub_70079680(nonce);                          /*0x700777c8*/
    sub_700A8F24(...);                            /*0x700777ec  — commit nonce to env*/
  }

  // --- Phase 3: continue with dram-vendor init ---
  env_get(...,                                    /*0x70077800*/
    "dram-vendor",
    "dram-vendor", ...);
```

### platform_init — boot-nonce region: AFTER patch

```c
  // --- Phase 2: set boot-nonce env ---
  env_set(...,                                    /*0x7007779c*/
    "boot-nonce",
    "boot-nonce", ...);
  env_clear();                                    /*0x700777a0*/
  v290 = env_check_property(...);                 /*0x700777b4*/

  // generate_nonce() block ELIMINATED by decompiler
  // (unconditional B at 0x700777B8 makes it dead code)

  // --- Phase 3: continue with dram-vendor init ---
  v298 = env_get(...,                             /*0x70077800*/
    "dram-vendor",
    "dram-vendor", ...);
```

**Patch effect in decompiler:** The entire `if` block containing `generate_nonce()`
is removed. The decompiler recognizes the unconditional `B` creates dead code and
eliminates it entirely — execution flows straight from `env_check_property()` to
the `"dram-vendor"` env_get.

### Byte Comparison

Reference: `patch(0x1b544, 0x1400000e)` (26.1 RESEARCH, hardcoded)

|              | Reference (26.1)    | Dynamic (26.3 RELEASE) | Dynamic (26.3 RESEARCH) |
| ------------ | ------------------- | ---------------------- | ----------------------- |
| **Offset**   | `0x1B544`           | `0x0B7B8`              | `0x0BC08`               |
| **Original** | `TBZ W0, #0, +0x38` | `TBZ W0, #0, +0x38`    | `TBZ W0, #0, +0x38`     |
| **Patched**  | `B +0x38`           | `B +0x38`              | `B +0x38`               |
| **Bytes**    | `0E 00 00 14`       | `0E 00 00 14`          | `0E 00 00 14`           |

All three produce byte-identical `0x1400000E` — same branch delta `+0x38` (14 words)
across all variants. Only the file offset differs between versions.

## Status

`patch_skip_generate_nonce()` is active in the JB path via
`IBootJBPatcher` and `fw_patch_jb.py` (iBSS JB component enabled).
