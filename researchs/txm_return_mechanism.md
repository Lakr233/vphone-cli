# TXM Return Mechanism & selector24 CS Bypass Analysis

Analysis of TXM's cross-level return mechanism and why direct `ret`/`retab` from
patched functions causes unhandled exceptions. Derived from disassembly of the
research TXM variant (iPhone17,3 / PCC-CloudOS 26.3).

## TXM Execution Model

TXM runs at a guested exception level (GL) under SPTM's supervision:

```
SPTM (GL2) — Secure Page Table Monitor
  ↕ svc #0
TXM (GL1) — Trusted Execution Monitor
  ↕ trap
Kernel (EL1/GL0)
```

SPTM dispatches selector calls into TXM. TXM **cannot** execute SPTM code
(instruction fetch permission fault). TXM must return to SPTM via `svc #0`.

## Return Path: TXM → SPTM

All TXM functions return through this chain:

```
TXM function
  → bl return_helper (0x26c04)
    → bl return_trap_stub (0x49b40)
      → movk x16, ... (set SPTM return code)
      → b trampoline (0x60000)
        → pacibsp
        → svc #0          ← traps to SPTM
        → retab            ← resumes after SPTM returns
```

### Trampoline at 0x60000 (`__TEXT_BOOT_EXEC`)

```asm
0x060000: pacibsp
0x060004: svc    #0           ; supervisor call → SPTM handles the trap
0x060008: retab               ; return after SPTM gives control back
```

### Return Trap Stub at 0x49B40 (`__TEXT_EXEC`)

```asm
0x049B40: bti    c
0x049B44: movk   x16, #0, lsl #48
0x049B48: movk   x16, #0xfd, lsl #32    ; x16 = 0x000000FD00000000
0x049B4C: movk   x16, #0, lsl #16       ; (SPTM return code identifier)
0x049B50: movk   x16, #0
0x049B54: b      #0x60000               ; → trampoline → svc #0
```

x16 carries a return code that SPTM uses to identify which TXM operation completed.

### Return Helper at 0x26C04 (`__TEXT_EXEC`)

```asm
0x026C04: pacibsp
0x026C08: stp    x20, x19, [sp, #-0x20]!
0x026C0C: stp    x29, x30, [sp, #0x10]
0x026C10: add    x29, sp, #0x10
0x026C14: mov    x19, x0              ; save result code
0x026C18: bl     #0x29024             ; get TXM context
0x026C1C: ldrb   w8, [x0]            ; check context flag
0x026C20: cbz    w8, #0x26c30
0x026C24: mov    x20, x0
0x026C28: bl     #0x29010             ; cleanup if flag set
0x026C2C: strb   wzr, [x20, #0x58]
0x026C30: mov    x0, x19              ; restore result
0x026C34: bl     #0x49b40             ; → svc #0 → SPTM
```

### Error Handler at 0x25924

```asm
0x025924: pacibsp
...
0x025978: stp    x19, x20, [sp]       ; x19=error_code, x20=param
0x02597C: adrp   x0, #0x1000
0x025980: add    x0, x0, #0x8d8       ; format string
0x025984: bl     #0x25744             ; log error → eventually svc #0
```

## Why `ret`/`retab` Fails

### Attempt 1: `mov x0, #0; retab` replacing PACIBSP

```
0x026C80: mov x0, #0     ; (was pacibsp)
0x026C84: retab           ; verify PAC on LR → FAIL
```

**Result**: `[TXM] Unhandled synchronous exception at pc 0x...6C84`

RETAB tries to verify the PAC signature on LR. Since PACIBSP was replaced,
LR was never signed. RETAB detects the invalid PAC → exception.

### Attempt 2: `mov x0, #0; ret` replacing PACIBSP

```
0x026C80: mov x0, #0     ; (was pacibsp)
0x026C84: ret             ; jump to LR (SPTM address)
```

**Result**: `[TXM] Unhandled synchronous exception at pc 0x...FA88` (SPTM space)

`ret` strips PAC and jumps to clean LR, which points to SPTM code (the caller).
TXM cannot execute SPTM code → **instruction fetch permission fault** (ESR EC=0x20, IFSC=0xF).

### Attempt 3: `pacibsp; mov x0, #0; retab`

```
0x026C80: pacibsp         ; signs LR correctly
0x026C84: mov x0, #0
0x026C88: retab           ; verifies PAC (OK), jumps to LR (SPTM address)
```

**Result**: Same permission fault — RETAB succeeds (PAC valid), but the return
address is in SPTM space. TXM still cannot execute there.

**Conclusion**: No form of `ret`/`retab` works because the **caller is SPTM**
and TXM cannot return to SPTM via normal returns. The only way back is `svc #0`.

## selector24 Function Analysis (0x026C80 - 0x026E7C)

### Full Control Flow

