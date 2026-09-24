# Binary Kernelcache Patch Verification Report

Date: 2026-02-27

## Scope

Verify that the dynamic kernel patch finder (`scripts/patchers/kernel.py`) produces
the same binary result as the legacy hardcoded patch list on vphone600, then
apply the dynamic patcher to a freshly extracted vresearch101 kernelcache.

## Inputs

- Original vphone600 raw kernel: `/tmp/kc_vphone600_orig.raw`
- vphone600 upstream hardcoded patch list: `super-tart-vphone-private/CFW/patch_fw.py`
- Dynamic patcher: `scripts/patchers/kernel.py`
- VM kernelcache image (vresearch101): `VM/iPhone17,3_26.1_23B85_Restore/kernelcache.research.vresearch101`

## Method

1. Apply legacy hardcoded patches to `/tmp/kc_vphone600_orig.raw` using binary
   replacement (32-bit writes) and save as `/tmp/kc_vphone600_upstream.raw`.
2. Run `KernelPatcher.find_all()` on `/tmp/kc_vphone600_orig.raw`, apply all
   dynamic patches, and save as `/tmp/kc_vphone600_dynamic.raw`.
3. Compare the two patched binaries with `cmp -l`.
4. Re-extract a clean vresearch101 kernelcache using `pyimg4 im4p extract`, save
   as `/tmp/kc_vresearch1_orig.raw`.
5. Run the dynamic patcher on `/tmp/kc_vresearch1_orig.raw`, save as
   `/tmp/kc_vresearch1_dynamic.raw`.

## Outputs

- `/tmp/kc_vphone600_upstream.raw`
- `/tmp/kc_vphone600_dynamic.raw`
- `/tmp/kc_vresearch1_orig.raw`
- `/tmp/kc_vresearch1_dynamic.raw`

## Checksums (SHA-256)

- `/tmp/kc_vphone600_orig.raw`:
  `b6846048f3a60eab5f360fcc0f3dcb5198aa0476c86fb06eb42f6267cdbfcae0`
- `/tmp/kc_vphone600_upstream.raw`:
  `373e016d34ae5a2d8ba7ba96c920f4f6700dea503e3689d06a99e90ebec701c8`
- `/tmp/kc_vphone600_dynamic.raw`:
  `373e016d34ae5a2d8ba7ba96c920f4f6700dea503e3689d06a99e90ebec701c8`
- `/tmp/kc_vresearch1_orig.raw`:
  `c673c9b8226ea774d1d935427760e2e9a48200fd1daf0ef584dc88df0dccefde`
- `/tmp/kc_vresearch1_dynamic.raw`:
  `f36a78ce59c658df85ecdead56d46370a1107181689091cf798e529664f6e2b5`

## vphone600: Hardcoded vs Dynamic

Result: **byte-identical** output between hardcoded and dynamic patching.

- `KernelPatcher` patches found: 26
- Hardcoded patches applied: 26
- `cmp -l /tmp/kc_vphone600_upstream.raw /tmp/kc_vphone600_dynamic.raw`:
  no output (files identical)

### Hardcoded Patch List (vphone600)

Offsets and 32-bit patch values, taken from `patch_fw.py`:

| #   | Offset (hex) | Patch value | Purpose                                     |
| --- | -----------: | ----------: | ------------------------------------------- |
| 1   |    0x2476964 |  0xD503201F | \_apfs_vfsop_mount root snapshot NOP        |
| 2   |    0x23CFDE4 |  0xD503201F | \_authapfs_seal_is_broken NOP               |
| 3   |   0x00F6D960 |  0xD503201F | \_bsd_init rootvp NOP                       |
| 4   |    0x163863C |  0x52800000 | \_proc_check_launch_constraints mov w0,#0   |
| 5   |    0x1638640 |  0xD65F03C0 | \_proc_check_launch_constraints ret         |
| 6   |    0x12C8138 |  0xD2800020 | \_PE_i_can_has_debugger mov x0,#1           |
| 7   |    0x12C813C |  0xD65F03C0 | \_PE_i_can_has_debugger ret                 |
| 8   |   0x00FFAB98 |  0xD503201F | TXM post-validation NOP (tbnz)              |
| 9   |    0x16405AC |  0x6B00001F | postValidation cmp w0,w0                    |
| 10  |    0x16410BC |  0x52800020 | \_check_dyld_policy_internal mov w0,#1 (1)  |
| 11  |    0x16410C8 |  0x52800020 | \_check_dyld_policy_internal mov w0,#1 (2)  |
| 12  |    0x242011C |  0x52800000 | \_apfs_graft mov w0,#0                      |
| 13  |    0x2475044 |  0xEB00001F | \_apfs_vfsop_mount cmp x0,x0                |
| 14  |    0x2476C00 |  0x52800000 | \_apfs_mount_upgrade_checks mov w0,#0       |
| 15  |    0x248C800 |  0x52800000 | \_handle_fsioc_graft mov w0,#0              |
| 16  |              |             | \_handle_get_dev_by_role entitlement bypass |
| 17  |    0x23AC528 |  0xD2800000 | \_hook_file_check_mmap mov x0,#0            |
| 18  |    0x23AC52C |  0xD65F03C0 | \_hook_file_check_mmap ret                  |
| 19  |    0x23AAB58 |  0xD2800000 | \_hook_mount_check_mount mov x0,#0          |
| 20  |    0x23AAB5C |  0xD65F03C0 | \_hook_mount_check_mount ret                |
| 21  |    0x23AA9A0 |  0xD2800000 | \_hook_mount_check_remount mov x0,#0        |
| 22  |    0x23AA9A4 |  0xD65F03C0 | \_hook_mount_check_remount ret              |
| 23  |    0x23AA80C |  0xD2800000 | \_hook_mount_check_umount mov x0,#0         |
| 24  |    0x23AA810 |  0xD65F03C0 | \_hook_mount_check_umount ret               |
| 25  |    0x23A5514 |  0xD2800000 | \_hook_vnode_check_rename mov x0,#0         |
| 26  |    0x23A5518 |  0xD65F03C0 | \_hook_vnode_check_rename ret               |

