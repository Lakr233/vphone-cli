# JB-25b `patch_vm_map_delete_immutable_code`

## Scope

This is an **opt-in Frida patch**. It is emitted only when firmware patching uses
`--frida`; baseline JB/EXP firmware is unchanged. During a fresh `vm create`, the same
option is forwarded to the JB/EXP host install, which stages the
`https://build.frida.re/` Sileo/APT source and an install marker. First boot installs
`re.frida.server` directly through APT, verifies its dpkg state, and does not write the
setup done marker until the required package is registered.

## Goal

Allow repeated debugger `VM_PROT_COPY` fixed-overwrites of CSM-associated permanent
USER_DEBUG mappings when the current protection is `RW` but the maximum protection is
still `RWX`. The patch changes only the immutable-code debugger exception; it does not
convert arbitrary `KERN_PROTECTION_FAILURE` results to success.

## XNU Source Correlation

Reference source: `research/reference/xnu`, tag `xnu-12377.1.9`.

`osfmk/vm/vm_map.c` uses the current entry protection in the permanent-entry debugger
exception:

```c
} else if ((flags & VM_MAP_REMOVE_IMMUTABLE_CODE) &&
    (entry->protection & VM_PROT_EXECUTE) &&
    developer_mode_state()) {
    entry->vme_permanent = FALSE;
}
```

A successful `vm_map_entry_cs_associate()` can set both `vme_permanent` and
`csm_associated`. Repeated write-then-flip operations can then present a packed entry
with current protection `RW` and maximum protection `RWX`. Testing current execute
rejects the next debugger overwrite even though executable capability remains in the
maximum protection.

## GDB Runtime Reveal

Kernel: `kernelcache.research.vphone600`, 26.4, UUID
`784F88D3-2AF5-3D4A-AB00-365607646E44`.

Clean reproduction:

```text
VM_PROT_COPY|RW  -> 0
RX               -> 0
VM_PROT_COPY|RWX -> 0
VM_PROT_COPY|RW  -> 2
```

At the exact fourth-call entry range, GDB stopped on the immutable-code execute gate
with packed entry word `0x088AB9C0`:

```text
protection         = 3 (RW)
max_protection     = 7 (RWX)
vme_permanent      = 1
csm_associated     = 1
vme_xnu_user_debug = 1
```

The taken control flow was:

```asm
tbnz w8, #9, allow       // current protection execute: not taken
...
b    failure
...
mov  w0, #2              // KERN_PROTECTION_FAILURE
```

The current-X bit 9 was clear while max-X bit 13 was set.

## Semantic Reveal Procedure

No file offset, VA, concrete register number, or preassembled replacement bytes are
used by the patcher.

1. Scan executable ranges for `ldr wFlags, [xEntry, #0x38]`, the packed
   `vm_map_entry` protection/permanent word.
2. Require an immediately associated `tbz wFlags, #19` (`vme_permanent`).
3. Require the local remove-flags `tbz ..., #6` immutable-code check.
4. Match one of two source-backed developer-mode control-flow forms:
   - Shape A: `tbz wFlags,#9,fallback` immediately after the immutable-code check,
     sharing its fallback target, followed by the developer-mode byte/bit-0 gate.
   - Shape B: developer-mode byte/bit-0 gate first, then
     `tbnz wFlags,#9,allow`, sharing the non-permanent allow target.
5. Require exactly two unique candidates and recover a valid containing function for
   each. The compiler may outline the two source paths into separate local helpers.
6. Preserve each decoded mnemonic, source register, and branch target; assemble the
   replacement with test bit 13 instead of bit 9.
7. Capstone-decode the generated instruction and verify branch sense, bit 13, and the
   original target before emitting either patch. The two replacements are all-or-none.

This context deliberately excludes later CSM current-X tests in the same local windows;
a shallow search for all `tbz/tbnz #9` instructions would patch the wrong policy gates.

## 26.4 Static Validation

Input: `/tmp/26.4-clean-running.dec`, extracted from the matching running kernel.

`patch-component --component kernel-jb --target-os 26.4` emitted exactly two records:

```text
0x01DBE14C: tbz  w8, #9, 0x1dbe16c -> tbz  w8, #0xd, 0x1dbe16c
0x01DBE828: tbnz w8, #9, 0x1dbe958 -> tbnz w8, #0xd, 0x1dbe958
```

The observed fourth-call failure used the second shape. The first shape covers the
sibling compiled permanent/immutable-code path.

## Runtime Validation — Fresh 26.4 Restore

A new `26.4-frida` VM was created end-to-end with the standard pipeline:

```text
prepare -> jb --frida patch -> DFU restore -> CFW install -> first boot
```

The firmware pass emitted 155 total records, including exactly two
`kernelcache_frida.vm_map_delete_immutable_code` records and the opt-in
`thread_set_state` record. With Frida 17.17.0 and the internal policy softener, the
same Sileo probe produced:

```text
COPY_RW       -> 0
RX            -> 0
COPY_RWX      -> 0
COPY_RW_again -> 0
```

The fourth call remained `rw-`, matching the intended write-then-flip workflow. A real
existing-thread Stalker test against an active Procursus `yes` process also completed:
5 call-summary batches, 81,920 calls, target remained alive.

## Validation Requirements

- `swift test --filter ARM64EncoderTests` passes.
- The 26.4 kernel dry-run emits exactly two
  `kernelcache_frida.vm_map_delete_immutable_code` records.
- Before/after disassembly differs only in bit index 9 to 13.
- Firmware is patched through the normal CFW pipeline with `--frida`, not by writing
  live kernel memory.
- Runtime reproduction changes only the fourth result from 2 to 0 and remains stable
  under a real Frida Stalker attach.
- If the semantic candidate count is not exactly two, the patch fails closed.