```
0x026C80: pacibsp                          ; prologue
0x026C84: sub sp, sp, #0x70
0x026C88-0x026C98: save x19-x30, setup fp

0x026CA0-0x026CB4: save args to x20-x25
0x026CB8: bl #0x29024                      ; get TXM context → x0
0x026CBC: adrp x8, #0x6c000               ; ◄── PATCH HERE (1/2)
0x026CC0: add x8, x8, #0x5c0              ; ◄── PATCH HERE (2/2)
0x026CC4: ldrb w8, [x8]                   ; flag check
0x026CC8: cbnz w8, #0x26cfc               ; if flag → error 0xA0
0x026CCC: mov x19, x0                     ; save context

0x026CD4: cmp w25, #2                     ; switch on sub-selector (arg0)
         b.gt → check 3,4,5
0x026CDC: cbz w25 → case 0
0x026CE4: b.eq → case 1
0x026CEC: b.ne → default (0xA1 error)

         case 0: setup, b 0x26dc0
         case 1: flag check, setup, b 0x26dfc
         case 2: bl 0x1e0e8, b 0x26db8
         case 3: bl 0x1e148, b 0x26db8
         case 4: bl 0x1e568, b 0x26db8
         case 5: flag → { mov x0,#0; b 0x26db8 } or { bl 0x1e70c; b 0x26db8 }
         default: mov w0, #0xa1; b 0x26d00 (error path)

0x026DB8: and w8, w0, #0xffff             ; result processing
0x026DBC: and x9, x0, #0xffffffffffff0000
0x026DC0: mov w10, w8
0x026DC4: orr x9, x9, x10
0x026DC8: str x9, [x19, #8]              ; store result to context
0x026DCC: cmp w8, #0
0x026DD0: csetm x0, ne                   ; x0 = 0 (success) or -1 (error)
0x026DD4: bl #0x26c04                    ; return via svc #0 ← SUCCESS RETURN

ERROR PATH:
0x026D00: mov w1, #0
0x026D04: bl #0x25924                    ; error handler → svc #0
```

### Existing Success Path

The function already has a success path at `0x026D30` (reached by case 5 when flag is set):

```asm
0x026D30: mov    x0, #0         ; success result
0x026D34: b      #0x26db8       ; → process result → str [x19,#8] → bl return_helper
```

### Error Codes

| Return Value | Meaning |
|---|---|
| `0x00` | Success (only via case 5 flag path) |
| `0xA0` | Early flag check failure |
| `0xA1` | Unknown sub-selector / validation failure |
| `0x130A1` | Hash mismatch (hash presence != flag) |
| `0x22DA1` | Version-dependent validation failure |

### Panic Format

`TXM [Error]: CodeSignature: selector: 24 | 0xA1 | 0x30 | 1`

This is a **kernel-side** message (not in TXM binary). The kernel receives the
non-zero return from the `svc #0` trap and formats the error:
`selector: <selector_num> | <low_byte> | <mid_byte> | <high_byte>`

For `0x000130A1`: low=`0xA1`, mid=`0x30`, high=`0x1` → `| 0xA1 | 0x30 | 1`

## Correct Fix: Redirect to Success Path

Patch 2 instructions at `0x26CBC` (right after `bl #0x29024`):

```asm
; Original:
0x026CBC: adrp   x8, #0x6c000     ; flag check setup
0x026CC0: add    x8, x8, #0x5c0   ; flag address

; Patched:
0x026CBC: mov    x19, x0           ; save context (originally done at 0x26CCC)
0x026CC0: b      #0x26D30          ; → mov x0,#0; b #0x26db8 (success path)
```

### Why This Works

1. **Prologue preserved**: PACIBSP signs LR, stack frame set up, registers saved
2. **Context initialized**: `bl #0x29024` returns the TXM context pointer in x0
3. **x19 = context**: Required for `str x9, [x19, #8]` at `0x26DC8`
4. **Success path**: `x0 = 0` → result processing stores 0 → `csetm x0, ne` → `x0 = 0`
5. **Normal return**: `bl #0x26c04` → `bl #0x49b40` → `svc #0` → back to SPTM

### Dynamic Finder Anchor

The function is uniquely identified by `mov w0, #0xa1` (only one instance in TXM).
Scan back for PACIBSP to find function start, then find `bl` at offset +0x38
from start (the `bl #0x29024` call). Patch the next 2 instructions.

## UUID Canary Verification

To confirm which TXM variant is loaded during boot, XOR the last byte of `LC_UUID`:

| | UUID |
|---|---|
| Original research | `0FFA437D-376F-3F8E-AD26-317E2111655D` |
| Original release | `3C1E0E65-BFE2-3113-9C65-D25926C742B4` |
| Canary (research XOR 0x01) | `0FFA437D-376F-3F8E-AD26-317E2111655C` |

Panic log `TXM UUID:` line confirmed canary `...655C` → **patched research TXM IS loaded**.
The problem was exclusively in the selector24 patch logic (NOP doesn't change return value).
