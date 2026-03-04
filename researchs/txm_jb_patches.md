# TXM Jailbreak Patch Analysis

Analysis of 6 logical TXM jailbreak patches (11 instruction modifications) applied by `txm_jb.py` on the RESEARCH variant
of TXM from iPhone17,3 / PCC-CloudOS 26.x.

## Address Mapping

| Segment            | VM Address           | File Offset | Size      |
| ------------------ | -------------------- | ----------- | --------- |
| `__TEXT_EXEC`      | `0xFFFFFFF017020000` | `0x1c000`   | `0x44000` |
| `__TEXT_BOOT_EXEC` | `0xFFFFFFF017064000` | `0x60000`   | `0xc000`  |

Conversion: `VA = file_offset - 0x1c000 + 0xFFFFFFF017020000` (for `__TEXT_EXEC`)

---

## TXM Selector Dispatch

All TXM operations enter through a single dispatch function (`sub_FFFFFFF01702AE80`),
a large switch on the selector number (1–51). Each case validates arguments and calls
a dedicated handler. Relevant selectors:

| Selector | Handler                                   | Purpose                                           |
| -------- | ----------------------------------------- | ------------------------------------------------- |
| 24       | `sub_FFFFFFF017024834` → validation chain | CodeSignature validation                          |
| 41       | `sub_FFFFFFF017023558`                    | Process entitlement setup (get-task-allow)        |
| 42       | `sub_FFFFFFF017023368`                    | Debug memory mapping                              |
| —        | `sub_FFFFFFF017023A20`                    | Developer mode configuration (called during init) |

The dispatcher passes raw page pointers through `sub_FFFFFFF0170280A4` (a bounds
validator that returns the input pointer unchanged) before calling handlers.

---

## Patch 1–2: CodeSignature Hash Comparison Bypass (selector 24)

**Error**: `TXM [Error]: CodeSignature: selector: 24 | 0xA1 | 0x30 | 1`

### Addresses

| File Offset | VA                   | Original Instruction      | Patch |
| ----------- | -------------------- | ------------------------- | ----- |
| `0x313ec`   | `0xFFFFFFF0170353EC` | `LDR X1, [X20, #0x38]`    | NOP   |
| `0x313f4`   | `0xFFFFFFF0170353F4` | `BL sub_FFFFFFF0170335F8` | NOP   |

### Function: `sub_FFFFFFF0170353B8` — CS hash flags validator

**Call chain**: selector 24 → `sub_FFFFFFF017024834` (CS handler) →
`sub_FFFFFFF0170356F8` (CS validation pipeline) → `sub_FFFFFFF017035A00`
(multi-step validation, step 4 of 8) → `sub_FFFFFFF0170353B8`

### Decompiled (pre-patch)

```c
// sub_FFFFFFF0170353B8(manifest_ptr, version)
__int64 __fastcall sub_FFFFFFF0170353B8(__int64 **a1, unsigned int a2)
{
    __int64 v4 = **a1;
    __int64 v7 = 0;    // hash data pointer
    int v6 = 0;        // hash flags

    // Patch 1: NOP removes arg load (LDR X1, [X20, #0x38])
    // Patch 2: NOP removes this call entirely:
    sub_FFFFFFF0170335F8(a1[6], a1[7], &v6);   // extract hash flags from CS blob
    sub_FFFFFFF017033718(a1[6], a1[7], &v7);    // extract hash data pointer

    if ( a2 >= 6 && *(v4 + 8) )
        return 0xA1;                            // 161

    // Critical comparison: does hash presence match flags?
    if ( (v7 != 0) == ((v6 & 2) >> 1) )
        return 0x130A1;                         // 77985 — hash mismatch

    // ... further version-dependent checks return 0xA1 or 0x22DA1
}
```

### What `sub_FFFFFFF0170335F8` does

Extracts hash flags from the CodeSignature blob header. Reads `bswap32(*(blob + 12))`
into the output parameter (the flags bitmask). Bit 1 of the flags indicates whether
a code hash is present.

### What `sub_FFFFFFF017033718` does

Locates the hash data within the CodeSignature blob. Validates blob header version
(`bswap32(*(blob+8)) >> 9 >= 0x101`), then follows a length-prefixed string pointer
at offset 48 to find the hash data. Returns the hash data pointer via output param.

### Effect of NOP

