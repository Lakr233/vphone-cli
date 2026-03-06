# Binary Patch Matrix: Regular / Development / Jailbreak

Only binary patch items are kept in this document.
Non-binary content (deployment flow, installed components, runtime defaults, toolchain notes) is intentionally excluded.

## Boot Chain Binary Patches

### AVPBooter

| # | Patch | Purpose | Regular | Dev | JB |
| --- | --- | --- | :---: | :---: | :---: |
| 1 | `mov x0, #0` | DGST signature validation bypass | Y | Y | Y |

### iBSS

| # | Patch | Purpose | Regular | Dev | JB |
| --- | --- | --- | :---: | :---: | :---: |
| 1 | Serial labels (2x) | `Loaded iBSS` serial marker | Y | Y | Y |
| 2 | `image4_validate_property_callback` | Signature bypass (`b.ne` -> NOP, `mov x0,x22` -> `mov x0,#0`) | Y | Y | Y |
| 3 | Skip `generate_nonce` | Keep apnonce stable for SHSH (`tbz` -> unconditional `b`) | - | - | Y |

### iBEC

| # | Patch | Purpose | Regular | Dev | JB |
| --- | --- | --- | :---: | :---: | :---: |
| 1 | Serial labels (2x) | `Loaded iBEC` serial marker | Y | Y | Y |
| 2 | `image4_validate_property_callback` | Signature bypass | Y | Y | Y |
| 3 | Boot-args redirect | ADRP+ADD -> `serial=3 -v debug=0x2014e %s` | Y | Y | Y |

### LLB

| # | Patch | Purpose | Regular | Dev | JB |
| --- | --- | --- | :---: | :---: | :---: |
| 1 | Serial labels (2x) | `Loaded LLB` serial marker | Y | Y | Y |
| 2 | `image4_validate_property_callback` | Signature bypass | Y | Y | Y |
| 3 | Boot-args redirect | ADRP+ADD -> `serial=3 -v debug=0x2014e %s` | Y | Y | Y |
| 4 | Rootfs bypass (5 patches) | Allow edited rootfs loading | Y | Y | Y |
| 5 | Panic bypass | NOP `cbnz` after `mov w8,#0x328` check | Y | Y | Y |

### TXM

| # | Patch | Purpose | Regular | Dev | JB |
| --- | --- | --- | :---: | :---: | :---: |
| 1 | Trustcache binary-search bypass | `bl hash_cmp` -> `mov x0, #0` | Y | Y | Y |
| 2 | Selector24 bypass: `mov w0, #0xa1` | Return PASS (byte 1 = 0) after prologue | - | Y | Y |
| 3 | Selector24 bypass: `b <epilogue>` | Skip validation, jump to register restore | - | Y | Y |
| 4 | get-task-allow (selector 41\|29) | `bl` -> `mov x0, #1` | - | Y | Y |
| 5 | Selector42\|29 shellcode: branch to cave | Redirect dispatch stub to shellcode | - | Y | Y |
| 6 | Selector42\|29 shellcode: NOP pad | UDF -> NOP in code cave | - | Y | Y |
| 7 | Selector42\|29 shellcode: `mov x0, #1` | Set return value to true | - | Y | Y |
| 8 | Selector42\|29 shellcode: `strb w0, [x20, #0x30]` | Set manifest flag | - | Y | Y |
| 9 | Selector42\|29 shellcode: `mov x0, x20` | Restore context pointer | - | Y | Y |
| 10 | Selector42\|29 shellcode: branch back | Return from shellcode to stub+4 | - | Y | Y |
| 11 | Debugger entitlement (selector 42\|37) | `bl` -> `mov w0, #1` | - | Y | Y |
| 12 | Developer mode bypass | NOP conditional guard before deny path | - | Y | Y |

## Kernelcache Binary Patches

### Base Patches (All Variants)

| # | Patch | Function | Purpose | Regular | Dev | JB |
| --- | --- | --- | --- | :---: | :---: | :---: |
| 1 | NOP `tbnz w8,#5` | `_apfs_vfsop_mount` | Skip root snapshot sealed-volume check | Y | Y | Y |
| 2 | NOP conditional | `_authapfs_seal_is_broken` | Skip root volume seal panic | Y | Y | Y |
| 3 | NOP conditional | `_bsd_init` | Skip rootvp not-authenticated panic | Y | Y | Y |
| 4-5 | `mov w0,#0; ret` | `_proc_check_launch_constraints` | Bypass launch constraints | Y | Y | Y |
| 6-7 | `mov x0,#1` (2x) | `PE_i_can_has_debugger` | Enable kernel debugger | Y | Y | Y |
| 8 | NOP | `_postValidation` | Skip AMFI post-validation | Y | Y | Y |
| 9 | `cmp w0,w0` | `_postValidation` | Force comparison true | Y | Y | Y |
| 10-11 | `mov w0,#1` (2x) | `_check_dyld_policy_internal` | Allow dyld loading | Y | Y | Y |
| 12 | `mov w0,#0` | `_apfs_graft` | Allow APFS graft | Y | Y | Y |
| 13 | `cmp x0,x0` | `_apfs_vfsop_mount` | Skip mount check | Y | Y | Y |
| 14 | `mov w0,#0` | `_apfs_mount_upgrade_checks` | Allow mount upgrade | Y | Y | Y |
| 15 | `mov w0,#0` | `_handle_fsioc_graft` | Allow fsioc graft | Y | Y | Y |
| 16 | NOP (3x) | `handle_get_dev_by_role` | Bypass APFS role-lookup deny gates for boot mounts | Y | Y | Y |
| 17-26 | `mov x0,#0; ret` (5 hooks) | Sandbox MACF ops table | Stub 5 sandbox hooks | Y | Y | Y |

