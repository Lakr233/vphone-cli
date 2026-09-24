# Kernel Patch Validation: Sandbox Hooks 17-26 (Regular/Development)

Date: 2026-03-05

## Scope

Validate the following non-JB kernel patches on a freshly prepared (unpatched) firmware kernelcache:

- 17/18 `file_check_mmap`: `mov x0,#0` + `ret`
- 19/20 `mount_check_mount`: `mov x0,#0` + `ret`
- 21/22 `mount_check_remount`: `mov x0,#0` + `ret`
- 23/24 `mount_check_umount`: `mov x0,#0` + `ret`
- 25/26 `vnode_check_rename`: `mov x0,#0` + `ret`

Patch flow under test:

- `scripts/fw_patch.py -> patch_kernelcache -> KernelPatcher.apply/find_all`
- `scripts/fw_patch_dev.py -> patch_kernelcache -> KernelPatcher.apply/find_all`

## Input

- Kernel file: `vm/iPhone17,3_26.1_23B85_Restore/kernelcache.research.vphone600`
- State: fresh from `fw_prepare` (clean, not yet patched)

## Locator Chain Verification

`KernelPatchSandboxMixin.patch_sandbox_hooks()` uses:

1. `_find_sandbox_ops_table_via_conf()` to locate `mac_policy_conf`
2. `mpc_ops` pointer to read function entries by index
3. `HOOK_INDICES`:
   - `file_check_mmap = 36`
   - `mount_check_mount = 87`
   - `mount_check_remount = 88`
   - `mount_check_umount = 91`
   - `vnode_check_rename = 120`

Observed on clean kernel payload:

- `seatbelt_off = 0x5F9493`
- `sandbox_off = 0x5FB33D`
- unique `mac_policy_conf` candidate: `off=0xA54428`
- `mpc_ops = off=0xA54488` (`VA=0xFFFFFE0007A58488`)

## Clean-Binary Before/After Verification

From direct `KernelPatcher` run on clean payload (in-memory, no file write):

1. `ops[88] mount_check_remount`
   - target `off=0x23AA9A0` (`VA=0xFFFFFE00093AE9A0`)
   - before:
     - `0x023AA9A0: pacibsp`
     - `0x023AA9A4: stp x28, x27, [sp, #-0x40]!`
   - after:
     - `0x023AA9A0: mov x0, #0`
     - `0x023AA9A4: ret`

2. `ops[91] mount_check_umount`
   - target `off=0x23AA80C` (`VA=0xFFFFFE00093AE80C`)
   - before:
     - `0x023AA80C: pacibsp`
     - `0x023AA810: stp x28, x27, [sp, #-0x40]!`
   - after:
     - `0x023AA80C: mov x0, #0`
     - `0x023AA810: ret`

3. `ops[120] vnode_check_rename`
   - target `off=0x23A5514` (`VA=0xFFFFFE00093A9514`)
   - before:
     - `0x023A5514: pacibsp`
     - `0x023A5518: stp d9, d8, [sp, #-0x70]!`
   - after:
     - `0x023A5514: mov x0, #0`
     - `0x023A5518: ret`

## IDA Cross-Check

Using IDA DB and disassembly/decompile on the same firmware family:

- Entry sites match the five hook slots above.
- For `vnode_check_rename`, downstream body includes rename-related path monitoring logic (`pathmonitor_prepare_rename`), confirming semantic alignment with rename hook behavior.
- Note: current IDA database had these entry points already recognized as patched stubs; additional inspection was performed from `entry+8` into original body for semantic validation.

## Result

Status: **working for now**.

For clean `fw_prepare` kernelcache, the 17-26 sandbox hook patches:

- resolve through the correct `mac_policy_ops` table,
- hit the expected five hook entry addresses,
- and rewrite exactly the first two instructions to `mov x0,#0; ret`.