With `sub_FFFFFFF0170335F8` NOPed, `v6` stays at its initialized value of **0**.
This means `(v6 & 2) >> 1 = 0` (hash-present flag is cleared). As long as
`sub_FFFFFFF017033718` returns a non-null hash pointer (`v7 != 0`), the comparison
becomes `(1 == 0)` → **false**, so the `0x130A1` error is skipped. The function
falls through to the version checks which return success for version ≤ 5.

This effectively bypasses CodeSignature hash validation — the hash data exists
in the blob but the hash-present flag is suppressed, so the consistency check passes.

### `txm_jb.py` dynamic finder: `patch_selector24_hash_extraction_nop()`

Scans for `mov w0, #0xa1` as a unique anchor to locate the CS hash validator function,
finds PACIBSP to determine function start, then matches the pattern
`LDR X1,[Xn,#0x38]` / `ADD X2,...` / `BL` / `LDP` within it. NOPs the `LDR X1`
(arg setup) and the `BL hash_flags_extract` (call).

---

## Patch 3: get-task-allow Force True (selector 41)

**Error**: `TXM [Error]: selector: 41 | 29`

### Address

| File Offset | VA                   | Original Instruction      | Patch        |
| ----------- | -------------------- | ------------------------- | ------------ |
| `0x1f5d4`   | `0xFFFFFFF0170235D4` | `BL sub_FFFFFFF017022A30` | `MOV X0, #1` |

### Function: `sub_FFFFFFF017023558` — selector 41 handler

**Call chain**: selector 41 → `sub_FFFFFFF0170280A4` (ptr validation) →
`sub_FFFFFFF017023558`

### Decompiled (pre-patch)

```c
// sub_FFFFFFF017023558(manifest)
__int64 __fastcall sub_FFFFFFF017023558(__int64 a1)
{
    // Check developer mode is enabled (byte_FFFFFFF017070F24)
    if ( (byte_FFFFFFF017070F24 & 1) == 0 )
        return 27;    // developer mode not enabled

    // Check license-to-operate entitlement (always first)
    sub_FFFFFFF017022A30(0, "research.com.apple.license-to-operate", 0);

    // Lock manifest
    sub_FFFFFFF017027074(a1, 0, 0);

    if ( *(a1 + 36) == 1 )     // special manifest type
        goto error_path;        // return via panic(0x81)

    // === PATCHED INSTRUCTION ===
    // Original: BL sub_FFFFFFF017022A30  — entitlement_lookup(manifest, "get-task-allow", 0)
    // Patched:  MOV X0, #1
    if ( (sub_FFFFFFF017022A30(a1, "get-task-allow", 0) & 1) != 0 )  // TBNZ w0, #0
    {
        v3 = 0;                 // success
        *(a1 + 0x30) = 1;      // set get-task-allow flag on manifest
    }
    else
    {
        v3 = 29;               // ERROR 29: no get-task-allow entitlement
    }

    sub_FFFFFFF01702717C(a1, 0);    // unlock manifest
    return v3;
}
```

### Assembly at patch site

```asm
FFFFFFF0170235C4  ADRL  X1, "get-task-allow"
FFFFFFF0170235CC  MOV   X0, X19              ; manifest object
FFFFFFF0170235D0  MOV   X2, #0
FFFFFFF0170235D4  BL    sub_FFFFFFF017022A30  ; <-- PATCHED to MOV X0, #1
FFFFFFF0170235D8  TBNZ  W0, #0, loc_...       ; always taken when x0=1
```

### Effect

Replaces the entitlement lookup call with a constant `1`. The subsequent `TBNZ W0, #0`
always takes the branch to the success path, which sets `*(manifest + 0x30) = 1`
(the get-task-allow flag byte). Every process now has get-task-allow, enabling
debugging via `task_for_pid` and LLDB attach.

### What `sub_FFFFFFF017022A30` does

Universal entitlement lookup function. When `a1 != 0`, it resolves the manifest's
entitlement dictionary and searches for the named key via `sub_FFFFFFF017036294`.
Returns a composite status word where bit 0 indicates the entitlement was found.

### `txm_jb.py` dynamic finder: `patch_get_task_allow_force_true()`

Searches for string refs to `"get-task-allow"`, then scans forward for the pattern
`BL X / TBNZ w0, #0, Y`. Patches the BL to `MOV X0, #1`.

---

## Patch 4: selector 42|29 Shellcode (Debug Mapping Gate)

**Error**: `TXM [Error]: selector: 42 | 29`

### Addresses

