# Kernel Patch Validation: Base 16-20 (Regular/Development)

Date: 2026-03-05

## Scope

Validate the following non-JB kernel patches on a freshly prepared (unpatched) firmware kernelcache:

- 16 `patch_apfs_get_dev_by_role_entitlement`
- 17/18 `patch_sandbox_hooks file_check_mmap` (`mov x0,#0; ret`)
- 19/20 `patch_sandbox_hooks mount_check_mount` (`mov x0,#0; ret`)

Patch flow under test:

- `scripts/fw_patch.py -> patch_kernelcache -> KernelPatcher.apply/find_all`
- `scripts/fw_patch_dev.py -> patch_kernelcache -> KernelPatcher.apply/find_all`

## Input

- Kernel file: `vm/iPhone17,3_26.1_23B85_Restore/kernelcache.research.vphone600`
- State: fresh from `fw_prepare` (clean, not yet patched)

## Code-Path Confirmation

Both Regular and Development call the same base kernel patcher path:

- `scripts/fw_patch.py:235` (`patch_kernelcache`)
- `scripts/fw_patch_dev.py:18` (reuses `patch_kernelcache` from `fw_patch.py`)
- `scripts/patchers/kernel.py:56` (`KernelPatcher.find_all` ordering)

## Clean-Binary Emit Verification

Direct `KernelPatcher` run on clean payload (in-memory, no file write) produced:

### Patch 16 (`handle_get_dev_by_role`)

- `off=0x0248AB50` (`VA=0xFFFFFE000948EB50`)
  - before: `cbz x0, #0x248abd8`
  - after: `nop`
- `off=0x0248AB64` (`VA=0xFFFFFE000948EB64`)
  - before: `cbz w0, #0x248abd8`
  - after: `nop`
- `off=0x0248AC24` (`VA=0xFFFFFE000948EC24`)
  - before: `cbz w0, #0x248adac`
  - after: `nop`

Target deny blocks decode to line-tagged error paths:

- target `0xFFFFFE000948EBD8` contains `mov w8, #0x332d`
- target `0xFFFFFE000948EDAC` contains `mov w8, #0x333b`

This matches the intended entitlement/context deny bypass.

### Patch 17/18 (`file_check_mmap`)

- `off=0x023AC528` (`VA=0xFFFFFE00093B0528`)
  - before: `pacibsp`
  - after: `mov x0, #0`
- `off=0x023AC52C` (`VA=0xFFFFFE00093B052C`)
  - before: `stp x28, x27, [sp, #-0x30]!`
  - after: `ret`

### Patch 19/20 (`mount_check_mount`)

- `off=0x023AAB58` (`VA=0xFFFFFE00093AEB58`)
  - before: `pacibsp`
  - after: `mov x0, #0`
- `off=0x023AAB5C` (`VA=0xFFFFFE00093AEB5C`)
  - before: `stp x28, x27, [sp, #-0x30]!`
  - after: `ret`

## Sandbox Ops-Table Mapping Proof

From clean payload using the same locator logic as patcher (`_find_sandbox_ops_table_via_conf`):

- `mac_policy_conf` found at `off=0x00A54428`
- `mpc_ops` found at `off=0x00A54488` (`VA=0xFFFFFE0007A58488`)

Relevant entries:

- index 36 (`file_check_mmap`):
  - entry `VA=0xFFFFFE0007A585A8`
  - function `VA=0xFFFFFE00093B0528`
- index 87 (`mount_check_mount`):
  - entry `VA=0xFFFFFE0007A58740`
  - function `VA=0xFFFFFE00093AEB58`

## IDA Cross-Check

IDA database used: `/Users/qaq/Desktop/kernelcache.research.vphone600.macho`.

- APFS function containing Patch 16 sites decompiles to `sub_FFFFFE000948EB10`; branch targets from the three CBZ sites land on the expected entitlement/error logger blocks (`0x332d`, `0x333b` tags).
- Data xrefs in IDA confirm sandbox function pointers are sourced from ops entries:
  - `0xFFFFFE0007A585A8 -> 0xFFFFFE00093B0528`
  - `0xFFFFFE0007A58740 -> 0xFFFFFE00093AEB58`

Note: this IDA DB already had those two sandbox entry points rendered as stubs (`mov x0,#0; ret`) from prior work; raw clean-byte "before" evidence above is taken from the fresh IM4P payload, not from patched IDB bytes.

## XNU Reference Cross-Validation (2026-03-06)

Reference source: `research/xnu` (apple-oss-distributions/xnu, shallow clone).

What XNU confirms:

- `ENOATTR` is `93` (`bsd/sys/errno.h`), matching the mount-side `Attribute not found` decode path used in analysis docs.
- MACF file/mount hooks exist in policy ops:
  - `mpo_file_check_mmap`
  - `mpo_mount_check_mount`
  - `security/mac_policy.h`
- Corresponding call sites are present in framework/syscall paths:
  - `mac_file_check_mmap` -> `MAC_CHECK(file_check_mmap, ...)` (`security/mac_file.c`)
  - `mac_mount_check_mount` -> `MAC_CHECK(mount_check_mount, ...)` (`security/mac_vfs.c`)
  - mount syscall path invokes `mac_mount_check_mount` (`bsd/vfs/vfs_syscalls.c`)

What XNU cannot directly confirm for this patch group:

- APFS-private targets in Patch 16:
  - `handle_get_dev_by_role`
  - `APFSVolumeRoleFind`
  - entitlement string `com.apple.apfs.get-dev-by-role`
- These symbols/paths are not present in open-source XNU tree.

Interpretation:

- Patch 17-20 semantics are additionally supported by XNU MACF interfaces/call wiring.
- Patch 16 target correctness remains IDA/runtime-byte authoritative for the shipping kernelcache.

## Result

Status: **working for now**.

For clean `fw_prepare` kernelcache, patches 16-20:

1. are located by deterministic, structure-aware anchors,
2. hit the intended APFS deny branches and sandbox hook entrypoints, and
3. rewrite exactly the intended instructions.
