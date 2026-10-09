# Research library

[Project overview](../README.md) · [User documentation](../Documents/README.md)

This directory keeps the evidence behind firmware patches, restore and the self-contained host runtime. **The current public workflow is JB only.** Many notes record earlier experiments and command names; use the [user guides](../Documents/README.md) and `vphone-cli --help` for current instructions.

## Start here

1. [Patch comparison](0_binary_patch_comparison.md) is the canonical per-component inventory. Its regular/dev/exp columns are historical.
2. [Firmware manifest and origins](Firmware/firmware_manifest_and_origins.md) explains the hybrid firmware inputs.
3. [CFW kernel patch notes](Kernel/kernel_jb_patch_notes.md) and the [individual patch index](KernelCustomFirmwarePatches/README.md) lead to the kernel evidence.
4. [Native restore design](Restore/native_restore_architecture.md) and [self-contained runtime](Host/runtime_dependency_tiers.md) explain the host migration.

## By subject

| Subject | Notes |
| --- | --- |
| Firmware and boot chain | [Manifest and origins](Firmware/firmware_manifest_and_origins.md), [iBoot patches](Firmware/iboot_patches.md), [TXM full chain](Firmware/txm_fullchain_analysis.md), [TXM JB patches](Firmware/txm_jb_patches.md), [selector 24](Firmware/txm_selector24_analysis.md), [variant differences](Firmware/txm_variant_diff.md) |
| Kernel | [CFW overview](Kernel/kernel_jb_patch_notes.md), [patcher verification](Kernel/kernel_patcher_verification.md), [FairPlay kexts](Kernel/kernel_fairplay_kexts.md), [base validation 1–5](Kernel/kernel_patch_base_first5_validation.md), [11–15](Kernel/kernel_patch_base_11_15_validation.md), [16–20](Kernel/kernel_patch_base_16_20_validation.md), [sandbox hooks](Kernel/kernel_patch_sandbox_hooks_17_26_validation.md), [individual patch notes](KernelCustomFirmwarePatches/README.md) |
| Other patches and captures | [Launchd jetsam](Patches/cfw_patch_launchd_jetsam.md), [user-mode hypervisor references](Patches/hv_vmm_present_usermode_xrefs.md), [reference capture](Patches/patch_reference_capture.md) |
| Restore | [DFU probe](Restore/virtual_dfu_probe.md), [in-process restore](Restore/native_restore_architecture.md) |
| Host and archives | [Binary split](Host/host_binary_split.md), [runtime dependency tiers](Host/runtime_dependency_tiers.md), [archive extraction contracts](Host/archive_extraction_contracts.md), [libarchive validation](Host/libarchive_xcframework_validation.md), [guest MAC, fixed address, port forwarding and names](Host/network_fixed_address.md), [machine identity and `vm clone --new-identity`](Host/machine_identity_and_clone.md) |
| VM disk space | [Where a VM's disk space goes](Host/disk_space.md) (overview and measured savings), [machine templates](Host/machine_templates.md), [sharing identical disk blocks with `vm rebase`](Host/disk_rebase.md), [guest TRIM and offline compaction](Host/guest_discard.md), [why the disk layout was not made deterministic](Host/deterministic_disk_layout.md), [why there is no content-addressed block store over NBD](Host/content_addressed_block_store.md) |
| Guest interaction and VM identity | [DevMode XPC](Guest/devmode_xpc_protocol.md), [keyboard events](Guest/keyboard_event_pipeline.md), [machine identifier](Guest/machine_identifier_storage_analysis.md), [Auto-Lock on the Lock Screen](Guest/lock_screen_idle_timer.md), [display refresh rate](Guest/display_refresh_rate.md), [GPU acceleration](Guest/gpu_acceleration.md), [RootHide bootstrap base](Guest/roothide_bootstrap_base.md), [the Mac's .local name](Guest/mac_name_resolution.md), [locationd startup deadlock](Guest/locationd_startup_deadlock.md), [trimming system services](Guest/service_trimming.md), [deleting the orig-fs snapshot for templates](Guest/template_snapshot_deletion.md) |
| Historical project records | [Migration ledger](History/intg_update_status.md), [manifest refactoring summary](History/manifest_and_refactoring_summary.md) |

`KernelSymbols/` holds symbol datasets and indexes; `Reference/` holds source references when present. They are evidence inputs, not steps for running the distributed app. The files in `History/` are preserved snapshots and may describe scripts or variants that have since been removed.
