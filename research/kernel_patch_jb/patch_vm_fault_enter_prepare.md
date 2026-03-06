# B9 `patch_vm_fault_enter_prepare` — re-analysis (2026-03-06)

## Scope

- Kernel: `kernelcache.research.vphone600`
- Primary function: `vm_fault_enter_prepare` @ `0xfffffe0007bb8818`
- Existing patch point emitted by the patcher: `0xfffffe0007bb898c`
- Existing callee at that point: `sub_FFFFFE0007C4B7DC`
- Paired unlock callee immediately after the guarded block: `sub_FFFFFE0007C4B9A4`

## Executive Summary

The current `patch_vm_fault_enter_prepare` analysis was wrong.

The patched instruction at `0xfffffe0007bb898c` is **not** a runtime code-signing gate and **not** a generic policy-deny helper. It is the lock-acquire half of a `pmap_lock_phys_page()` / `pmap_unlock_phys_page()` pair used while consuming the page's `vmp_clustered` state.

So the current patch does this:

- skips the physical-page / PVH lock acquire,
- still executes the protected critical section,
- still executes the corresponding unlock,
- therefore breaks lock pairing and page-state synchronization inside the VM fault path.

That is fully consistent with a boot-time failure.

## What the current patcher actually matches

Current implementation: `scripts/patchers/kernel_jb_patch_vm_fault.py:7`

The matcher looks for this in-function shape:

- `BL target(rare)`
- `LDRB wN, [xM, #0x2c]`
- `TBZ/TBNZ wN, #bit, ...`

That logic resolves to exactly one site in `vm_fault_enter_prepare` and emits:

- VA: `0xFFFFFE0007BB898C`
- Patch: `944b0294 -> 1f2003d5`
- Description: `NOP [_vm_fault_enter_prepare]`

IDA disassembly at the matched site:

```asm
0xfffffe0007bb8988  MOV   X0, X27
0xfffffe0007bb898c  BL    sub_FFFFFE0007C4B7DC
0xfffffe0007bb8990  LDRB  W8, [X20,#0x2C]
0xfffffe0007bb8994  TBZ   W8, #5, loc_FFFFFE0007BB89C4
0xfffffe0007bb8998  LDR   W8, [X20,#0x1C]
...
0xfffffe0007bb89c0  STR   W8, [X20,#0x2C]
0xfffffe0007bb89c4  MOV   X0, X27
0xfffffe0007bb89c8  BL    sub_FFFFFE0007C4B9A4
```

The old assumption was: “call helper, then test a security flag, so NOP the helper.”

The re-analysis result is: the call is a lock acquire, the tested bit is `m->vmp_clustered`, and the second call is the matching unlock.

## PCC 26.1 Research: upstream site vs derived site

Using the user-loaded `PCC-CloudOS-26.1-23B85` `kernelcache.research.vphone600`, extracted locally to a temporary raw Mach-O, the upstream hard-coded site and our derived matcher do **not** land on the same instruction.

### Upstream hard-coded site

Upstream script site:

- raw file offset: `0x00BA9E1C`
- mapped VA in `26.1 research`: `0xFFFFFE0007BADE1C`
- instruction: `TBZ W22, #3, loc_...DE28`

Local disassembly around the upstream site:

```asm
0xfffffe0007bade10  CBZ   X27, loc_...DEE4
0xfffffe0007bade14  LDR   X0, [X27,#0x488]
0xfffffe0007bade18  B     loc_...DEE8
0xfffffe0007bade1c  TBZ   W22, #3, loc_...DE28   ; upstream NOP site
0xfffffe0007bade20  MOV   W23, #0
0xfffffe0007bade24  B     loc_...E004
0xfffffe0007bade28  ...
0xfffffe0007bade94  BL    0xfffffe0007f82428
0xfffffe0007bade98  CBZ   W0, loc_...DF54
```

This means the upstream patch is not hitting the later helper call directly. It is patching a branch gate immediately before a larger validation/decision block. Replacing this `TBZ` with `NOP` forces fall-through into:

- `MOV W23, #0`
- `B loc_...E004`

So the likely effect is to skip the subsequent validation path entirely.

### Current derived matcher site

Current derived `patch_vm_fault_enter_prepare()` site on the **same 26.1 research raw**:

- raw file offset: `0x00BA9BB0`
- mapped VA: `0xFFFFFE0007BADBB0`
- instruction: `BL 0xFFFFFE0007C4007C`

The local patcher was run directly on the extracted `26.1 research` raw Mach-O and emitted:

- `0x00BA9BB0  NOP [_vm_fault_enter_prepare]`

Local disassembly around the derived site:

```asm
0xfffffe0007badbac  MOV   X0, X27
0xfffffe0007badbb0  BL    0xfffffe0007c4007c   ; derived NOP site
0xfffffe0007badbb4  LDRB  W8, [X20,#0x2C]
0xfffffe0007badbb8  TBZ   W8, #5, loc_...DBE8
...
0xfffffe0007badbe8  MOV   X0, X27
0xfffffe0007badbec  BL    0xfffffe0007c40244
```

And the two helpers decode as the same lock/unlock pair seen in later analysis:

- `0xFFFFFE0007C4007C`: physical-page indexed lock acquire path (`LDXR` / `CASA` fast path, contended lock path)
- `0xFFFFFE0007C40244`: matching unlock path

### Meaning of the mismatch

This is the key clarification:

- the **upstream** patch is very likely semantically related to the `vm_fault_enter_prepare` runtime validation path on `26.1 research`;
- the **derived patcher** in this repository does **not** reproduce that upstream site;
- instead, it drifts earlier in the same larger function region and NOPs a lock-acquire call.

So the most likely situation is **not** “the upstream author typed the wrong function name.”

The more likely situation is:

1. upstream had a real site in `26.1 research`;
2. our repository later generalized that idea into a pattern matcher;
3. that matcher overfit the wrong local shape (`BL` + `LDRB [#0x2c]` + `TBZ`) and started hitting the wrong block.

In other words: the current bug is much more likely a **bad derived matcher / bad retarget**, not proof that the original upstream `26.1` patch label was bogus.

## IDA evidence: what the callees really are

### `sub_FFFFFE0007C4B7DC`

IDA shows a physical-page-index based lock acquisition routine, not a deny/policy check:

- takes `X0` as page number / index input,
- checks whether the physical page is in-range,
- on the normal path acquires a lock associated with that physical page,
- on contended paths may sleep / block,
- returns only after the lock is acquired.

Key observations from IDA:

- the function begins by deriving an indexed address from `X0` (`UBFIZ X9, X0, #0xE, #0x20`),
- it performs lock acquisition with `LDXR` / `CASA` on a fallback lock or calls into a lower lock primitive,
- it contains a contended-wait path (`assert_wait`, `thread_block` style flow),
- it does **not** contain a boolean policy return used by the caller.

This matches `pmap_lock_phys_page(ppnum_t pn)` semantics.

### `sub_FFFFFE0007C4B9A4`

IDA shows the paired unlock routine:

- same page-number based addressing scheme,
- direct fast-path jump into a low-level unlock helper for the backup lock case,
- range-based path that reconstructs a `locked_pvh_t`-like wrapper and unlocks the per-page PVH lock.

This matches `pmap_unlock_phys_page(ppnum_t pn)` semantics.

## XNU source mapping

The matched basic block in `vm_fault_enter_prepare()` maps cleanly onto the `m->vmp_pmapped == FALSE && m->vmp_clustered` handling in XNU.

Relevant source: `research/reference/xnu/osfmk/vm/vm_fault.c:3958`

```c
if (m->vmp_pmapped == FALSE) {
    if (m->vmp_clustered) {
        if (*type_of_fault == DBG_CACHE_HIT_FAULT) {
            if (object->internal) {
                *type_of_fault = DBG_PAGEIND_FAULT;
            } else {
                *type_of_fault = DBG_PAGEINV_FAULT;
            }
            VM_PAGE_COUNT_AS_PAGEIN(m);
        }
        VM_PAGE_CONSUME_CLUSTERED(m);
    }
}
```