## TXM Patch Details

Dynamic patcher locates the `"TXM [Error]: CodeSignature"` string, finds the
following `tbnz` in the log/error path, and NOPs it.

### vphone600 disassembly around the patch (0xFFAB98)

Before:

```
0x00FFAB90: mov     w0, #5
0x00FFAB94: ldrb    w8, [x19, #6]
0x00FFAB98: tbnz    w8, #0, #0xffac80
0x00FFAB9C: ldp     x29, x30, [sp, #0x100]
```

After:

```
0x00FFAB90: mov     w0, #5
0x00FFAB94: ldrb    w8, [x19, #6]
0x00FFAB98: nop
0x00FFAB9C: ldp     x29, x30, [sp, #0x100]
```

## vresearch101: Dynamic Patch Run

Extraction:

```
pyimg4 im4p extract \
  -i VM/iPhone17,3_26.1_23B85_Restore/kernelcache.research.vresearch101 \
  -o /tmp/kc_vresearch1_orig.raw
```

Dynamic patcher results:

- Patches found/applied: 26
- TXM patch location: `0xFA6B98` (NOP `tbnz w8, #0, #0xfa6c80`)
- Patched output: `/tmp/kc_vresearch1_dynamic.raw`

## Conclusion

For vphone600, the dynamic patcher output is byte-identical to the legacy
hardcoded patch list, indicating functional equivalence on this kernelcache.
The same dynamic patcher also successfully patches the freshly extracted
vresearch101 kernelcache with the expected TXM NOP and a full 26-patch set.

## Targeted Re-Verification (2026-03-05)

Scope for this pass was limited to the user-requested kernel patches in
`KernelPatcher.find_all()` order:

- 6 `patch_PE_i_can_has_debugger` (`mov x0,#1`)
- 7 `patch_PE_i_can_has_debugger` (`ret`)
- 8 `patch_post_validation_nop` (NOP TXM post-validation `tbnz`)
- 9 `patch_post_validation_cmp` (`cmp w0,w0`)
- 10 `patch_check_dyld_policy` (`BL -> mov w0,#1` at `@1`)

Input kernel:

- `vm/iPhone17,3_26.1_23B85_Restore/kernelcache.research.vphone600`
  (IM4P payload decompressed in-memory; no file write during verification)

Regular and Development both use the same kernel patch entrypoint:

- `scripts/fw_patch.py` -> `patch_kernelcache()` -> `KernelPatcher.apply()`
- `scripts/fw_patch_dev.py` reuses `patch_kernelcache` from `fw_patch.py`

### Verification Results

| Item    | Patch                    |  File Offset |                   VA | Before                  | After        | Status |
| ------- | ------------------------ | -----------: | -------------------: | ----------------------- | ------------ | ------ |
| 6       | `_PE_i_can_has_debugger` | `0x012C8138` | `0xFFFFFE00082CC138` | `adrp x8, ...`          | `mov x0, #1` | OK     |
| 7       | `_PE_i_can_has_debugger` | `0x012C813C` | `0xFFFFFE00082CC13C` | `cbz x0, ...`           | `ret`        | OK     |
| 8       | TXM post-validation      | `0x00FFAB98` | `0xFFFFFE0007FFEB98` | `tbnz w8,#0,...`        | `nop`        | OK     |
| 9       | postValidation compare   | `0x016405AC` | `0xFFFFFE00086445AC` | `cmp w0, #2`            | `cmp w0, w0` | OK     |
| 10 (@1) | dyld policy              | `0x016410BC` | `0xFFFFFE00086450BC` | `bl 0xFFFFFE0007FFD304` | `mov w0, #1` | OK     |

### Structural Evidence (IDA + raw context)

- Patch 6/7 site is a dedicated tiny function entry at
  `0xFFFFFE00082CC138`; patching first two instructions produces exact
  `mov x0,#1; ret` stub. Call fanout observed by patcher histogram: 82 callers.
- Patch 8 site is the `tbnz` immediately after the
  `"TXM [Error]: CodeSignature"` log call chain
  (`ADRP+ADD string` -> `BL` -> `...` -> `TBNZ`), matching patch intent.
- Patch 9 site is in AMFI code path with local pattern:
  `BL` -> `CMP W0,#imm` -> `B.NE`; target instruction at `0x...45AC` is
  `cmp w0,#2` before replacement.
- Patch 10 (@1) site is in the function containing
  `"com.apple.developer.swift-playgrounds-app.development-build"` and matches
  the expected `BL` followed by a conditional on `W0`; the `BL` at
  `0x...50BC` is replaced by `mov w0,#1`.

### Conclusion (2026-03-05 pass)

The requested items 6/7/8/9/10 (with 10 interpreted as `@1`) all:

1. resolve to deterministic patch sites on clean `kernelcache.research.vphone600`,
2. replace the intended original instructions, and
3. align with the expected code path in IDA.
