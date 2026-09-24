# Research library

[Project overview](../README.md) · [User documentation](../Documents/README.md)

This directory keeps the evidence behind firmware patches, restore and the self-contained host runtime. **The current public workflow is JB only.** Many notes record earlier experiments and command names; use the [user guides](../Documents/README.md) and `vphone-cli --help` for current instructions.

## Start here

1. [Patch comparison](0_binary_patch_comparison.md) is the canonical per-component inventory. Its regular/dev/exp columns are historical.
2. [Firmware manifest and origins](Firmware/firmware_manifest_and_origins.md) explains the hybrid firmware inputs.
3. [JB kernel patch notes](Kernel/kernel_jb_patch_notes.md) and the [individual patch index](KernelJailbreakPatches/README.md) lead to the kernel evidence.
4. [Native restore design](Restore/p2_restore_off_python.md) and [self-contained runtime](Host/d2_d3_self_containment.md) explain the host migration.

## By subject

| Subject | Notes |
| --- | --- |
| Firmware and boot chain | [Manifest and origins](Firmware/firmware_manifest_and_origins.md), [iBoot patches](Firmware/iboot_patches.md), [TXM full chain](Firmware/txm_fullchain_analysis.md), [TXM JB patches](Firmware/txm_jb_patches.md), [selector 24](Firmware/txm_selector24_analysis.md), [variant differences](Firmware/txm_variant_diff.md) |
| Kernel | [JB overview](Kernel/kernel_jb_patch_notes.md), [patcher verification](Kernel/kernel_patcher_verification.md), [FairPlay kexts](Kernel/kernel_fairplay_kexts.md), [base validation 1–5](Kernel/kernel_patch_base_first5_validation.md), [11–15](Kernel/kernel_patch_base_11_15_validation.md), [16–20](Kernel/kernel_patch_base_16_20_validation.md), [sandbox hooks](Kernel/kernel_patch_sandbox_hooks_17_26_validation.md), [individual patch notes](KernelJailbreakPatches/README.md) |
| Other patches and captures | [Launchd jetsam](Patches/cfw_patch_launchd_jetsam.md), [user-mode hypervisor references](Patches/hv_vmm_present_usermode_xrefs.md), [reference capture](Patches/patch_reference_capture.md) |
| Restore | [DFU probe](Restore/p2_dfu_spike.md), [in-process restore](Restore/p2_restore_off_python.md) |
| Host and archives | [Binary split](Host/host_binary_split.md), [runtime dependency tiers](Host/d2_d3_self_containment.md), [archive extraction contracts](Host/archive_extraction_contracts.md), [libarchive validation](Host/libarchive_xcframework_validation.md) |
| Guest interaction and VM identity | [DevMode XPC](Guest/devmode_xpc_protocol.md), [keyboard events](Guest/keyboard_event_pipeline.md), [machine identifier](Guest/machine_identifier_storage_analysis.md) |
| Historical project records | [Migration ledger](History/intg_update_status.md), [manifest refactoring summary](History/manifest_and_refactoring_summary.md) |

`KernelSymbols/` holds symbol datasets and indexes; `Reference/` holds source references when present. They are evidence inputs, not steps for running the distributed app. The files in `History/` are preserved snapshots and may describe scripts or variants that have since been removed.