The lock/unlock comes from `VM_PAGE_CONSUME_CLUSTERED(mem)` in `research/reference/xnu/osfmk/vm/vm_page_internal.h:999`:

```c
#define VM_PAGE_CONSUME_CLUSTERED(mem)                          \
    MACRO_BEGIN                                                 \
    ppnum_t __phys_page;                                        \
    __phys_page = VM_PAGE_GET_PHYS_PAGE(mem);                   \
    pmap_lock_phys_page(__phys_page);                           \
    if (mem->vmp_clustered) {                                   \
        vm_object_t o;                                          \
        o = VM_PAGE_OBJECT(mem);                                \
        assert(o);                                              \
        o->pages_used++;                                        \
        mem->vmp_clustered = FALSE;                             \
        VM_PAGE_SPECULATIVE_USED_ADD();                         \
    }                                                           \
    pmap_unlock_phys_page(__phys_page);                         \
    MACRO_END
```

And those helpers are defined here:

- `research/reference/xnu/osfmk/arm64/sptm/pmap/pmap.c:7520` — `pmap_lock_phys_page(ppnum_t pn)`
- `research/reference/xnu/osfmk/arm64/sptm/pmap/pmap.c:7535` — `pmap_unlock_phys_page(ppnum_t pn)`
- `research/reference/xnu/osfmk/arm64/sptm/pmap/pmap_data.h:330` — `pvh_lock(unsigned int index)`
- `research/reference/xnu/osfmk/arm64/sptm/pmap/pmap_data.h:497` — `pvh_unlock(locked_pvh_t *locked_pvh)`

## Why the current patch can break boot

The current patch NOPs only the acquire side:

- before: `BL sub_FFFFFE0007C4B7DC`
- after: `NOP`

But the surrounding code still:

- reads `m->vmp_clustered`,
- may increment `object->pages_used`,
- clears `m->vmp_clustered`,
- calls `sub_FFFFFE0007C4B9A4` unconditionally afterwards.

That means the patch turns a balanced critical section into:

1. no lock acquire,
2. mutate shared page/object state,
3. unlock a lock that was never acquired.

Concrete risks:

- PVH / backup-lock state corruption,
- waking or releasing waiters against an unowned lock,
- racing `m->vmp_clustered` / `object->pages_used` updates during active fault handling,
- early-boot hangs or panics when clustered pages are first faulted in.

This is a much stronger explanation for the observed boot failure than the old “wrong security helper” theory.

## What this patch actually changes semantically

If applied successfully, the patch does **not** bypass code-signing validation.

It only removes synchronization from this clustered-page bookkeeping path:

- page-in accounting (`DBG_CACHE_HIT_FAULT` -> `DBG_PAGEIND_FAULT` / `DBG_PAGEINV_FAULT`),
- `object->pages_used++`,
- `m->vmp_clustered = FALSE`,
- speculative-page accounting.

So the effective behavior is:

- **not** “allow weird userspace methods,”
- **not** “disable vm fault code-signing rejection,”
- **not** “bypass a kernel deny path,”
- only “break the lock discipline around clustered-page consumption.”

For the jailbreak goal, this patch is mis-targeted.

## Where the real security-relevant logic is in this function

Two genuinely security-relevant regions exist in the same XNU function, but they are **not** the current patch site:

1. `pmap_has_prot_policy(...)` handling in `research/reference/xnu/osfmk/vm/vm_fault.c:3943`
   - this is where protection-policy constraints are enforced for the requested mapping protections.
2. `vm_fault_validate_cs(...)` in `research/reference/xnu/osfmk/vm/vm_fault.c:3991`
   - this is the runtime code-signing validation path.

So if the jailbreak objective is “allow runtime execution / invocation patterns without kernel interception,” the current B9 patch is aimed at the wrong block.