| File Offset | VA                   | Patch                      |
| ----------- | -------------------- | -------------------------- |
| `0x2717c`   | `0xFFFFFFF01702B17C` | `B #0x36238` (→ shellcode) |
| `0x5d3b4`   | `0xFFFFFFF0170613B4` | `NOP` (pad)                |
| `0x5d3b8`   | `0xFFFFFFF0170613B8` | `MOV X0, #1`               |
| `0x5d3bc`   | `0xFFFFFFF0170613BC` | `STRB W0, [X20, #0x30]`    |
| `0x5d3c0`   | `0xFFFFFFF0170613C0` | `MOV X0, X20`              |
| `0x5d3c4`   | `0xFFFFFFF0170613C4` | `B #-0x36244` (→ 0xB180)   |

### Context: Dispatcher case 42

```asm
; jumptable case 42 entry in sub_FFFFFFF01702AE80:
FFFFFFF01702B178  BTI   j
FFFFFFF01702B17C  MOV   X0, X20                ; <-- PATCHED to B shellcode
FFFFFFF01702B180  BL    sub_FFFFFFF0170280A4    ; validate pointer
FFFFFFF01702B184  MOV   X1, X21
FFFFFFF01702B188  MOV   X2, X22
FFFFFFF01702B18C  BL    sub_FFFFFFF017023368    ; selector 42 handler
FFFFFFF01702B190  B     loc_FFFFFFF01702B344    ; return result
```

### Shellcode (at zero-filled code cave in `__TEXT_EXEC`)

```asm
; 0xFFFFFFF0170613B4 — cave was all zeros
NOP                           ; pad (original 0x00000000)
MOV   X0, #1                  ; value to store
STRB  W0, [X20, #0x30]        ; force manifest->get_task_allow = 1
MOV   X0, X20                 ; restore original instruction (was at 0xB17C)
B     #-0x36244                ; jump back to 0xFFFFFFF01702B180 (BL validate)
```

### Why this is needed

Selector 42's handler `sub_FFFFFFF017023368` checks the get-task-allow byte early:

```c
// sub_FFFFFFF017023368(manifest, addr, size)
// ... after debugger entitlement check ...
v8 = atomic_load((unsigned __int8 *)(a1 + 48));  // offset 0x30
if ( (v8 & 1) == 0 )
{
    v6 = 29;    // ERROR 29: get-task-allow not set
    goto unlock_and_return;
}
// ... proceed with debug memory mapping ...
```

Selector 41 (patch 3) sets this byte during entitlement validation, but
there are code paths where selector 42 can be called before selector 41 has run
for a given manifest. The shellcode ensures the flag is always set at the dispatch
level before the handler even sees it.

### `sub_FFFFFFF0170280A4` — pointer validator

```c
// Validates page alignment and bounds, returns input pointer unchanged
unsigned __int64 sub_FFFFFFF0170280A4(unsigned __int64 a1) {
    if ( (a1 & ~0x3FFF) == 0 ) panic(64);
    if ( a1 >= 0xFFFFFFFFFFFFC000 ) panic(66);
    // ... bounds checks ...
    return (a1 & ~0x3FFF) + (a1 & 0x3FFF);  // == a1
}
```

Since the validator returns the pointer unchanged, `x20` (raw arg) and the validated
pointer both refer to the same object. The shellcode's `STRB W0, [X20, #0x30]`
writes to the correct location.

### `txm_jb.py` dynamic finder: `patch_selector42_29_shellcode()`

1. Finds the "debugger gate function" via string refs to `"com.apple.private.cs.debugger"`
2. Locates the dispatch stub by matching `BTI j / MOV X0, X20 / BL / MOV X1, X21 / MOV X2, X22 / BL debugger_gate / B`
3. Finds a zero-filled code cave via `_find_udf_cave()` near the stub
4. Emits the branch + shellcode + branch-back

---

## Patch 5: Debugger Entitlement Force True (selector 42)

**Error**: `TXM [Error]: selector: 42 | 37`

### Address

| File Offset | VA                   | Original Instruction      | Patch        |
| ----------- | -------------------- | ------------------------- | ------------ |
| `0x1f3b8`   | `0xFFFFFFF0170233B8` | `BL sub_FFFFFFF017022A30` | `MOV W0, #1` |

### Function: `sub_FFFFFFF017023368` — selector 42 handler (debug memory mapping)

### Assembly at patch site

