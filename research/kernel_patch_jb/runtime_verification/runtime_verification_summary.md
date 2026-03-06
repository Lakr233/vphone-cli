# JB Runtime Patch Verification Summary

- generated_at_utc: `2026-03-05T14:55:53.029710+00:00`
- kernel_input: `/Users/qaq/Documents/Firmwares/PCC-CloudOS-26.3-23D128/kernelcache.research.vphone600`
- kernel_format: `IM4P`
- base_va: `0xFFFFFE0007004000`
- base_patch_count: `28`

## Scheduler Coverage

- methods_defined: `38`
- methods_in_find_all: `12`
- doc_methods_unscheduled: `12`
  - `patch_bsd_init_auth`
  - `patch_dounmount`
  - `patch_io_secure_bsd_root`
  - `patch_load_dylinker`
  - `patch_mac_mount`
  - `patch_nvram_verify_permission`
  - `patch_shared_region_map`
  - `patch_spawn_validate_persona`
  - `patch_task_for_pid`
  - `patch_thid_should_crash`
  - `patch_vm_fault_enter_prepare`
  - `patch_vm_map_protect`

## Method Results

| Method                                | Status | Patch Count | Duration(s) |
| ------------------------------------- | -----: | ----------: | ----------: |
| `patch_amfi_cdhash_in_trustcache`     |  `hit` |           4 |      2.1063 |
| `patch_amfi_execve_kill_path`         |  `hit` |           1 |      1.8737 |
| `patch_bsd_init_auth`                 |  `hit` |           1 |      1.9794 |
| `patch_convert_port_to_map`           |  `hit` |           1 |      1.8238 |
| `patch_cred_label_update_execve`      |  `hit` |           2 |      1.8675 |
| `patch_dounmount`                     |  `hit` |           1 |      1.8348 |
| `patch_hook_cred_label_update_execve` |  `hit` |           2 |      1.8813 |
| `patch_io_secure_bsd_root`            |  `hit` |           1 |      1.8405 |
| `patch_kcall10`                       |  `hit` |           3 |      2.3068 |
| `patch_load_dylinker`                 |  `hit` |           1 |      1.9300 |
| `patch_mac_mount`                     |  `hit` |           1 |      1.8349 |
| `patch_nvram_verify_permission`       |  `hit` |           1 |      1.8408 |
| `patch_post_validation_additional`    |  `hit` |           1 |      1.8452 |
| `patch_proc_pidinfo`                  |  `hit` |           2 |      1.9673 |
| `patch_proc_security_policy`          |  `hit` |           2 |      1.9561 |
| `patch_sandbox_hooks_extended`        |  `hit` |          52 |      1.8963 |
| `patch_shared_region_map`             |  `hit` |           1 |      1.8230 |
| `patch_spawn_validate_persona`        |  `hit` |           1 |      1.8310 |
| `patch_syscallmask_apply_to_proc`     |  `hit` |           2 |      1.8354 |
| `patch_task_conversion_eval_internal` |  `hit` |           1 |      2.4943 |
| `patch_task_for_pid`                  |  `hit` |           1 |      2.6071 |
| `patch_thid_should_crash`             |  `hit` |           1 |      1.8476 |
| `patch_vm_fault_enter_prepare`        |  `hit` |           1 |      1.8196 |
| `patch_vm_map_protect`                |  `hit` |           1 |      1.8241 |

## Patch Hits

### `patch_amfi_cdhash_in_trustcache`

- `0x01641B10` / `0xFFFFFE0008645B10` / mov x0,#1 [AMFIIsCDHashInTrustCache] / bytes `7f2303d5 -> 200080d2`
- `0x01641B14` / `0xFFFFFE0008645B14` / cbz x2,+8 [AMFIIsCDHashInTrustCache] / bytes `ffc300d1 -> 420000b4`
- `0x01641B18` / `0xFFFFFE0008645B18` / str x0,[x2] [AMFIIsCDHashInTrustCache] / bytes `f44f01a9 -> 400000f9`
- `0x01641B1C` / `0xFFFFFE0008645B1C` / ret [AMFIIsCDHashInTrustCache] / bytes `fd7b02a9 -> c0035fd6`

