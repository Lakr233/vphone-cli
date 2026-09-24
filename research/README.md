# Research library

[Project overview](../README.md) · [User documentation](../docs/README.md)

This directory keeps the evidence behind firmware patches, restore and the self-contained host runtime. **The current public workflow is JB only.** Many notes record earlier experiments and command names; use the [user guides](../docs/README.md) and `vphone-cli --help` for current instructions.

## Start here

1. [Patch comparison](0_binary_patch_comparison.md) is the canonical per-component inventory. Its regular/dev/exp columns are historical.
2. [Firmware manifest and origins](firmware/firmware_manifest_and_origins.md) explains the hybrid firmware inputs.
3. [JB kernel patch notes](kernel/kernel_jb_patch_notes.md) and the [individual patch index](kernel_jailbreak_patches/README.md) lead to the kernel evidence.
4. [Native restore design](restore/p2_restore_off_python.md) and [self-contained runtime](host/d2_d3_self_containment.md) explain the host migration.

## By subject

| Subject | Notes |
| --- | --- |
| Firmware and boot chain | [Manifest and origins](firmware/firmware_manifest_and_origins.md), [iBoot patches](firmware/iboot_patches.md), [TXM full chain](firmware/txm_fullchain_analysis.md), [TXM JB patches](firmware/txm_jb_patches.md), [selector 24](firmware/txm_selector24_analysis.md), [variant differences](firmware/txm_variant_diff.md) |
| Kernel | [JB overview](kernel/kernel_jb_patch_notes.md), [patcher verification](kernel/kernel_patcher_verification.md), [FairPlay kexts](kernel/kernel_fairplay_kexts.md), [base validation 1–5](kernel/kernel_patch_base_first5_validation.md), [11–15](kernel/kernel_patch_base_11_15_validation.md), [16–20](kernel/kernel_patch_base_16_20_validation.md), [sandbox hooks](kernel/kernel_patch_sandbox_hooks_17_26_validation.md), [individual patch notes](kernel_jailbreak_patches/README.md) |
| Other patches and captures | [Launchd jetsam](patches/cfw_patch_launchd_jetsam.md), [user-mode hypervisor references](patches/hv_vmm_present_usermode_xrefs.md), [reference capture](patches/patch_reference_capture.md) |
| Restore | [DFU probe](restore/p2_dfu_spike.md), [in-process restore](restore/p2_restore_off_python.md) |
| Host and archives | [Binary split](host/host_binary_split.md), [runtime dependency tiers](host/d2_d3_self_containment.md), [archive extraction contracts](host/archive_extraction_contracts.md), [libarchive validation](host/libarchive_xcframework_validation.md) |
| Guest interaction and VM identity | [DevMode XPC](guest/devmode_xpc_protocol.md), [keyboard events](guest/keyboard_event_pipeline.md), [machine identifier](guest/machine_identifier_storage_analysis.md) |
| Historical project records | [Migration ledger](history/intg_update_status.md), [manifest refactoring summary](history/manifest_and_refactoring_summary.md) |

`kernel_symbols/` holds symbol datasets and indexes; `reference/` holds source references when present. They are evidence inputs, not steps for running the distributed app. The files in `history/` are preserved snapshots and may describe scripts or variants that have since been removed.
