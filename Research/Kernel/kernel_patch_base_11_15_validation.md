# Base Kernel Patch Validation: #11-#15 (Regular + Dev)

Date: 2026-03-05
Scope: non-jailbreak shared kernel patch flow (`fw_patch` + `fw_patch_dev`)
Target kernel input: `vm/iPhone17,3_26.1_23B85_Restore/kernelcache.research.vphone600`

## Goal

Validate that base patch items #11-#15:

1. hit the intended code paths,
2. rewrite the intended instruction shape,
3. preserve expected local control flow semantics.

## Source-of-truth path

- Regular flow calls `patch_kernelcache()` in `scripts/fw_patch.py`.
- Development flow imports and reuses the same `patch_kernelcache()` from `scripts/fw_patch.py`.
- `KernelPatcher.find_all()` order defines patch indices.

Key code references:

- `scripts/fw_patch.py:235`
- `scripts/fw_patch_dev.py:12`
- `scripts/patchers/kernel.py:56`
- `scripts/patchers/kernel_patch_dyld_policy.py`
- `scripts/patchers/kernel_patch_apfs_graft.py`
- `scripts/patchers/kernel_patch_apfs_mount.py`

## Verification method

1. Load clean IM4P payload from `kernelcache.research.vphone600`.
2. Run `KernelPatcher.find_all()` and capture emitted offsets/descriptions.
3. Compare instruction bytes before/after for #11-#15.
4. Assert matcher semantics programmatically:
   - dyld patch pair has `BL + conditional-on-w0` and distinct BL targets.
   - `_apfs_graft` BL target equals `validate_on_disk_root_hash` function.
   - `_apfs_mount_upgrade_checks` target is `BL + TBNZ w0` with small leaf callee.
   - `_handle_fsioc_graft` BL target equals `validate_payload_and_manifest` function.
5. Cross-check in IDA:
   - patch site belongs to expected function region (string xref/function context).

## Results

Base VA: `0xFFFFFE0007004000`

### #11 patch_check_dyld_policy (@2)

- file offset: `0x016410C8`
- VA: `0xFFFFFE00086450C8`
- before: `bl #0x1638384`
- after: `mov w0, #1`
- next instruction (unchanged): `tbnz w0, #0, ...`
- matcher assertions:
  - `@1` and `@2` are both `BL` followed by conditional branch on `w0`: PASS
  - BL targets are different: PASS
- IDA context:
  - site in function `sub_FFFFFE000864507C`
  - same function references string
    `com.apple.developer.swift-playgrounds-app.development-build`

### #12 patch_apfs_graft

- file offset: `0x0242011C`
- VA: `0xFFFFFE000942411C`
- before: `bl #0x246d398`
- after: `mov w0, #0`
- next instruction: `cbz w0, ...`
- matcher assertion:
  - BL target equals `_find_validate_root_hash_func()` result: PASS
- IDA context:
  - site in function `sub_FFFFFE000942326C` (apfs_graft call path)
  - target function aligns with `authenticate_root_hash` string-referenced routine
    (`sub_FFFFFE00094711CC`/entry region at `0x...9471398`)

### #13 patch_apfs_vfsop_mount_cmp

- file offset: `0x02475044`
- VA: `0xFFFFFE0009479044`
- before: `cmp x0, x8`
- after: `cmp x0, x0`
- adjacent shape (before patch):
  - `bl ...`
  - `adrp x8, ...`
  - `ldr x8, [x8, ...]`
  - `ldr x8, [x8]`
  - `cmp x0, x8`
  - `b.eq ...`
- interpretation: correct hit on mount path thread-vs-kernel-task comparison.

### #14 patch_apfs_mount_upgrade_checks

- file offset: `0x02476C00`
- VA: `0xFFFFFE000947AC00`
- before: `tbnz w0, #0xe, ...`
- after: `mov w0, #0`
- previous instruction: `bl #0xCC6144`
- matcher assertion:
  - previous BL target behaves as small leaf (ret within first `0x20` bytes): PASS
- IDA context:
  - site in function `sub_FFFFFE000947AB88`
  - function region references `apfs_mount_upgrade_checks`

### #15 patch_handle_fsioc_graft

- file offset: `0x0248C800`
- VA: `0xFFFFFE0009490800`
- before: `bl #0x2416bd4`
- after: `mov w0, #0`
- next instruction: `cbz w0, ...`
- matcher assertion:
  - BL target equals `_find_validate_payload_manifest_func()` result: PASS
- IDA context:
  - site in function `sub_FFFFFE000949074C`
  - target function aligns with `validate_payload_and_manifest`
    (`sub_FFFFFE000941ABD4`)

## Input consistency note

- VM clean IM4P payload and IDA-loaded macho have same size but different hash.
- Dword diff count is `25`, and the diff set includes all expected base patch sites.
- This is consistent with IDA sample being the patched image variant for the same kernel.

## Conclusion

For `kernelcache.research.vphone600` prepared from clean firmware:

- patch #11 (`_check_dyld_policy_internal @2`) works and hits intended `BL` site.
- patch #12 (`_apfs_graft`) works and hits intended validation `BL` site.
- patch #13 (`_apfs_vfsop_mount cmp`) works and hits intended compare site.
- patch #14 (`_apfs_mount_upgrade_checks`) works and hits intended `TBNZ w0` site.
- patch #15 (`_handle_fsioc_graft`) works and hits intended validation `BL` site.

Status: **working for now** (correct semantic hit + instruction rewrite on this kernel variant).