```asm
; Check com.apple.private.cs.debugger entitlement
FFFFFFF0170233A8  ADRL  X1, "com.apple.private.cs.debugger"
FFFFFFF0170233B0  MOV   X0, #0                 ; check global manifest (a1=0)
FFFFFFF0170233B4  MOV   X2, #0
FFFFFFF0170233B8  BL    sub_FFFFFFF017022A30    ; <-- PATCHED to MOV W0, #1
FFFFFFF0170233BC  TBNZ  W0, #0, loc_...         ; always taken when w0=1
FFFFFFF0170233C0  ADRL  X8, fallback_flag       ; secondary check (also bypassed)
FFFFFFF0170233C8  LDRB  W8, [X8, #offset]
FFFFFFF0170233CC  TBNZ  W8, #0, loc_...         ; secondary bypass path
FFFFFFF0170233D0  ADRL  X0, "disallowed non-debugger initiated debug mapping"
FFFFFFF0170233D8  BL    sub_FFFFFFF017025B7C    ; log error
FFFFFFF0170233DC  MOV   W20, #0x25              ; error 37
FFFFFFF0170233E0  B     unlock_return
```

### Decompiled (pre-patch)

```c
// First check in sub_FFFFFFF017023368 after input validation:
if ( (sub_FFFFFFF017022A30(0, "com.apple.private.cs.debugger", 0) & 1) == 0 )
{
    // Fallback: check a static byte flag
    if ( (fallback_flag & 1) == 0 )
    {
        log("disallowed non-debugger initiated debug mapping");
        return 37;   // 0x25
    }
}
// Continue with debug mapping...
```

### Effect

Replaces the entitlement lookup with `MOV W0, #1`. The `TBNZ W0, #0` always
branches to the success path, bypassing both the entitlement check and the
fallback flag check. This allows any process to create debug memory mappings
regardless of whether it has `com.apple.private.cs.debugger`.

### `txm_jb.py` dynamic finder: `patch_debugger_entitlement_force_true()`

Searches for string refs to `"com.apple.private.cs.debugger"`, then matches
the pattern: `mov x0, #0 / mov x2, #0 / bl X / tbnz w0, #0, Y`. Patches the BL
to `MOV W0, #1`.

---

## Patch 6: Developer Mode Bypass

### Address

| File Offset | VA                   | Original Instruction                | Patch |
| ----------- | -------------------- | ----------------------------------- | ----- |
| `0x1FA58`   | `0xFFFFFFF017023A58` | `TBNZ W9, #0, loc_FFFFFFF017023A6C` | NOP   |

### Function: `sub_FFFFFFF017023A20` — developer mode configuration

Called during TXM initialization to determine and store the developer mode state.
The result is stored in `byte_FFFFFFF017070F24`, which is the gate flag checked by
selector 41 (`sub_FFFFFFF017023558`).

### Assembly at patch site

```asm
; Check system policy configuration
FFFFFFF017023A50  LDR   X9, [X8, #off_FFFFFFF0170146C0]
FFFFFFF017023A54  LDRB  W9, [X9, #0x4D]         ; load system policy byte
FFFFFFF017023A58  TBNZ  W9, #0, loc_FFFFFFF017023A6C  ; <-- PATCHED to NOP
; Fall through to force-enable:
FFFFFFF017023A5C  MOV   W20, #1                  ; developer_mode = ENABLED
FFFFFFF017023A60  ADRL  X0, "developer mode enabled due to system policy configuration"
FFFFFFF017023A68  B     log_and_store
```

### Decompiled (pre-patch)

```c
__int64 sub_FFFFFFF017023A20(__int64 manifest)
{
    char devmode;

    // Check 1: PCC research variant flag
    if ( pcc_research_flag )
    {
        devmode = 1;
        goto apply;
    }

    // Check 2: System policy (patched here)
    byte policy = *(system_config_ptr + 0x4D);
    if ( (policy & 1) != 0 )        // <-- TBNZ jumps past force-enable
        goto normal_path;            //     to xART / user-config checks

    // Force-enable path (reached by NOPing the TBNZ):
    devmode = 1;
    log("developer mode enabled due to system policy configuration");
    goto apply;

normal_path:
    // ... xART availability check ...
    // ... user configuration check ...
    // May set devmode = 0 (disabled) based on config

apply:
    byte_FFFFFFF017070F24 = devmode;  // global developer mode state
    return result;
}
```

### Effect

NOPing the `TBNZ` makes execution always fall through to `MOV W20, #1`, forcing
developer mode enabled regardless of the system policy byte. Without this:

- The `TBNZ` would jump to `loc_FFFFFFF017023A6C` (the normal path)
- The normal path checks xART availability, device tree flags, and user configuration
- On PCC VMs, this can result in developer mode being **disabled**

