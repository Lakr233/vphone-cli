# IDA Patch Chain Report

- Functions with patch points: `34`

## `sub_FFFFFE0007B10334` @ `0xFFFFFE0007B10334`

- Patch methods: `patch_task_conversion_eval_internal`
- Patch points: `0xFFFFFE0007B10400`
- Callers(6): `sub_FFFFFE0007B10118`, `sub_FFFFFE0007B109C0`, `sub_FFFFFE0007B10E70`, `sub_FFFFFE0007B11B1C`, `sub_FFFFFE0007B12200`, `sub_FFFFFE0007B87398`
- Callees(14): `sub_FFFFFE0007B10334`, `sub_FFFFFE0007B48D24`, `sub_FFFFFE0007B48C00`, `sub_FFFFFE0008308A6C`, `sub_FFFFFE0008302368`, `sub_FFFFFE0007B84C5C`, `sub_FFFFFE0007AE3BB8`, `sub_FFFFFE0007B5F304` ...

## `convert_port_to_map_with_flavor` @ `0xFFFFFE0007B12024`

- Patch methods: `patch_convert_port_to_map`
- Patch points: `0xFFFFFE0007B12100`
- Callers(17): `_Xmach_vm_wire_external`, `_Xvm_wire`, `_Xmach_vm_range_create`, `_Xmach_vm_behavior_set`, `_Xmach_vm_msync`, `_Xmach_vm_copy`, `_Xmach_vm_write`, `_X_map_exec_lockdown` ...
- Callees(7): `convert_port_to_map_with_flavor`, `sub_FFFFFE0007AE3BB8`, `sub_FFFFFE0007B10E70`, `sub_FFFFFE0008302368`, `sub_FFFFFE0007B1EEE0`, `sub_FFFFFE0007C54FD8`, `sub_FFFFFE0007BCB274`

## `vm_fault_enter_prepare` @ `0xFFFFFE0007BB8818`

- Patch methods: `patch_vm_fault_enter_prepare`
- Patch points: `0xFFFFFE0007BB898C`
- Callers(2): `vm_fault_internal`, `sub_FFFFFE0007BB8294`
- Callees(32): `vm_fault_enter_prepare`, `sub_FFFFFE0008302368`, `sub_FFFFFE0007B84C5C`, `sub_FFFFFE0007C4B7DC`, `sub_FFFFFE0007C4B9A4`, `sub_FFFFFE0007BB8168`, `sub_FFFFFE0007F8C248`, `sub_FFFFFE0007B84334` ...

## `vm_map_protect` @ `0xFFFFFE0007BD08D8`

- Patch methods: `patch_vm_map_protect`
- Patch points: `0xFFFFFE0007BD09A8`
- Callers(15): `sub_FFFFFE0007BD0528`, `mach_vm_protect_trap`, `_Xmach_vm_protect`, `_Xprotect`, `sub_FFFFFE0007C1F7A8`, `sub_FFFFFE0007C1F7C8`, `sub_FFFFFE0007C477DC`, `sub_FFFFFE0007FB0EE0` ...
- Callees(16): `vm_map_protect`, `sub_FFFFFE0007C20E24`, `vm_sanitize_send_telemetry`, `sub_FFFFFE0007B1D788`, `vm_map_store_entry_link`, `sub_FFFFFE0007B84C5C`, `sub_FFFFFE0007B840E0`, `sub_FFFFFE0007BC6030` ...

## `prepare_coveredvp` @ `0xFFFFFE0007CB41BC`

- Patch methods: `patch_mac_mount`
- Patch points: `0xFFFFFE0007CB4260`
- Callers(2): `mount_common`, `__mac_mount`
- Callees(11): `prepare_coveredvp`, `sub_FFFFFE0007CD84F8`, `buf_invalidateblks`, `sub_FFFFFE0007B1C590`, `sub_FFFFFE0007FE3138`, `sub_FFFFFE00082E9438`, `sub_FFFFFE0007CA3618`, `thread_wakeup_prim` ...

## `dounmount` @ `0xFFFFFE0007CB6EA0`

- Patch methods: `patch_dounmount`
- Patch points: `0xFFFFFE0007CB75B0`
- Callers(4): `vfs_mountroot`, `sub_FFFFFE0007CAAE28`, `safedounmount`, `sub_FFFFFE0007CB770C`
- Callees(37): `dounmount`, `sub_FFFFFE0007B84214`, `sub_FFFFFE0007B84334`, `sub_FFFFFE0007CDD91C`, `thread_wakeup_prim`, `sub_FFFFFE0007CB770C`, `sub_FFFFFE0007B1D788`, `lck_rw_done` ...