### `patch_amfi_execve_kill_path`

- `0x0164A38C` / `0xFFFFFE000864E38C` / mov w0,#0 [AMFI kill return → allow] / bytes `20008052 -> 00008052`

### `patch_bsd_init_auth`

- `0x00FAC9DC` / `0xFFFFFE0007FB09DC` / mov x0,#0 [_bsd_init auth] / bytes `a050ef97 -> 000080d2`

### `patch_convert_port_to_map`

- `0x00B0E100` / `0xFFFFFE0007B12100` / b 0xB0E154 [_convert_port_to_map skip panic] / bytes `a1020054 -> 15000014`

### `patch_cred_label_update_execve`

- `0x01649F00` / `0xFFFFFE000864DF00` / mov x0,xzr [_cred_label_update_execve low-risk] / bytes `ff4302d1 -> e0031faa`
- `0x01649F04` / `0xFFFFFE000864DF04` / retab [_cred_label_update_execve low-risk] / bytes `fc6f03a9 -> ff0f5fd6`

### `patch_dounmount`

- `0x00CB35B0` / `0xFFFFFE0007CB75B0` / NOP [_dounmount MAC check] / bytes `33cfff97 -> 1f2003d5`

### `patch_hook_cred_label_update_execve`

- `0x023CECE8` / `0xFFFFFE00093D2CE8` / mov x0,xzr [_hook_cred_label_update_execve low-risk] / bytes `fc6fbaa9 -> e0031faa`
- `0x023CECEC` / `0xFFFFFE00093D2CEC` / retab [_hook_cred_label_update_execve low-risk] / bytes `fa6701a9 -> ff0f5fd6`

### `patch_io_secure_bsd_root`

- `0x0136A1F0` / `0xFFFFFE000836E1F0` / b #0x1A4 [_IOSecureBSDRoot] / bytes `200d0034 -> 69000014`
- 2026-03-06 reanalysis: this historical hit is real but semantically wrong. It patches the `"SecureRoot"` name-check gate in `AppleARMPE::callPlatformFunction`, not the final `"SecureRootName"` deny return consumed by `IOSecureBSDRoot()`. The implementation was retargeted to `0x0136A464` / `0xFFFFFE000836E464` (`CSEL W22, WZR, W9, NE -> MOV W22, #0`).

### `patch_kcall10`

- `0x0074A5A0` / `0xFFFFFE000774E5A0` / sysent[439].sy_call = \_nosys 0xF6F048 (auth rebase, div=0xBCAD, next=2) [kcall10 low-risk] / bytes `0ccd0701adbc1080 -> 48f0f600adbc1080`
- `0x0074A5B0` / `0xFFFFFE000774E5B0` / sysent[439].sy_return_type = 1 [kcall10 low-risk] / bytes `01000000 -> 01000000`
- `0x0074A5B4` / `0xFFFFFE000774E5B4` / sysent[439].sy_narg=0,sy_arg_bytes=0 [kcall10 low-risk] / bytes `03000c00 -> 00000000`

### `patch_load_dylinker`

- `0x0105BED0` / `0xFFFFFE000805FED0` / b #0x44 [_load_dylinker policy bypass] / bytes `d228ef97 -> 11000014`

### `patch_mac_mount`

- `0x00CB0260` / `0xFFFFFE0007CB4260` / NOP [___mac_mount deny branch] / bytes `e0000035 -> 1f2003d5`

### `patch_nvram_verify_permission`

- `0x0123CC24` / `0xFFFFFE0008240C24` / NOP [verifyPermission NVRAM] / bytes `78151037 -> 1f2003d5`

### `patch_post_validation_additional`

- `0x0163C760` / `0xFFFFFE0008640760` / cmp w0,w0 [postValidation additional fallback] / bytes `1f000071 -> 1f00006b`