## XNU source cross-mapping for the upstream 26.1 site

The `26.1 research` upstream site now maps cleanly to the `cs_bypass` fast-path semantics in XNU.

### Field mapping

From the `vm_fault_enter_prepare` function prologue in `26.1 research`:

```asm
0xfffffe0007bada60  MOV   X21, X7        ; fault_type
0xfffffe0007bada64  MOV   X25, X3        ; prot*
0xfffffe0007bada74  LDP   X28, X8, [X29,#0x10]  ; fault_info, type_of_fault*
0xfffffe0007bada78  LDR   W22, [X28,#0x28]      ; fault_info flags word
```

The XNU struct layout confirms that `fault_info + 0x28` is the packed boolean flag word, and **bit 3 is `cs_bypass`**:

- `research/reference/xnu/osfmk/vm/vm_object_xnu.h:112`
- `research/reference/xnu/osfmk/vm/vm_object_xnu.h:116`

### Upstream site semantics

The upstream hard-coded instruction is:

```asm
0xfffffe0007bade1c  TBZ   W22, #3, loc_...DE28
0xfffffe0007bade20  MOV   W23, #0
0xfffffe0007bade24  B     loc_...E004
```

Since `W22.bit3 == fault_info->cs_bypass`, this branch means:

- if `cs_bypass == 0`: continue into the runtime code-signing validation / violation path
- if `cs_bypass == 1`: skip that path, force `is_tainted = 0`, and jump to the common success/mapping continuation

Patching `TBZ` -> `NOP` therefore forces the **`cs_bypass` fast path unconditionally**.

### XNU source correspondence

This aligns with the source-level fast path in `vm_fault_cs_check_violation()`:

- `research/reference/xnu/osfmk/vm/vm_fault.c:2831`
- `research/reference/xnu/osfmk/vm/vm_fault.c:2833`

```c
if (cs_bypass) {
    *cs_violation = FALSE;
} else if (VMP_CS_TAINTED(...)) {
    *cs_violation = TRUE;
} ...
```

and with the caller in `vm_fault_validate_cs()` / `vm_fault_enter_prepare()`:

- `research/reference/xnu/osfmk/vm/vm_fault.c:3208`
- `research/reference/xnu/osfmk/vm/vm_fault.c:3233`
- `research/reference/xnu/osfmk/vm/vm_fault.c:3991`
- `research/reference/xnu/osfmk/vm/vm_fault.c:3999`

So the upstream patch is best understood as:

- forcing `vm_fault_validate_cs()` to behave as though `cs_bypass` were already set,
- preventing runtime code-signing violation handling for this fault path,
- still preserving the rest of the normal page mapping flow.

This is fundamentally different from the derived repository matcher, which NOPs a `pmap_lock_phys_page()` call and breaks lock pairing.

## Proposed repair strategy

### Recommended fix for B9

Retarget `patch_vm_fault_enter_prepare` to the **upstream semantic site**, not the current lock-site matcher.

For `PCC 26.1 / 23B85 / kernelcache.research.vphone600`, the concrete patch is:

- file offset: `0x00BA9E1C`
- VA: `0xFFFFFE0007BADE1C`
- before: `76 00 18 36` (`TBZ W22, #3, ...`)
- after: `1F 20 03 D5` (`NOP`)

### Why this is the right site

- It is in the correct `vm_fault_enter_prepare` control-flow region.
- It matches XNU's `cs_bypass` logic, not an unrelated lock helper.
- It preserves lock/unlock pairing and page accounting.
- It reproduces the **intent** of the upstream `26.1 research` patch rather than the accidental behavior of the derived matcher.

### How to implement the new matcher

The current matcher should be replaced, not refined.

#### Do not match

- `BL` followed by `LDRB [X?,#0x2C]` and `TBZ/TBNZ`
- any site with a nearby paired lock/unlock helper call

#### Do match

Inside `vm_fault_enter_prepare`, find the unique gate with this semantic shape:

```asm
...                     ; earlier checks on prot/page state
CBZ   X?, error_path    ; load helper arg or zero
LDR   X0, [X?,#0x488]
B     <join>
TBZ   Wflags, #3, validation_path   ; Wflags = fault_info flags word
MOV   Wtainted, #0
B     post_validation_success
```

Where:

- `Wflags` is loaded from `[fault_info_reg, #0x28]` near the function prologue,
- bit `#3` is `cs_bypass`,
- the fall-through path lands at the common mapping continuation (`post_validation_success`),
- the branch target enters the larger runtime validation / violation block.

A robust implementation can anchor on:

1. resolved function `vm_fault_enter_prepare`
2. in-prologue `LDR Wflags, [fault_info,#0x28]`
3. later unique `TBZ Wflags, #3, ...; MOV W?, #0; B ...` sequence

### Prototype matcher result (2026-03-06)

A local prototype matcher was run against the extracted `PCC-CloudOS-26.1-23B85` `kernelcache.research.vphone600` raw Mach-O with these rules:

1. inside `vm_fault_enter_prepare`, discover the early `LDR Wflags, [fault_info,#0x28]` load,
2. track that exact `Wflags` register,
3. find `TBZ Wflags, #3, ...` followed immediately by `MOV W?, #0` and `B ...`.

Result:

- prologue flag load: `0xFFFFFE0007BADA78` -> `LDR W22, [X28,#0x28]`
- matcher hit count: `1`
- unique hit: `0xFFFFFE0007BADE1C`

This is the expected upstream semantic site and proves the repaired matcher can be made both specific and stable on `26.1 research` without relying on the old false-positive lock-call fingerprint.

### Validation guidance

For `26.1 research`, a repaired matcher should resolve to exactly one hit:

- `0x00BA9E1C`

and must **not** resolve to:

- `0x00BA9BB0`

If it still resolves to `0x00BA9BB0`, the matcher is still targeting the lock-pair block and is not fixed.

## Practical conclusion

### Verdict on the current patch

- Keep `patch_vm_fault_enter_prepare` disabled.
- Do **not** re-enable the current NOP at `0xFFFFFE0007BB898C`.
- Treat the previous “Skip fault check” description as incorrect for `vphone600` research kernel.

### Likely root cause of boot failure

Most likely root cause: unbalanced `pmap_lock_phys_page()` / `pmap_unlock_phys_page()` behavior in the hot VM fault path.

### Recommended next research direction

If we still want a B9-class runtime-memory patch, the next candidates to study are:

- `vm_fault_validate_cs()`
- `vm_fault_cs_check_violation()`
- `vm_fault_cs_handle_violation()`
- the `pmap_has_prot_policy()` / `cs_bypass` decision region

Those are the places that can plausibly affect runtime execution restrictions. The current B9 site cannot.

## Minimal safe recommendation for patch schedule

For now, the correct action is not “retarget this exact byte write,” but:

- leave `patch_vm_fault_enter_prepare` disabled,
- mark its prior purpose label as wrong,
- open a fresh analysis track for the real code-signing fault-validation path.

## Evidence summary

- Function symbol: `vm_fault_enter_prepare` @ `0xfffffe0007bb8818`
- Current patchpoint: `0xfffffe0007bb898c`
- Current matched callee: `sub_FFFFFE0007C4B7DC` -> `pmap_lock_phys_page()` equivalent
- Paired callee: `sub_FFFFFE0007C4B9A4` -> `pmap_unlock_phys_page()` equivalent
- XNU semantic match:
  - `research/reference/xnu/osfmk/vm/vm_fault.c:3958`
  - `research/reference/xnu/osfmk/vm/vm_page_internal.h:999`
  - `research/reference/xnu/osfmk/arm64/sptm/pmap/pmap.c:7520`
  - `research/reference/xnu/osfmk/arm64/sptm/pmap/pmap_data.h:330`
  - `research/reference/xnu/osfmk/arm64/sptm/pmap/pmap_data.h:497`