## `exec_handle_sugid` @ `0xFFFFFE0007FB07BC`

- Patch methods: `patch_bsd_init_auth`
- Patch points: `0xFFFFFE0007FB09DC`
- Callers(1): `exec_mach_imgact`
- Callees(22): `exec_handle_sugid`, `sub_FFFFFE0007B84214`, `sub_FFFFFE0007B84334`, `sub_FFFFFE00082E27D0`, `sub_FFFFFE0007F8B188`, `sub_FFFFFE00082DBF18`, `sub_FFFFFE0007B84C5C`, `sub_FFFFFE0007B0EA64` ...

## `exec_spawnattr_getmacpolicyinfo` @ `0xFFFFFE0007FB28F0`

- Patch methods: `patch_spawn_validate_persona`
- Patch points: `0xFFFFFE0007FB48B0`
- Callers(4): `mac_proc_check_launch_constraints`, `sub_FFFFFE00082E2484`, `sub_FFFFFE00082E27D0`, `sub_FFFFFE00082E4118`
- Callees(112): `exec_spawnattr_getmacpolicyinfo`, `sub_FFFFFE0007AC5830`, `sub_FFFFFE0008302368`, `sub_FFFFFE0007B84C5C`, `sub_FFFFFE0007B1663C`, `sub_FFFFFE0007C5887C`, `sub_FFFFFE0008298510`, `sub_FFFFFE0007FCFD50` ...

## `sub_FFFFFE000800CFFC` @ `0xFFFFFE000800CFFC`

- Patch methods: `patch_task_for_pid`
- Patch points: `0xFFFFFE000800D120`
- Callers(0):
- Callees(7): `sub_FFFFFE000800CFFC`, `sub_FFFFFE0007B1F444`, `sub_FFFFFE0007FE91CC`, `sub_FFFFFE0007B15AFC`, `sub_FFFFFE0008312DC0`, `kfree_ext`, `sub_FFFFFE0007B1F20C`

## `load_dylinker` @ `0xFFFFFE000805FE44`

- Patch methods: `patch_load_dylinker`
- Patch points: `0xFFFFFE000805FED0`
- Callers(1): `sub_FFFFFE000805DF38`
- Callees(21): `load_dylinker`, `sub_FFFFFE0007AC5700`, `sub_FFFFFE0007C2A218`, `sub_FFFFFE0007B1663C`, `sub_FFFFFE0007B84334`, `sub_FFFFFE0007B84214`, `namei`, `sub_FFFFFE0007C9D9E8` ...

## `sub_FFFFFE000806DED8` @ `0xFFFFFE000806DED8`

- Patch methods: `patch_proc_pidinfo`
- Patch points: `0xFFFFFE000806DF38`, `0xFFFFFE000806DF40`
- Callers(1): `proc_info_internal`
- Callees(41): `sub_FFFFFE000806DED8`, `sub_FFFFFE0007B84334`, `sub_FFFFFE0007FC78B0`, `sub_FFFFFE0007FC6D68`, `sub_FFFFFE0007FC7940`, `proc_find_zombref`, `sub_FFFFFE0007FC63BC`, `sub_FFFFFE00080705F0` ...

## `sub_FFFFFE00080705F0` @ `0xFFFFFE00080705F0`

- Patch methods: `patch_proc_security_policy`
- Patch points: `0xFFFFFE00080705F0`, `0xFFFFFE00080705F4`
- Callers(5): `sub_FFFFFE000806DED8`, `sub_FFFFFE000806E9E8`, `sub_FFFFFE000806F414`, `sub_FFFFFE000806FACC`, `proc_info_internal`
- Callees(8): `sub_FFFFFE00080705F0`, `sub_FFFFFE0007B84334`, `sub_FFFFFE00082DD990`, `sub_FFFFFE0007FCA008`, `_enable_preemption_underflow`, `sub_FFFFFE0007C64A3C`, `sub_FFFFFE00082F5868`, `sub_FFFFFE00082F5A78`

## `sub_FFFFFE000807F5F4` @ `0xFFFFFE000807F5F4`

- Patch methods: `patch_shared_region_map`
- Patch points: `0xFFFFFE000807FE1C`
- Callers(1): `_shared_region_map_and_slide`
- Callees(16): `sub_FFFFFE000807F5F4`, `sub_FFFFFE0007B84C5C`, `sub_FFFFFE0007AC5540`, `sub_FFFFFE0007B15AFC`, `sub_FFFFFE0007C11F88`, `sub_FFFFFE0007C18184`, `sub_FFFFFE00080803AC`, `sub_FFFFFE0007F92284` ...