### `patch_proc_pidinfo`

- `0x01069F38` / `0xFFFFFE000806DF38` / NOP [_proc_pidinfo pid-0 guard A] / bytes `e04000b4 -> 1f2003d5`
- `0x01069F40` / `0xFFFFFE000806DF40` / NOP [_proc_pidinfo pid-0 guard B] / bytes `34410034 -> 1f2003d5`

### `patch_proc_security_policy`

- `0x0106C5F0` / `0xFFFFFE00080705F0` / mov x0,#0 [_proc_security_policy] / bytes `7f2303d5 -> 000080d2`
- `0x0106C5F4` / `0xFFFFFE00080705F4` / ret [_proc_security_policy] / bytes `f85fbca9 -> c0035fd6`

### `patch_sandbox_hooks_extended`

- `0x023AFB18` / `0xFFFFFE00093B3B18` / mov x0,#0 [_hook_vnode_check_fsgetpath] / bytes `7f2303d5 -> 000080d2`
- `0x023AFB1C` / `0xFFFFFE00093B3B1C` / ret [_hook_vnode_check_fsgetpath] / bytes `f44fbea9 -> c0035fd6`
- `0x023B1100` / `0xFFFFFE00093B5100` / mov x0,#0 [_hook_vnode_check_unlink] / bytes `7f2303d5 -> 000080d2`
- `0x023B1104` / `0xFFFFFE00093B5104` / ret [_hook_vnode_check_unlink] / bytes `e923ba6d -> c0035fd6`
- `0x023B13D8` / `0xFFFFFE00093B53D8` / mov x0,#0 [_hook_vnode_check_truncate] / bytes `7f2303d5 -> 000080d2`
- `0x023B13DC` / `0xFFFFFE00093B53DC` / ret [_hook_vnode_check_truncate] / bytes `fc6fbea9 -> c0035fd6`
- `0x023B1540` / `0xFFFFFE00093B5540` / mov x0,#0 [_hook_vnode_check_stat] / bytes `7f2303d5 -> 000080d2`
- `0x023B1544` / `0xFFFFFE00093B5544` / ret [_hook_vnode_check_stat] / bytes `fc6fbea9 -> c0035fd6`
- `0x023B16A8` / `0xFFFFFE00093B56A8` / mov x0,#0 [_hook_vnode_check_setutimes] / bytes `7f2303d5 -> 000080d2`
- `0x023B16AC` / `0xFFFFFE00093B56AC` / ret [_hook_vnode_check_setutimes] / bytes `f44fbea9 -> c0035fd6`
- `0x023B1800` / `0xFFFFFE00093B5800` / mov x0,#0 [_hook_vnode_check_setowner] / bytes `7f2303d5 -> 000080d2`
- `0x023B1804` / `0xFFFFFE00093B5804` / ret [_hook_vnode_check_setowner] / bytes `f44fbea9 -> c0035fd6`
- `0x023B1958` / `0xFFFFFE00093B5958` / mov x0,#0 [_hook_vnode_check_setmode] / bytes `7f2303d5 -> 000080d2`
- `0x023B195C` / `0xFFFFFE00093B595C` / ret [_hook_vnode_check_setmode] / bytes `e923ba6d -> c0035fd6`
- `0x023B1BEC` / `0xFFFFFE00093B5BEC` / mov x0,#0 [_hook_vnode_check_setflags] / bytes `7f2303d5 -> 000080d2`
- `0x023B1BF0` / `0xFFFFFE00093B5BF0` / ret [_hook_vnode_check_setflags] / bytes `e923bb6d -> c0035fd6`
- `0x023B1E54` / `0xFFFFFE00093B5E54` / mov x0,#0 [_hook_vnode_check_setextattr] / bytes `7f2303d5 -> 000080d2`
- `0x023B1E58` / `0xFFFFFE00093B5E58` / ret [_hook_vnode_check_setextattr] / bytes `f657bda9 -> c0035fd6`
- `0x023B1FD8` / `0xFFFFFE00093B5FD8` / mov x0,#0 [_hook_vnode_check_setattrlist] / bytes `7f2303d5 -> 000080d2`
- `0x023B1FDC` / `0xFFFFFE00093B5FDC` / ret [_hook_vnode_check_setattrlist] / bytes `fc6fbba9 -> c0035fd6`
- `0x023B2538` / `0xFFFFFE00093B6538` / mov x0,#0 [_hook_vnode_check_readlink] / bytes `7f2303d5 -> 000080d2`
- `0x023B253C` / `0xFFFFFE00093B653C` / ret [_hook_vnode_check_readlink] / bytes `f44fbea9 -> c0035fd6`
- `0x023B2690` / `0xFFFFFE00093B6690` / mov x0,#0 [_hook_vnode_check_open] / bytes `7f2303d5 -> 000080d2`
- `0x023B2694` / `0xFFFFFE00093B6694` / ret [_hook_vnode_check_open] / bytes `f85fbca9 -> c0035fd6`
- `0x023B28D8` / `0xFFFFFE00093B68D8` / mov x0,#0 [_hook_vnode_check_listextattr] / bytes `7f2303d5 -> 000080d2`
- `0x023B28DC` / `0xFFFFFE00093B68DC` / ret [_hook_vnode_check_listextattr] / bytes `f44fbea9 -> c0035fd6`
- `0x023B2A5C` / `0xFFFFFE00093B6A5C` / mov x0,#0 [_hook_vnode_check_link] / bytes `7f2303d5 -> 000080d2`
- `0x023B2A60` / `0xFFFFFE00093B6A60` / ret [_hook_vnode_check_link] / bytes `e923ba6d -> c0035fd6`
- `0x023B311C` / `0xFFFFFE00093B711C` / mov x0,#0 [_hook_vnode_check_ioctl] / bytes `7f2303d5 -> 000080d2`
- `0x023B3120` / `0xFFFFFE00093B7120` / ret [_hook_vnode_check_ioctl] / bytes `f85fbca9 -> c0035fd6`
- `0x023B3404` / `0xFFFFFE00093B7404` / mov x0,#0 [_hook_vnode_check_getextattr] / bytes `7f2303d5 -> 000080d2`
- `0x023B3408` / `0xFFFFFE00093B7408` / ret [_hook_vnode_check_getextattr] / bytes `f44fbea9 -> c0035fd6`
- `0x023B3560` / `0xFFFFFE00093B7560` / mov x0,#0 [_hook_vnode_check_getattrlist] / bytes `7f2303d5 -> 000080d2`
- `0x023B3564` / `0xFFFFFE00093B7564` / ret [_hook_vnode_check_getattrlist] / bytes `fc6fbea9 -> c0035fd6`
- `0x023B3720` / `0xFFFFFE00093B7720` / mov x0,#0 [_hook_vnode_check_exchangedata] / bytes `7f2303d5 -> 000080d2`
- `0x023B3724` / `0xFFFFFE00093B7724` / ret [_hook_vnode_check_exchangedata] / bytes `e923ba6d -> c0035fd6`
- `0x023B3AA4` / `0xFFFFFE00093B7AA4` / mov x0,#0 [_hook_vnode_check_deleteextattr] / bytes `7f2303d5 -> 000080d2`
- `0x023B3AA8` / `0xFFFFFE00093B7AA8` / ret [_hook_vnode_check_deleteextattr] / bytes `f657bda9 -> c0035fd6`
- `0x023B3C28` / `0xFFFFFE00093B7C28` / mov x0,#0 [_hook_vnode_check_create] / bytes `7f2303d5 -> 000080d2`
- `0x023B3C2C` / `0xFFFFFE00093B7C2C` / ret [_hook_vnode_check_create] / bytes `f85fbca9 -> c0035fd6`
- `0x023B3EF4` / `0xFFFFFE00093B7EF4` / mov x0,#0 [_hook_vnode_check_chroot] / bytes `7f2303d5 -> 000080d2`
- `0x023B3EF8` / `0xFFFFFE00093B7EF8` / ret [_hook_vnode_check_chroot] / bytes `f44fbea9 -> c0035fd6`
- `0x023B404C` / `0xFFFFFE00093B804C` / mov x0,#0 [_hook_proc_check_set_cs_info2] / bytes `7f2303d5 -> 000080d2`
- `0x023B4050` / `0xFFFFFE00093B8050` / ret [_hook_proc_check_set_cs_info2] / bytes `f85fbca9 -> c0035fd6`
- `0x023B4498` / `0xFFFFFE00093B8498` / mov x0,#0 [_hook_proc_check_set_cs_info] / bytes `7f2303d5 -> 000080d2`
- `0x023B449C` / `0xFFFFFE00093B849C` / ret [_hook_proc_check_set_cs_info] / bytes `e923ba6d -> c0035fd6`
- `0x023B46BC` / `0xFFFFFE00093B86BC` / mov x0,#0 [_hook_proc_check_get_cs_info] / bytes `7f2303d5 -> 000080d2`
- `0x023B46C0` / `0xFFFFFE00093B86C0` / ret [_hook_proc_check_get_cs_info] / bytes `fc6fbca9 -> c0035fd6`
- `0x023B5110` / `0xFFFFFE00093B9110` / mov x0,#0 [_hook_vnode_check_getattr] / bytes `7f2303d5 -> 000080d2`
- `0x023B5114` / `0xFFFFFE00093B9114` / ret [_hook_vnode_check_getattr] / bytes `f44fbea9 -> c0035fd6`
- `0x023CD16C` / `0xFFFFFE00093D116C` / mov x0,#0 [_hook_vnode_check_exec] / bytes `7f2303d5 -> 000080d2`
- `0x023CD170` / `0xFFFFFE00093D1170` / ret [_hook_vnode_check_exec] / bytes `fc6fbba9 -> c0035fd6`

