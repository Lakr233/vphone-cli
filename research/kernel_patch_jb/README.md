# JB kernel patch notes

[Research library](../README.md) · [Patch comparison](../0_binary_patch_comparison.md) · [Document framework](PATCH_DOC_FRAMEWORK.md)

These notes explain the source anchors, binary matches and validation evidence for individual JB kernel patches. The Swift implementations live under `sources/FirmwarePatcher/Kernel/JBPatches/`; the notes are research records, not commands to apply a patch by hand.

| Area | Patch notes |
| --- | --- |
| Boot, root and mount | [BSD init auth](patch_bsd_init_auth.md), [IO secure BSD root](patch_io_secure_bsd_root.md), [dounmount](patch_dounmount.md), [mac mount](patch_mac_mount.md), [load dylinker](patch_load_dylinker.md) |
| AMFI, credentials and policy | [CDHash in trust cache](patch_amfi_cdhash_in_trustcache.md), [execve kill path](patch_amfi_execve_kill_path.md), [credential label update](patch_cred_label_update_execve.md), [credential hook](patch_hook_cred_label_update_execve.md), [proc security policy](patch_proc_security_policy.md), [persona validation](patch_spawn_validate_persona.md), [sandbox hooks](patch_sandbox_hooks_extended.md), [NVRAM permission](patch_nvram_verify_permission.md) |
| Tasks, ports and threads | [convert port to map](patch_convert_port_to_map.md), [task conversion](patch_task_conversion_eval_internal.md), [task for PID](patch_task_for_pid.md), [thread set state](patch_thread_set_state.md), [thread crash gate](patch_thid_should_crash.md) |
| VM and shared regions | [VM fault](patch_vm_fault_enter_prepare.md), [immutable map delete](patch_vm_map_delete_immutable_code.md), [VM map protect](patch_vm_map_protect.md), [shared region map](patch_shared_region_map.md) |
| Process and syscall paths | [proc PID info](patch_proc_pidinfo.md), [syscall mask](patch_syscallmask_apply_to_proc.md), [kcall10](patch_kcall10.md) |
| Follow-up evidence | [26.5 hook fixes](26.5_jb_hook_fixes.md), [post-validation additions](patch_post_validation_additional.md), [runtime verification archive](runtime_verification/README.md) |

For the supported firmware flow, use `vphone-cli fw patch` or `vphone-cli vm create`; see the [user guide](../../docs/guides/create-and-run.md).