Developer mode is a **prerequisite** for selectors 41 and 42 — the selector 41
handler returns error 27 immediately if `byte_FFFFFFF017070F24` is not set:

```c
// In sub_FFFFFFF017023558 (selector 41):
if ( (byte_FFFFFFF017070F24 & 1) == 0 )
    return 27;    // developer mode not enabled
```

### `txm_jb.py` dynamic finder: `patch_developer_mode_bypass()`

Searches for string refs to `"developer mode enabled due to system policy
configuration"`, then scans backwards for a `tbz/tbnz/cbz/cbnz` instruction
matching `w9, #0`. NOPs it.

---

## Patch Dependency Chain

The patches have a logical ordering — later patches depend on earlier ones:

```
Patch 6: Developer Mode Bypass
  │  Forces byte_FFFFFFF017070F24 = 1
  │
  ├──► Patch 3: get-task-allow Force True (selector 41)
  │      Requires developer mode (checks byte_FFFFFFF017070F24)
  │      Forces manifest[0x30] = 1
  │
  ├──► Patch 4: selector 42|29 Shellcode
  │      Forces manifest[0x30] = 1 at dispatch level
  │      Safety net for Patch 3 (covers cases where sel 42 runs before sel 41)
  │
  ├──► Patch 5: Debugger Entitlement Force True (selector 42)
  │      Bypasses com.apple.private.cs.debugger check
  │      Allows debug memory mapping for all processes
  │
  └──► Patches 1–2: CodeSignature Hash Bypass (selector 24)
         Independent — bypasses CS hash validation in the signature chain
```

### Boot-time flow

1. TXM initializes → `sub_FFFFFFF017023A20` runs → **Patch 6** forces devmode ON
2. Process loads → selector 24 validates CodeSignature → **Patches 1–2** skip hash check
3. Process requests entitlements → selector 41 → **Patch 3** grants get-task-allow
4. Debugger attaches → selector 42 → **Patch 4** pre-sets flag + **Patch 5** grants debugger ent
5. Debug mapping succeeds → LLDB can attach to any process

---

## Summary Table

| #   | File Offset | VA                   | Function                                     | Patch                  | Purpose                           |
| --- | ----------- | -------------------- | -------------------------------------------- | ---------------------- | --------------------------------- |
| 1   | `0x313ec`   | `0xFFFFFFF0170353EC` | `sub_FFFFFFF0170353B8` (CS hash validator)   | NOP                    | Remove hash flag load             |
| 2   | `0x313f4`   | `0xFFFFFFF0170353F4` | `sub_FFFFFFF0170353B8` (CS hash validator)   | NOP                    | Skip hash flag extraction call    |
| 3   | `0x1f5d4`   | `0xFFFFFFF0170235D4` | `sub_FFFFFFF017023558` (selector 41)         | `MOV X0, #1`           | Force get-task-allow = true       |
| 4   | `0x2717c`   | `0xFFFFFFF01702B17C` | `sub_FFFFFFF01702AE80` (dispatcher, case 42) | `B shellcode`          | Redirect to shellcode cave        |
| 4a  | `0x5d3b4`   | `0xFFFFFFF0170613B4` | code cave (zeros)                            | `NOP`                  | Shellcode padding                 |
| 4b  | `0x5d3b8`   | `0xFFFFFFF0170613B8` | code cave                                    | `MOV X0, #1`           | Set value for flag                |
| 4c  | `0x5d3bc`   | `0xFFFFFFF0170613BC` | code cave                                    | `STRB W0, [X20,#0x30]` | Force get-task-allow flag         |
| 4d  | `0x5d3c0`   | `0xFFFFFFF0170613C0` | code cave                                    | `MOV X0, X20`          | Restore original instruction      |
| 4e  | `0x5d3c4`   | `0xFFFFFFF0170613C4` | code cave                                    | `B back`               | Return to dispatcher              |
| 5   | `0x1f3b8`   | `0xFFFFFFF0170233B8` | `sub_FFFFFFF017023368` (selector 42)         | `MOV W0, #1`           | Force debugger entitlement = true |
| 6   | `0x1FA58`   | `0xFFFFFFF017023A58` | `sub_FFFFFFF017023A20` (devmode init)        | NOP                    | Force developer mode ON           |

**Total**: 6 logical patches, 11 instruction modifications (counting shellcode), enabling:

- CodeSignature bypass (patches 1–2)
- Universal get-task-allow (patches 3–4)
- Universal debugger entitlement (patch 5)
- Forced developer mode (patch 6)