### `patch_shared_region_map`

- `0x0107BE1C` / `0xFFFFFE000807FE1C` / cmp x0,x0 [_shared_region_map_and_slide_setup] / bytes `1f0110eb -> 1f0000eb`

### `patch_spawn_validate_persona`

- `0x00FB08B0` / `0xFFFFFE0007FB48B0` / b #0x130 [_spawn_validate_persona gate] / bytes `88090836 -> 4c000014`

### `patch_syscallmask_apply_to_proc`

- `0x023AA6E4` / `0xFFFFFE00093AE6E4` / mov x0,xzr [_syscallmask_apply_to_proc low-risk] / bytes `ff8300d1 -> e0031faa`
- `0x023AA6E8` / `0xFFFFFE00093AE6E8` / retab [_syscallmask_apply_to_proc low-risk] / bytes `fd7b01a9 -> ff0f5fd6`

### `patch_task_conversion_eval_internal`

- `0x00B0C400` / `0xFFFFFE0007B10400` / cmp xzr,xzr [_task_conversion_eval_internal] / bytes `3f0100eb -> ff031feb`

### `patch_task_for_pid`

- `0x01009120` / `0xFFFFFE000800D120` / NOP [_task_for_pid proc_ro copy] / bytes `889244b9 -> 1f2003d5`

### `patch_thid_should_crash`

- `0x0068AB48` / `0xFFFFFE000768EB48` / zero [_thid_should_crash] / bytes `01000000 -> 00000000`

### `patch_vm_fault_enter_prepare`

- `0x00BB498C` / `0xFFFFFE0007BB898C` / NOP [_vm_fault_enter_prepare] / bytes `944b0294 -> 1f2003d5`

### `patch_vm_map_protect`

- `0x00BCC9A8` / `0xFFFFFE0007BD09A8` / b #0x48C [_vm_map_protect] / bytes `782400b7 -> 23010014`
