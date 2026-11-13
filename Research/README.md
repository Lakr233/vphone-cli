# Research library

[Project overview](../README.md) · [User documentation](../Documents/en/README.md)

This directory keeps the evidence behind firmware patches, restore and the self-contained host runtime. **The current public workflow is JB only.** Many notes record earlier experiments and command names; use the [user guides](../Documents/en/README.md) and `vphone-cli --help` for current instructions.

## Working on vphone

- `vphone-launchpad`: a Mac app that downloads and installs `VPhone.bundle` and sets up the host. Released separately.
- `vphone-cli`: prepares firmware, patches it, restores the system, and manages VMs.
- `vphone-vm`: runs the VM and shows its window.
- `vphoned`: the control service inside the VM. The window's features and the API work through it.

| Path | Contents |
| --- | --- |
| [`VPhoneExecutable/`](../VPhoneExecutable/) | `vphone-cli`, `vphone-vm`, firmware patching and restore |
| [`VPhoneKit/`](../VPhoneKit/) | Shared host libraries and API client |
| [`VPhoneDaemon/`](../VPhoneDaemon/) | `vphoned` |
| [`VPhoneGuestComponents/`](../VPhoneGuestComponents/) | Hooks and helper programs inside the VM |
| [`VPhoneLaunchpad/`](../VPhoneLaunchpad/) | The Launchpad app and its helper |
| [`VPhoneWebsite/`](../VPhoneWebsite/) | This documentation site, built with Rspress from `Documents/` and `Research/` |

- `xcodebuild -workspace VPhone.xcworkspace -scheme VPhone build` produces and validates `VPhone.bundle`. Run each project's test scheme separately.
- The user manual is `Documents/<lang>/`, one identical tree per language (`en` is the source). Every manual page is listed in its language's `README.md`; the site's sidebar is built from those tables. Research notes stay in English.
- Preview the site with `npm ci && npm run dev` in `VPhoneWebsite/`.

## Start here

1. [Patch comparison](0_binary_patch_comparison.md) is the canonical per-component inventory. Its regular/dev/exp columns are historical.
2. [Firmware manifest and origins](Firmware/firmware_manifest_and_origins.md) explains the hybrid firmware inputs.
3. [CFW kernel patch notes](Kernel/kernel_jb_patch_notes.md) and the [individual patch index](KernelCustomFirmwarePatches/README.md) lead to the kernel evidence.
4. [Native restore design](Restore/native_restore_architecture.md) and [self-contained runtime](Host/runtime_dependency_tiers.md) explain the host migration.

## By subject

| Subject | Notes |
| --- | --- |
| Guest orientation | [SpringBoard language-change wedge and virtual gravity](Guest/springboard_orientation_stuck.md), [iPad pointer missing in landscape](Guest/ipad_pointer_landscape_scanout.md) |
| Firmware and boot chain | [Manifest and origins](Firmware/firmware_manifest_and_origins.md), [iBoot patches](Firmware/iboot_patches.md), [TXM full chain](Firmware/txm_fullchain_analysis.md), [TXM JB patches](Firmware/txm_jb_patches.md), [selector 24](Firmware/txm_selector24_analysis.md), [variant differences](Firmware/txm_variant_diff.md) |
| Kernel | [Native KDK extraction and byte-parity tests](Kernel/native_kdk_export.md), [CFW overview](Kernel/kernel_jb_patch_notes.md), [patcher verification](Kernel/kernel_patcher_verification.md), [FairPlay kexts](Kernel/kernel_fairplay_kexts.md), [base validation 1–5](Kernel/kernel_patch_base_first5_validation.md), [11–15](Kernel/kernel_patch_base_11_15_validation.md), [16–20](Kernel/kernel_patch_base_16_20_validation.md), [sandbox hooks](Kernel/kernel_patch_sandbox_hooks_17_26_validation.md), [individual patch notes](KernelCustomFirmwarePatches/README.md) |
| Other patches and captures | [Launchd jetsam](Patches/cfw_patch_launchd_jetsam.md), [user-mode hypervisor references](Patches/hv_vmm_present_usermode_xrefs.md), [reference capture](Patches/patch_reference_capture.md) |
| Restore | [DFU probe](Restore/virtual_dfu_probe.md), [in-process restore](Restore/native_restore_architecture.md) |
| Host and archives | [Binary split](Host/host_binary_split.md), [runtime dependency tiers](Host/runtime_dependency_tiers.md), [archive extraction contracts](Host/archive_extraction_contracts.md), [libarchive validation](Host/libarchive_xcframework_validation.md), [guest MAC, fixed address, port forwarding and names](Host/network_fixed_address.md), [machine identity and `vm clone --new-identity`](Host/machine_identity_and_clone.md) |
| VM disk space | [Where a VM's disk space goes](Host/disk_space.md) (overview and measured savings), [machine templates](Host/machine_templates.md), [sharing identical disk blocks with `vm rebase`](Host/disk_rebase.md), [guest TRIM and offline compaction](Host/guest_discard.md), [why the disk layout was not made deterministic](Host/deterministic_disk_layout.md), [why there is no content-addressed block store over NBD](Host/content_addressed_block_store.md) |
| Guest interaction and VM identity | [DevMode XPC](Guest/devmode_xpc_protocol.md), [keyboard events](Guest/keyboard_event_pipeline.md), [machine identifier](Guest/machine_identifier_storage_analysis.md), [Auto-Lock on the Lock Screen](Guest/lock_screen_idle_timer.md), [display refresh rate](Guest/display_refresh_rate.md), [GPU acceleration](Guest/gpu_acceleration.md), [RootHide bootstrap base](Guest/roothide_bootstrap_base.md), [the Mac's .local name](Guest/mac_name_resolution.md), [locationd startup deadlock](Guest/locationd_startup_deadlock.md), [host clock sync](Guest/host_clock_sync.md), [trimming system services](Guest/service_trimming.md), [deleting the orig-fs snapshot for templates](Guest/template_snapshot_deletion.md) |
| Historical project records | [Migration ledger](History/intg_update_status.md), [manifest refactoring summary](History/manifest_and_refactoring_summary.md) |

`KernelSymbols/` holds symbol datasets and indexes; `Reference/` holds source references when present. They are evidence inputs, not steps for running the distributed app. The files in `History/` are preserved snapshots and may describe scripts or variants that have since been removed.