## `__ZL16verifyPermission16IONVRAMOperationPKhPKcbb` @ `0xFFFFFE0008240AD8`

- Patch methods: `patch_nvram_verify_permission`
- Patch points: `0xFFFFFE0008240C24`
- Callers(7): `sub_FFFFFE0008240970`, `__ZN9IODTNVRAM26setPropertyWithGUIDAndNameEPKhPKcP8OSObject`, `sub_FFFFFE0008241614`, `sub_FFFFFE0008241EDC`, `sub_FFFFFE0008243850`, `__ZN16IONVRAMV3Handler17setEntryForRemoveEP18nvram_v3_var_entryb`, `sub_FFFFFE000824CE68`
- Callees(9): `__ZL16verifyPermission16IONVRAMOperationPKhPKcbb`, `sub_FFFFFE000824153C`, `sub_FFFFFE0007C2A218`, `sub_FFFFFE0007C2A1E8`, `sub_FFFFFE0007B84C5C`, `sub_FFFFFE0007B840E0`, `sub_FFFFFE0007AC5830`, `__ZN12IOUserClient18clientHasPrivilegeEPvPKc` ...

## `__ZN10AppleARMPE20callPlatformFunctionEPK8OSSymbolbPvS3_S3_S3_` @ `0xFFFFFE000836E168`

- Patch methods: `patch_io_secure_bsd_root`
- Patch points: `0xFFFFFE000836E1F0`
- Callers(0):
- Callees(8): `__ZN10AppleARMPE20callPlatformFunctionEPK8OSSymbolbPvS3_S3_S3_`, `sub_FFFFFE0008133868`, `sub_FFFFFE0007B1B4E0`, `sub_FFFFFE00081AA798`, `sub_FFFFFE0007B1C324`, `sub_FFFFFE0007AC57A0`, `sub_FFFFFE0007AC5830`, `sub_FFFFFE00081AA7B8`

## `sub_FFFFFE00086406F0` @ `0xFFFFFE00086406F0`

- Patch methods: `patch_post_validation_additional`
- Patch points: `0xFFFFFE0008640760`
- Callers(0):
- Callees(4): `sub_FFFFFE00086406F0`, `sub_FFFFFE0007F8C72C`, `sub_FFFFFE0007F8C800`, `sub_FFFFFE0007C2A218`

## `sub_FFFFFE0008645B10` @ `0xFFFFFE0008645B10`

- Patch methods: `patch_amfi_cdhash_in_trustcache`
- Patch points: `0xFFFFFE0008645B10`, `0xFFFFFE0008645B14`, `0xFFFFFE0008645B18`, `0xFFFFFE0008645B1C`
- Callers(7): `__Z29isConstraintCategoryEnforcing20ConstraintCategory_t`, `__ZN24AppleMobileFileIntegrity27submitAuxiliaryInfoAnalyticEP5vnodeP7cs_blob`, `__Z14tokenIsTrusted13audit_token_t`, `sub_FFFFFE000864DC14`, `sub_FFFFFE000864DC8C`, `__ZL22_vnode_check_signatureP5vnodeP5labeliP7cs_blobPjS5_ijPPcPm`, `__ZL15_policy_syscallP4prociy__FFFFFE00086514F8`
- Callees(3): `sub_FFFFFE0008645B10`, `sub_FFFFFE0008006344`, `sub_FFFFFE0008659D48`

## `__Z25_cred_label_update_execveP5ucredS0_P4procP5vnodexS4_P5labelS6_S6_PjPvmPi` @ `0xFFFFFE000864DEFC`

- Patch methods: `patch_amfi_execve_kill_path`, `patch_cred_label_update_execve`
- Patch points: `0xFFFFFE000864DF00`, `0xFFFFFE000864DF04`, `0xFFFFFE000864E38C`
- Callers(1): `__ZL35_initializeAppleMobileFileIntegrityv`
- Callees(26): `__Z25_cred_label_update_execveP5ucredS0_P4procP5vnodexS4_P5labelS6_S6_PjPvmPi`, `sub_FFFFFE0007CD7750`, `sub_FFFFFE0007CD7760`, `sub_FFFFFE0007F8C7E8`, `sub_FFFFFE0007FC78B0`, `sub_FFFFFE0007FC99FC`, `sub_FFFFFE00081AA034`, `sub_FFFFFE0007FCA008` ...

