# JB-23b `patchThreadSetStateEntitlementFlag`

## Scope

Opt-in Frida Stalker patch. Emitted only when firmware patching uses `--frida`
(`KernelJBPatcher.applyFrida`). Baseline JB/EXP firmware is byte-identical when
off (26.4 emits 83 kernel-jb records without `--frida`, 85 with).

## Problem

Frida Stalker follows an existing thread by rewriting its core CPU registers via
the `thread_set_state` MIG routine, which lands in `thread_set_state_from_user()`.
That path passes:

```c
// osfmk/kern/thread_act.c
thread_set_state_from_user(...)
    -> thread_set_state_internal(..., TSSF_TRANSLATE_TO_USER | TSSF_CHECK_ENTITLEMENT);  // 0x1 | 0x200 = 0x201
```

`thread_set_state_internal()` (with `thread_set_state_allowed()` inlined) then, on
any flags carrying `TSSF_CHECK_ENTITLEMENT`, requires the caller task to hold
`com.apple.private.thread-set-state`. Frida's target does not, so the kernel
raises `GUARD_TYPE_MACH_PORT / THREAD_SET_STATE` and terminates it.

## Approach — clear the flag, don't NOP the check

Instead of NOPing an entitlement-failure branch inside `thread_set_state_allowed()`,
clear `TSSF_CHECK_ENTITLEMENT` (bit 9, 0x200) in the flags the *user setters* pass:

```asm
mov  w6, #0x201        // before  (TSSF_TRANSLATE_TO_USER | TSSF_CHECK_ENTITLEMENT)
mov  w6, #0x1          // after   (TSSF_TRANSLATE_TO_USER only)
```

`w6` is the 7th argument to `thread_set_state_internal` (`flags`) by the AArch64
calling convention. Clearing bit 9:

- `TSSF_TRANSLATE_TO_USER` (0x1) is preserved, so user-pointer translation on the
  `from_user` path is unchanged.
- Both entitlement-gated branches in `thread_set_state_allowed()` (the
  core-register and fatal-PAC-debug clauses, each `flags & TSSF_CHECK_ENTITLEMENT`)
  fall through to "allowed" — the function's first test is `tbnz w6, #9`, which is
  now not taken, so a non-mach-exception thread returns allowed immediately.
- The `TH_IN_MACH_EXCEPTION` guard (independent of this flag) stays enforced.

This is narrower and more source-faithful than editing the check: it disables the
entitlement requirement only for user-initiated `thread_set_state`, at the exact
call sites that request it.

## Reveal Procedure

1. `findString("com.apple.private.thread-set-state")`.
2. `findStringRefs` → all ADRP+ADD xrefs; group by `findFunctionStart`. Require
   they resolve to a single function — `thread_set_state_internal` (the entitlement
   checks are inlined there). Recover `[fnStart, fnEnd)` via `findFuncEnd`.
3. Scan code for direct `b`/`bl` whose target lands in `[fnStart - 0x10, fnEnd)`
   (the internal function's entry, allowing a small landing-pad lead-in).
4. For each such call, scan back up to 8 instructions for `mov w6, #0x201`
   (`w6` = flags; abandon if `w6` is otherwise written first).
5. Patch each such setter to `mov w6, #0x1` via `ARM64Encoder.encodeMovzW`,
   Capstone-verifying the re-encode decodes to `mov/movz w6, #1`.

No file offsets, VAs, register numbers, or preassembled bytes are hardcoded.
Kernels without the shape are skipped without changing bytes (fail-open no-op),
and the patch only runs under `--frida`.

## Static Validation — 26.4

Kernel: `ipsws/c0ecdb4b…/kernelcache.research.vphone600`, UUID
`BCD06230-CCBE-8E48-50FF-D9C166D83CD5`.

`patch-component --component kernel-jb --target-os 26.4 --frida` emits exactly two
`kernelcache_frida.thread_set_state_entitlement_flag` records:

```text
0x01D95720: mov w6, #0x201 -> mov w6, #0x1
0x01D9594C: mov w6, #0x201 -> mov w6, #0x1
```

(VA `0xfffffe0008d99720` / `0xfffffe0008d9994c` — the `thread_set_state_from_user`
setter and the inlined `act_set_state_from_user` setter, both feeding the same
`thread_set_state_internal` at `0xfffffe0008d5c170`.) Without `--frida`, zero such
records are emitted.

## Notes

- The 26.4 research kernel has no `tss_should_crash` early-out in the compiled
  `thread_set_state_allowed()` (it goes straight to `tbnz w6, #9`), so the
  DEVELOPMENT boot-arg bypass is not available — a code patch is required.
- Companion: Frida Stalker's repeated `VM_PROT_COPY` overwrite also needs the
  `vm_map_delete` immutable-code fix — JB-25c
  (`patch_vm_map_delete_immutable_code.md`), applied together under `--frida`.
