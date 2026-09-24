# JB-25c `patchVmMapDeleteImmutableCode`

## Scope

Opt-in Frida Stalker patch. Emitted only under `--frida`
(`KernelJBPatcher.applyFrida`). Companion to JB-23b (thread_set_state); together
they give Frida Stalker existing-thread following and repeated re-instrumentation.

## Problem

Frida Stalker instruments code by a write-then-flip: allocate, write RW, then
`vm_protect(VM_PROT_COPY)` to executable. On a CSM device this leaves a
CSM-associated **permanent** `vm_map_entry` at **current protection RW, maximum
protection RWX**. When Stalker later overwrites that region (re-instrumentation),
the fixed-overwrite path calls `vm_map_delete` on the old entry, whose
permanent-entry handler has a debugger exception (`osfmk/vm/vm_map.c:8855`):

```c
} else if ((flags & VM_MAP_REMOVE_IMMUTABLE_CODE) &&
    (entry->protection & VM_PROT_EXECUTE) &&   // CURRENT protection
    developer_mode_state()) {
    entry->vme_permanent = FALSE;              // allow the debugger to undo it
}
```

The entry is current-RW, so `entry->protection & VM_PROT_EXECUTE` is false, the
exception is skipped, the entry stays permanent, and the overwrite returns
`KERN_PROTECTION_FAILURE`.

## Approach — test max protection instead of current

Retarget the execute test from current protection to maximum protection. The
packed flags word at `[entry, #0x38]` (see `vm_map_xnu.h`: `VME_ALIAS_BITS=12` +
`VME_OFFSET_BITS=52` fill qword0, so `protection:3`/`max_protection:4` land in
qword1's low half) places:

- current protection EXECUTE = **bit 9**
- max protection EXECUTE = **bit 13**

So the fix is `#9 → #13` on the immutable-code execute test — "allow a debugger to
undo a mapping that is *capable of* execution," which is exactly Frida's RW/max-RWX
entry. This is strictly narrower than converting every `KERN_PROTECTION_FAILURE`
to success.

## Semantic Reveal Procedure

No offsets, VAs, registers, or bytes are hardcoded. For each candidate:

1. Pre-filter for `ldr wF, [xE, #0x38]` (the packed `vm_map_entry` flags word).
2. Require `tbz wF, #19` immediately after (`vme_permanent`).
3. Require the inlined `developer_mode_state()` read in the window: a byte load
   whose bit 0 is then tested (`ldrb wD,[…] ; … ; tbz/tbnz wD,#0`). This ties the
   match to the immutable-code gate rather than any packed-flags load.
4. Identify the current-X test (`wF`, bit 9) bound to the cluster:
   - **Shape A**: `tbz wF,#9,T` immediately following a remove-flags argument test
     `tbz wArg,#b,T` (different register, **same** fallback target `T`).
   - **Shape B**: `tbnz wF,#9,P` (after the developer-mode gate) whose target `P`
     equals the `vme_permanent` test's target (the permanent-continuation path).
5. Retarget bit 9 → 13, preserving sense (`tbz`/`tbnz`), source register, and
   target, via `ARM64Encoder.encodeTestBitBranch`; Capstone round-trip verify the
   re-encode's mnemonic, bit (13), and target before emitting.

Exactly two gates must be found (the compiler outlines the two source paths); any
other count fails closed. The **later CSM current-X `#9` test** in the same window
is excluded because its branch target is neither the remove-flags fallback nor the
permanent-continuation target.

Robustness notes vs. a naive scan:
- The remove-flags bit is matched **structurally** (a test of a register other than
  the entry-flags register), never by a source constant — `VM_MAP_REMOVE_*` bit
  numbers drift across XNU versions (this kernel tests bit 6; the reference source
  defines `VM_MAP_REMOVE_IMMUTABLE_CODE = 0x080`).
- Bits 9/13/19 are protection/permanent **struct** bits, stable across versions.

## 26.4 Static Validation

Kernel: `ipsws/c0ecdb4b…/kernelcache.research.vphone600`.
`patch-component --component kernel-jb --target-os 26.4 --frida` emits exactly two
`kernelcache_frida.vm_map_delete_immutable_code` records:

```text
0x01DBE14C: tbz  w8, #9, 0x1dbe16c -> tbz  w8, #0xd, 0x1dbe16c   (shape-A)
0x01DBE828: tbnz w8, #9, 0x1dbe958 -> tbnz w8, #0xd, 0x1dbe958   (shape-B)
```

Branch targets are unchanged; only the tested bit index differs. Without `--frida`,
zero such records are emitted (baseline 83; `--frida` 87 = 83 + 2 thread_set_state
+ 2 vm_map_delete).

## Validation Requirements

- `swift test --filter ARM64EncoderTests` passes (round-trip of the bit-13 encode).
- 26.4 dry-run emits exactly two `vm_map_delete_immutable_code` records.
- Before/after disassembly differs only in the tested bit index (9 → 13).
- If the semantic candidate count is not exactly two, the patch fails closed.