## `_profile_syscallmask_destroy` @ `0xFFFFFE00093AE6A4`

- Patch methods: `patch_syscallmask_apply_to_proc`
- Patch points: `0xFFFFFE00093AE6E4`, `0xFFFFFE00093AE6E8`
- Callers(2): `sub_FFFFFE00093AE678`, `_profile_uninit`
- Callees(2): `sub_FFFFFE00093AE70C`, `sub_FFFFFE0008302368`

## `sub_FFFFFE00093B3B18` @ `0xFFFFFE00093B3B18`

- Patch methods: `patch_sandbox_hooks_extended`
- Patch points: `0xFFFFFE00093B3B18`, `0xFFFFFE00093B3B1C`
- Callers(1): `sub_FFFFFE00093B39C0`
- Callees(4): `sub_FFFFFE00093B3B18`, `sub_FFFFFE00093B14A8`, `_sb_evaluate_internal`, `sub_FFFFFE00093B3C70`

## `_hook_vnode_check_unlink` @ `0xFFFFFE00093B5100`

- Patch methods: `patch_sandbox_hooks_extended`
- Patch points: `0xFFFFFE00093B5100`, `0xFFFFFE00093B5104`, `0xFFFFFE00093B53D8`, `0xFFFFFE00093B53DC`, `0xFFFFFE00093B5540`, `0xFFFFFE00093B5544`, `0xFFFFFE00093B56A8`, `0xFFFFFE00093B56AC` ...
- Callers(2): `_hook_vnode_check_rename`, `sub_FFFFFE00093C4110`
- Callees(12): `_hook_vnode_check_unlink`, `sub_FFFFFE00093B14A8`, `_sb_evaluate_internal`, `sub_FFFFFE00093C8158`, `sub_FFFFFE00093C8530`, `sub_FFFFFE0008185C50`, `sub_FFFFFE00093C5D44`, `sub_FFFFFE0007CD51F0` ...

## `sub_FFFFFE00093B711C` @ `0xFFFFFE00093B711C`

- Patch methods: `patch_sandbox_hooks_extended`
- Patch points: `0xFFFFFE00093B711C`, `0xFFFFFE00093B7120`
- Callers(0):
- Callees(7): `sub_FFFFFE00093B711C`, `sub_FFFFFE0008131F0C`, `sub_FFFFFE0007F8A17C`, `sub_FFFFFE00093B14A8`, `_sb_evaluate_internal`, `sub_FFFFFE00093C8158`, `sub_FFFFFE00093B7404`

## `sub_FFFFFE00093B7404` @ `0xFFFFFE00093B7404`

- Patch methods: `patch_sandbox_hooks_extended`
- Patch points: `0xFFFFFE00093B7404`, `0xFFFFFE00093B7408`
- Callers(1): `sub_FFFFFE00093B711C`
- Callees(4): `sub_FFFFFE00093B7404`, `sub_FFFFFE00093B14A8`, `_sb_evaluate_internal`, `sub_FFFFFE00093B7560`

## `sub_FFFFFE00093B7560` @ `0xFFFFFE00093B7560`

- Patch methods: `patch_sandbox_hooks_extended`
- Patch points: `0xFFFFFE00093B7560`, `0xFFFFFE00093B7564`
- Callers(1): `sub_FFFFFE00093B7404`
- Callees(4): `sub_FFFFFE00093B7560`, `sub_FFFFFE00093B14A8`, `_sb_evaluate_internal`, `sub_FFFFFE00093B7720`

## `sub_FFFFFE00093B7720` @ `0xFFFFFE00093B7720`

- Patch methods: `patch_sandbox_hooks_extended`
- Patch points: `0xFFFFFE00093B7720`, `0xFFFFFE00093B7724`
- Callers(1): `sub_FFFFFE00093B7560`
- Callees(5): `sub_FFFFFE00093B7720`, `sub_FFFFFE00093B14A8`, `_sb_evaluate_internal`, `sub_FFFFFE00093C8158`, `sub_FFFFFE00093B7AA4`

## `sub_FFFFFE00093B7AA4` @ `0xFFFFFE00093B7AA4`

- Patch methods: `patch_sandbox_hooks_extended`
- Patch points: `0xFFFFFE00093B7AA4`, `0xFFFFFE00093B7AA8`
- Callers(1): `sub_FFFFFE00093B7720`
- Callees(5): `sub_FFFFFE00093B7AA4`, `_rootless_forbid_xattr`, `sub_FFFFFE00093B14A8`, `_sb_evaluate_internal`, `_hook_vnode_check_create`