### JB-Only Kernel Methods

| # | Group | Method | Function | Purpose | JB |
| --- | --- | --- | --- | --- | :---: |
| JB-01 | A | `patch_amfi_cdhash_in_trustcache` | `AMFIIsCDHashInTrustCache` | Always return true + store hash | Y |
| JB-02 | A | `patch_amfi_execve_kill_path` | AMFI execve kill return site | Convert shared kill return from deny to allow | Y |
| JB-03 | C | `patch_cred_label_update_execve` | `_cred_label_update_execve` | Early-return low-riskized cs_flags path | Y |
| JB-04 | C | `patch_hook_cred_label_update_execve` | `_hook_cred_label_update_execve` | Low-riskized early-return hook gate | Y |
| JB-05 | C | `patch_kcall10` | `sysent[439]` (`SYS_kas_info` replacement) | Kernel arbitrary call from userspace | Y |
| JB-06 | B | `patch_post_validation_additional` | `_postValidation` (additional) | Disable SHA256-only hash-type reject | Y |
| JB-07 | C | `patch_syscallmask_apply_to_proc` | `_syscallmask_apply_to_proc` | Low-riskized early return for syscall mask gate | Y |
| JB-08 | A | `patch_task_conversion_eval_internal` | `_task_conversion_eval_internal` | Allow task conversion | Y |
| JB-09 | A | `patch_sandbox_hooks_extended` | Sandbox MACF ops (extended) | Stub remaining 30+ sandbox hooks (incl. IOKit 201..210) | Y |
| JB-10 | A | `patch_iouc_failed_macf` | IOUC MACF shared gate | Bypass shared IOUserClient MACF deny path | Y |
| JB-11 | B | `patch_proc_security_policy` | `_proc_security_policy` | Bypass security policy | Y |
| JB-12 | B | `patch_proc_pidinfo` | `_proc_pidinfo` | Allow pid 0 info | Y |
| JB-13 | B | `patch_convert_port_to_map` | `_convert_port_to_map_with_flavor` | Skip kernel map panic | Y |
| JB-14 | B | `patch_bsd_init_auth` | `_bsd_init` (2nd auth gate) | Skip auth at @%s:%d | Y |
| JB-15 | B | `patch_dounmount` | `_dounmount` | Allow unmount (strict in-function match) | Y |
| JB-16 | B | `patch_io_secure_bsd_root` | `_IOSecureBSDRoot` | Skip secure root check (guard-site filter) | Y |
| JB-17 | B | `patch_load_dylinker` | `_load_dylinker` | Skip strict `LC_LOAD_DYLINKER == "/usr/lib/dyld"` gate | Y |
| JB-18 | B | `patch_mac_mount` | `___mac_mount` | Bypass MAC mount deny path (strict site) | Y |
| JB-19 | B | `patch_nvram_verify_permission` | `_verifyPermission` (NVRAM) | Allow NVRAM writes | Y |
| JB-20 | B | `patch_shared_region_map` | `_shared_region_map_and_slide_setup` | Force shared region path | Y |
| JB-21 | B | `patch_spawn_validate_persona` | `_spawn_validate_persona` | Skip persona validation | Y |
| JB-22 | B | `patch_task_for_pid` | `_task_for_pid` | Allow task_for_pid | Y |
| JB-23 | B | `patch_thid_should_crash` | `_thid_should_crash` | Prevent GUARD_TYPE_MACH_PORT crash | Y |
| JB-24 | B | `patch_vm_fault_enter_prepare` | `_vm_fault_enter_prepare` | Skip fault check | Y |
| JB-25 | B | `patch_vm_map_protect` | `_vm_map_protect` | Allow VM protect | Y |

## CFW Binary Patches

### Patches Applied Over SSH Ramdisk

| # | Patch | Binary | Purpose | Regular | Dev | JB |
| --- | --- | --- | --- | :---: | :---: | :---: |
| 1 | `/%s.gl` -> `/AA.gl` | `seputil` | Gigalocker UUID fix | Y | Y | Y |
| 2 | NOP cache validation | `launchd_cache_loader` | Allow modified `launchd.plist` | Y | Y | Y |
| 3 | `mov x0,#1; ret` | `mobileactivationd` | Activation bypass | Y | Y | Y |
| 4 | Plist injection | `launchd.plist` | Add bash/dropbear/trollvnc/vphoned daemons | Y | Y | Y |
| 5 | `b` (skip jetsam guard) | `launchd` | Prevent jetsam panic on boot | - | Y | Y |
| 6 | `LC_LOAD_DYLIB` injection | `launchd` | Load `/cores/launchdhook.dylib` | - | - | Y |

## Ramdisk Binary Patch

| # | Patch Site | Purpose | Regular | Dev | JB |
| --- | --- | --- | :---: | :---: | :---: |
| 1 | `ramdisk_input/ssh/usr/local/bin/restored_external` | Replace default USBMux serial label (`SSHRD_Script ...`) with `UDID` | Y | Y | Y |