## `_hook_vnode_check_create` @ `0xFFFFFE00093B7C28`

- Patch methods: `patch_sandbox_hooks_extended`
- Patch points: `0xFFFFFE00093B7C28`, `0xFFFFFE00093B7C2C`
- Callers(1): `sub_FFFFFE00093B7AA4`
- Callees(6): `_hook_vnode_check_create`, `sub_FFFFFE00093B14A8`, `sub_FFFFFE00093B0998`, `_sb_evaluate_internal`, `sub_FFFFFE00093C8158`, `sub_FFFFFE00093B7EF4`

## `sub_FFFFFE00093B7EF4` @ `0xFFFFFE00093B7EF4`

- Patch methods: `patch_sandbox_hooks_extended`
- Patch points: `0xFFFFFE00093B7EF4`, `0xFFFFFE00093B7EF8`
- Callers(1): `_hook_vnode_check_create`
- Callees(4): `sub_FFFFFE00093B7EF4`, `sub_FFFFFE00093B14A8`, `_sb_evaluate_internal`, `sub_FFFFFE00093B804C`

## `sub_FFFFFE00093B804C` @ `0xFFFFFE00093B804C`

- Patch methods: `patch_sandbox_hooks_extended`
- Patch points: `0xFFFFFE00093B804C`, `0xFFFFFE00093B8050`
- Callers(1): `sub_FFFFFE00093B7EF4`
- Callees(6): `sub_FFFFFE00093B804C`, `sub_FFFFFE00093B14A8`, `sub_FFFFFE0007CD7760`, `_sb_evaluate_internal`, `sub_FFFFFE00093C8158`, `sub_FFFFFE00093B834C`

## `sub_FFFFFE00093B8498` @ `0xFFFFFE00093B8498`

- Patch methods: `patch_sandbox_hooks_extended`
- Patch points: `0xFFFFFE00093B8498`, `0xFFFFFE00093B849C`
- Callers(1): `sub_FFFFFE00093B834C`
- Callees(5): `sub_FFFFFE00093B8498`, `sub_FFFFFE00093B14A8`, `_sb_evaluate_internal`, `sub_FFFFFE00093C8158`, `sub_FFFFFE00093B86BC`

## `sub_FFFFFE00093B86BC` @ `0xFFFFFE00093B86BC`

- Patch methods: `patch_sandbox_hooks_extended`
- Patch points: `0xFFFFFE00093B86BC`, `0xFFFFFE00093B86C0`
- Callers(1): `sub_FFFFFE00093B8498`
- Callees(5): `sub_FFFFFE00093B86BC`, `sub_FFFFFE00093B14A8`, `_sb_evaluate_internal`, `sub_FFFFFE00093C8158`, `_hook_vnode_check_clone`

## `sub_FFFFFE00093B9110` @ `0xFFFFFE00093B9110`

- Patch methods: `patch_sandbox_hooks_extended`
- Patch points: `0xFFFFFE00093B9110`, `0xFFFFFE00093B9114`
- Callers(1): `sub_FFFFFE00093B8F68`
- Callees(4): `sub_FFFFFE00093B9110`, `sub_FFFFFE00093B14A8`, `_sb_evaluate_internal`, `sub_FFFFFE00093B934C`

## `_hook_vnode_check_exec` @ `0xFFFFFE00093D116C`

- Patch methods: `patch_sandbox_hooks_extended`
- Patch points: `0xFFFFFE00093D116C`, `0xFFFFFE00093D1170`
- Callers(0):
- Callees(19): `_hook_vnode_check_exec`, `_sb_evaluate_internal`, `sub_FFFFFE0007CD51F0`, `sub_FFFFFE0007CD84F8`, `sub_FFFFFE0007C61E74`, `sub_FFFFFE00093DE8B4`, `sub_FFFFFE00093B14A8`, `sub_FFFFFE000864E78C` ...

## `sub_FFFFFE00093D2CE4` @ `0xFFFFFE00093D2CE4`

- Patch methods: `patch_hook_cred_label_update_execve`
- Patch points: `0xFFFFFE00093D2CE8`, `0xFFFFFE00093D2CEC`
- Callers(0):
- Callees(37): `sub_FFFFFE00093D2CE4`, `sub_FFFFFE0007FC78B0`, `sub_FFFFFE00093C6980`, `sub_FFFFFE000864F634`, `proc_checkdeadrefs`, `sub_FFFFFE0007F89CD0`, `sub_FFFFFE00093D3F54`, `sub_FFFFFE0007FC4FD8` ...
