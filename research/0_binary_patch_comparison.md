# Patch Comparison: Regular / Development / Jailbreak / Experimental

> **EXP is a JB superset.** Everything in the baseline tables below that is `Y`
> for JB is also `Y` for EXP. The columns are kept at three variants to avoid
> noise — the only place EXP and JB diverge is the **Experimental additions**
> below, all of which are EXP-only (JB and the other variants are deliberately
> unaffected). The EXP-only items, taken together:
>
> - **Kernel** — `KernelEXPPatcher` runs the `hv_vmm_present` sysctl OID rename
>   plus kernel-internal caller cstring/sandbox-profile-token mangle (formerly
>   wired into JB Group B as JB-26 — moved out).
> - **DeviceTree at fw_patch time** — 8 identity-rewrite property patches
>   (Tier 1b + 1c) flipping userland-visible identity surfaces toward
>   D47AP / iPhone17,3.
> - **DSC user-mode** — byte-5 cstring mangle of `kern.hv_vmm_present` with a
>   sign-in blacklist + per-page slot re-attestation (`cfw_patch_hv_vmm_dsc.py`),
>   companion to the kernel rename.
> - **watchdogd (EXP-JB-3.5)** — surgical 2-instruction patch + slot re-attest;
>   forces the cached "am I a VM?" byte to `1` so watchdogd's clean-exit branch
>   runs.
> - **Post-restore DT rewrite (EXP-JB-6)** — host-side rewrite of `devicetree.img4`
>   on the ramdisk's mounted rootfs for the three restore-fatal identity
>   properties (root `model`, `target-type`, `compatible[0]`) that broke
>   restore when applied at fw_patch time.
> - **SystemVersion.plist `ProductBuildVersion` (EXP-JB-7, opt-in)** — gated on
>   `SPOOF_BUILD=<id>`. Rewrites the build identifier in the rootfs and
>   cryptex copies of `SystemVersion.plist`.
> - **Camera.app accessibility** — at fw_patch time: the `/product/camera`
>   node, two `/product` cam-offset rewrites (Tier B), three new
>   `/product` child nodes `facetime` / `audio` / `iopm` (Tier C), and
>   five minimal `/arm-io` stubs `isp` / `ispRtb` /
>   `smc/iop-smc-nub/smc-ext-charger` carrying camera-front, camera-rear
>   and camera-driver (Tier F). At install time: the 5
>   `+[_NUStyleTransfer*Processor processWithInputs:...]` DSC
>   short-circuits in NeutrinoCore plus a 1-instruction
>   `+[AVCaptureDevice authorizationStatusForMediaType:]` rewrite in
>   AVFCapture that returns `Authorized` for any media type
>   (Stage 0 of the vcam stack — auth gate only; downstream
>   cameracaptured/vcamd plumbing for actual frame delivery is open
>   work). Together these make Camera.app's icon show on the home
>   screen and in Spotlight, the viewfinder render, and arbitrary apps
>   stop bailing on the camera permission check. The NeutrinoCore patch
>   stops the viewfinder's CIImageProcessorKernel chain from asserting
>   on a nil descriptor when ANE detection comes back NO on the VM.

## Boot Chain Patches

### AVPBooter

| #   | Patch        | Purpose                          | Regular | Dev | JB  |
| --- | ------------ | -------------------------------- | :-----: | :-: | :-: |
| 1   | `mov x0, #0` | DGST signature validation bypass |    Y    |  Y  |  Y  |

### iBSS

| #   | Patch                               | Purpose                                                                                                            | Regular | Dev | JB  |
| --- | ----------------------------------- | ------------------------------------------------------------------------------------------------------------------ | :-----: | :-: | :-: |
| 1   | Serial labels (2x)                  | "Loaded iBSS" in serial log                                                                                        |    Y    |  Y  |  Y  |
| 2   | `image4_validate_property_callback` | Signature bypass (`b.ne` -> NOP, `mov x0,x22` -> `mov x0,#0`)                                                      |    Y    |  Y  |  Y  |
| 3   | Skip `generate_nonce`               | Keep apnonce stable for SHSH (`tbz` -> unconditional `b`)                                                          |    -    |  -  |  Y  |

### iBEC

| #   | Patch                               | Purpose                                                                                                            | Regular | Dev | JB  |
| --- | ----------------------------------- | ------------------------------------------------------------------------------------------------------------------ | :-----: | :-: | :-: |
| 1   | Serial labels (2x)                  | "Loaded iBEC" in serial log                                                                                        |    Y    |  Y  |  Y  |
| 2   | `image4_validate_property_callback` | Signature bypass                                                                                                   |    Y    |  Y  |  Y  |
| 3   | Boot-args redirect                  | ADRP+ADD -> `serial=3 -v debug=0x2014e %s`                                                                         |    Y    |  Y  |  Y  |
| 4   | Modern bootx-handoff panic bypass   | `IBootPatcher.patchBootxPrecondition` NOPs gate TBZ via structural anchor (no hash/line tied); no-op pre-26.4      |    Y    |  Y  |  Y  |
| 5   | Ramdisk boot-args overwrite         | `ramdisk_build.py:patch_ibec_bootargs` rewrites string to `... rd=md0 ... wdt=-1 ...` (ramdisk-send iBEC only)     |    Y    |  Y  |  Y  |

### LLB

| #   | Patch                               | Purpose                                                                                                            | Regular | Dev | JB  |
| --- | ----------------------------------- | ------------------------------------------------------------------------------------------------------------------ | :-----: | :-: | :-: |
| 1   | Serial labels (2x)                  | "Loaded LLB" in serial log                                                                                         |    Y    |  Y  |  Y  |
| 2   | `image4_validate_property_callback` | Signature bypass                                                                                                   |    Y    |  Y  |  Y  |
| 3   | Boot-args redirect                  | ADRP+ADD -> `serial=3 -v debug=0x2014e %s`                                                                         |    Y    |  Y  |  Y  |
| 4   | Rootfs bypass (5 patches)           | Allow edited rootfs loading                                                                                        |    Y    |  Y  |  Y  |
| 5   | Panic bypass                        | NOP `cbnz` after `mov w8,#0x328` check                                                                             |    Y    |  Y  |  Y  |

### TXM

| #   | Patch                                             | Purpose                                   | Regular | Dev | JB  |
| --- | ------------------------------------------------- | ----------------------------------------- | :-----: | :-: | :-: |
| 1   | Trustcache binary-search bypass                   | `bl hash_cmp` -> `mov x0, #0`             |    Y    |  Y  |  Y  |
| 2   | Selector24 bypass: `mov w0, #0xa1`                | Return PASS (byte 1 = 0) after prologue   |    -    |  Y  |  Y  |
| 3   | Selector24 bypass: `b <epilogue>`                 | Skip validation, jump to register restore |    -    |  Y  |  Y  |
| 4   | get-task-allow (selector 41\|29)                  | `bl` -> `mov x0, #1`                      |    -    |  Y  |  Y  |
| 5   | Selector42\|29 shellcode: branch to cave          | Redirect dispatch stub to shellcode       |    -    |  Y  |  Y  |
| 6   | Selector42\|29 shellcode: NOP pad                 | UDF -> NOP in code cave                   |    -    |  Y  |  Y  |
| 7   | Selector42\|29 shellcode: `mov x0, #1`            | Set return value to true                  |    -    |  Y  |  Y  |
| 8   | Selector42\|29 shellcode: `strb w0, [x20, #0x30]` | Set manifest flag                         |    -    |  Y  |  Y  |
| 9   | Selector42\|29 shellcode: `mov x0, x20`           | Restore context pointer                   |    -    |  Y  |  Y  |
| 10  | Selector42\|29 shellcode: branch back             | Return from shellcode to stub+4           |    -    |  Y  |  Y  |
| 11  | Debugger entitlement (selector 42\|37)            | `bl` -> `mov w0, #1`                      |    -    |  Y  |  Y  |
| 12  | Developer mode bypass                             | NOP conditional guard before deny path    |    -    |  Y  |  Y  |

## Kernelcache

### Base Patches (All Variants)

| #     | Patch                      | Function                         | Purpose                                            | Regular | Dev | JB  |
| ----- | -------------------------- | -------------------------------- | -------------------------------------------------- | :-----: | :-: | :-: |
| 1     | NOP `tbnz w8,#5`           | `_apfs_vfsop_mount`              | Skip root snapshot sealed-volume check             |    Y    |  Y  |  Y  |
| 2     | NOP conditional            | `_authapfs_seal_is_broken`       | Skip root volume seal panic                        |    Y    |  Y  |  Y  |
| 3     | NOP conditional            | `_bsd_init`                      | Skip rootvp not-authenticated panic                |    Y    |  Y  |  Y  |
| 4-5   | `mov w0,#0; ret`           | `_proc_check_launch_constraints` | Bypass launch constraints                          |    Y    |  Y  |  Y  |
| 6-7   | `mov x0,#1` (2x)           | `PE_i_can_has_debugger`          | Enable kernel debugger                             |    Y    |  Y  |  Y  |
| 8     | NOP                        | `_postValidation`                | Skip AMFI post-validation                          |    Y    |  Y  |  Y  |
| 9     | `cmp w0,w0`                | `_postValidation`                | Force comparison true                              |    Y    |  Y  |  Y  |
| 10-11 | `mov w0,#1` (2x)           | `_check_dyld_policy_internal`    | Allow dyld loading                                 |    Y    |  Y  |  Y  |
| 12    | `mov w0,#0`                | `_apfs_graft`                    | Allow APFS graft                                   |    Y    |  Y  |  Y  |
| 13    | `cmp x0,x0`                | `_apfs_vfsop_mount`              | Skip mount check                                   |    Y    |  Y  |  Y  |
| 14    | `mov w0,#0`                | `_apfs_mount_upgrade_checks`     | Allow mount upgrade                                |    Y    |  Y  |  Y  |
| 15    | `mov w0,#0`                | `_handle_fsioc_graft`            | Allow fsioc graft                                  |    Y    |  Y  |  Y  |
| 16    | NOP (3x)                   | `handle_get_dev_by_role`         | Bypass APFS role-lookup deny gates for boot mounts |    Y    |  Y  |  Y  |
| 17-26 | `mov x0,#0; ret` (5 hooks) | Sandbox MACF ops table           | Stub 5 sandbox hooks                               |    Y    |  Y  |  Y  |
| 27    | `PACIBSP→RET`              | `_thread_guard_violation`        | Disable EXC_GUARD delivery (match production behavior) |    -    |  Y  |  -  |

### JB-Only Kernel Methods (Reference List)

| #     | Group | Method                                | Function                                                                                             | Purpose                                                                                                                                                                              | JB Enabled |
| ----- | ----- | ------------------------------------- | ---------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | :--------: |
| JB-01 | A     | `patch_amfi_cdhash_in_trustcache`     | `AMFIIsCDHashInTrustCache`                                                                           | Always return true + store hash                                                                                                                                                      |     Y      |
| JB-02 | A     | `patch_amfi_execve_kill_path`         | AMFI execve kill return site                                                                         | Convert shared kill return from deny to allow (superseded by C21; standalone only)                                                                                                   |     N      |
| JB-03 | C     | `patch_cred_label_update_execve`      | `_cred_label_update_execve`                                                                          | Reworked C21-v3: C21-v1 already boots; v3 keeps split late exits and additionally ORs success-only helper bits `0xC` after clearing `0x3F00`; still disabled pending boot validation |     N      |
| JB-04 | C     | `patch_hook_cred_label_update_execve` | sandbox `mpo_cred_label_update_execve` wrapper (`ops[18]` -> `sub_FFFFFE00093BDB64`)                 | Faithful upstream C23 trampoline: copy `VSUID`/`VSGID` owner state into pending cred, set `P_SUGID`, then branch back to wrapper                                                     |     Y      |
| JB-05 | C     | `patch_kcall10`                       | `sysent[439]` (`SYS_kas_info` replacement)                                                           | Rebuilt ABI-correct kcall cave: `target + 7 args -> uint64 x0`; re-enabled after focused dry-run validation                                                                          |     Y      |
| JB-06 | B     | `patch_post_validation_additional`    | `_postValidation` (additional)                                                                       | Disable SHA256-only hash-type reject                                                                                                                                                 |     Y      |
| JB-07 | C     | `patch_syscallmask_apply_to_proc`     | syscallmask apply wrapper (`_proc_apply_syscall_masks` path)                                         | Faithful upstream C22: mutate installed Unix/Mach/KOBJ masks to all-ones via structural cave, then continue into setter; distinct from `NULL`-mask alternative                       |     Y      |
| JB-08 | A     | `patch_task_conversion_eval_internal` | `_task_conversion_eval_internal`                                                                     | Allow task conversion                                                                                                                                                                |     Y      |
| JB-09 | A     | `patch_sandbox_hooks_extended`        | Sandbox MACF ops (extended)                                                                          | Stub remaining 30+ sandbox hooks (incl. IOKit 201..210)|     Y      |
| JB-10 | A     | `patch_iouc_failed_macf`              | IOUC MACF shared gate                                                                                | A5-v2: patch only the post-`mac_iokit_check_open` deny gate (`CBZ W0, allow` -> `B allow`) and keep the rest of the IOUserClient open path intact                                    |     Y      |
| JB-11 | B     | `patch_proc_security_policy`          | `_proc_security_policy`                                                                              | Bypass security policy                                                                                                                                                               |     Y      |
| JB-12 | B     | `patch_proc_pidinfo`                  | `_proc_pidinfo`                                                                                      | Allow pid 0 info                                                                                                                                                                     |     Y      |
| JB-13 | B     | `patch_convert_port_to_map`           | `_convert_port_to_map_with_flavor`                                                                   | Skip kernel map panic                                                                                                                                                                |     Y      |
| JB-14 | B     | `patch_bsd_init_auth`                 | `_bsd_init` rootauth-failure branch                                                                  | Ignore `FSIOC_KERNEL_ROOTAUTH` failure in `bsd_init`; same gate as base patch #3 when layered                                                                                        |     Y      |
| JB-15 | B     | `patch_dounmount`                     | `_dounmount`                                                                                         | Allow unmount via upstream coveredvp cleanup-call NOP                                                                                                                                |     Y      |
| JB-16 | B     | `patch_io_secure_bsd_root`            | `AppleARMPE::callPlatformFunction` (`"SecureRootName"` return select), called from `IOSecureBSDRoot` | Force `"SecureRootName"` policy return to success without altering callback flow; implementation retargeted 2026-03-06                                                               |     Y      |
| JB-17 | B     | `patch_load_dylinker`                 | `_load_dylinker`                                                                                     | Skip strict `LC_LOAD_DYLINKER == "/usr/lib/dyld"` gate                                                                                                                               |     Y      |
| JB-18 | B     | `patch_mac_mount`                     | `___mac_mount`                                                                                       | Upstream mount-role wrapper bypass (`tbnz` NOP + role-byte zeroing)                                                                                                                  |     Y      |
| JB-19 | B     | `patch_nvram_verify_permission`       | `_verifyPermission` (NVRAM)                                                                          | Allow NVRAM writes                                                                                                                                                                   |     Y      |
| JB-20 | B     | `patch_shared_region_map`             | `_shared_region_map_and_slide_setup`                                                                 | Force root-vs-process-root mount compare to succeed before Cryptex fallback                                                                                                          |     Y      |
| JB-21 | B     | `patch_spawn_validate_persona`        | `_spawn_validate_persona`                                                                            | Upstream dual-`cbz` persona helper bypass                                                                                                                                            |     Y      |
| JB-22 | B     | `patch_task_for_pid`                  | `_task_for_pid`                                                                                      | Allow task_for_pid via upstream early `pid == 0` gate NOP                                                                                                                            |     Y      |
| JB-23 | B     | `patch_thid_should_crash`             | `_thid_should_crash`                                                                                 | Prevent GUARD_TYPE_MACH_PORT crash                                                                                                                                                   |     Y      |
| JB-24 | B     | `patch_vm_fault_enter_prepare`        | `_vm_fault_enter_prepare`                                                                            | Force `cs_bypass` fast path in runtime fault validation                                                                                                                              |     Y      |
| JB-25 | B     | `patch_vm_map_protect`                | `_vm_map_protect`                                                                                    | Skip upstream write-downgrade gate in `vm_map_protect`                                                                                                                               |     Y      |

### EXP-Only Kernel Methods (Reference List)

Runs in `KernelEXPPatcher.findAll()` (chained after `KernelPatcher` +
`KernelJBPatcher` for the `.exp` variant only — JB and other variants
do NOT execute these).

| #      | Group | Method                | Function                                                              | Purpose                                                                                                                                                                                                                                                                                                                                                                       | EXP Enabled |
| ------ | ----- | --------------------- | --------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | :---------: |
| EXP-01 | B     | `patch_hv_vmm_rename` | sysctl OID name cstring `"hv_vmm_present"` → `"Xv_vmm_present"` (Part A) + every kernel-internal occurrence of `kern.hv_vmm_present` cstring/sandbox-profile token mangled at byte 5 (Part B) | Rename the `kern.hv_vmm_present` OID's name in place (`'h' → 'X'` at offset 0 of the 14-byte cstring). After this: `sysctlbyname("kern.hv_vmm_present")` returns ENOENT; `sysctlbyname("kern.Xv_vmm_present")` returns the original int value (1). Part B mangles every kernel-internal caller — AMFI, IOCryptoAcceleratorFamily, sandbox-profile token, apfs — so they keep hitting the renamed OID. Companion to the user-mode blacklist-flip mangle in `cfw_patch_hv_vmm_dsc.py`. |      Y      |

## CFW Installation Patches

### Binary Patches Applied Over SSH Ramdisk

| #   | Patch                     | Binary                 | Purpose                                                       | Regular | Dev | JB  |
| --- | ------------------------- | ---------------------- | ------------------------------------------------------------- | :-----: | :-: | :-: |
| 1   | `/%s.gl` -> `/AA.gl`      | `seputil`              | Gigalocker UUID fix                                           |    Y    |  Y  |  Y  |
| 2   | NOP cache validation      | `launchd_cache_loader` | Allow modified `launchd.plist`                                |    Y    |  Y  |  Y  |
| 3   | `mov x0,#1; ret`          | `mobileactivationd`    | Activation bypass                                             |    Y    |  Y  |  Y  |
| 4   | Plist injection           | `launchd.plist`        | bash/dropbear/trollvnc/vphoned daemons                        |    Y    |  Y  |  Y  |
| 5   | `b` (skip jetsam guard)   | `launchd`              | Prevent jetsam panic on boot                                  |    -    |  Y  |  Y  |
| 6   | Weak dylib load injection | `launchd`              | Load short alias `/b` (copy of `launchdhook.dylib`) at launch. On by default; set `DISABLE_LAUNCHD_HOOK=1` to skip because this pid-1 hook path is boot-critical and has produced boot-analysis failures |    -    |  Y  |  Y  |
| 7   | cstring byte 5 mangle `'h' → 'X'` (`"kern.hv_vmm_present"` → `"kern.Xv_vmm_present"`) + per-page slot-hash re-attestation, BLACKLIST semantics — **EXP only** | DSC dylibs        | Companion to EXP kernel rename (`KernelEXPPatcher.patchHvVmmRename`). The mangle is applied to every DSC dylib EXCEPT those in `DONT_PATCH_INSTALL_NAMES` (sign-in / device-likeness consumers, ~15 entries). Patched dylibs query `kern.Xv_vmm_present` and get the truthful 1 (graphics / accel passthrough). Blacklisted dylibs keep the original cstring, hit ENOENT on the renamed kernel, cache 0, lie about VM presence. On `codeSigningMonitor == 2` hardware the byte-mangle alone causes `CODESIGNING/Invalid Page` SIGKILL because TXM enforces per-page hashes; the re-attestation pass recomputes the SHA-256 slot in the chunk's `CS_CodeDirectory` for every modified 16 KiB page. See `scripts/patchers/cfw_dsc_codesign.py` and `cfw_patch_hv_vmm_dsc.py`. |    -    |  -  |  -  |
| 8   | (removed — was: standalone-binary mangle in 6 rootfs Mach-Os via SSH) | n/a               | Removed in the blacklist-flip redesign. With the EXP kernel rename in place, the 6 rootfs binaries (MobileActivationMigrator, CheckerBoard, StoreKitUISceneService, storekitd, appstored, CorePrescriptionService) get the desired "cache 0 / not in a VM" behavior for free: they keep their original cstring, hit ENOENT on the renamed kernel sysctl, defensive `cbnz w0, skip` leaves the cached byte at BSS-zero. No SSH-time standalone patch needed. |    -    |  -  |  -  |

### Installed Components

| #   | Component                  | Description                                                                                                        | Regular | Dev | JB  |
| --- | -------------------------- | ------------------------------------------------------------------------------------------------------------------ | :-----: | :-: | :-: |
| 1   | Cryptex SystemOS + AppOS   | Decrypt AEA + mount + copy to device                                                                               |    Y    |  Y  |  Y  |
| 2   | GPU driver                 | AppleParavirtGPUMetalIOGPUFamily bundle                                                                            |    Y    |  Y  |  Y  |
| 3   | `iosbinpack64`             | Jailbreak tools (base set)                                                                                         |    Y    |  Y  |  Y  |
| 4   | `iosbinpack64` dev overlay | Replace `rpcserver_ios` with dev build                                                                             |    -    |  Y  |  -  |
| 5   | `vphoned`                  | vsock HID/control daemon (built + signed)                                                                          |    Y    |  Y  |  Y  |
| 6   | LaunchDaemons              | bash/dropbear/trollvnc/rpcserver_ios/vphoned plists                                                                |    Y    |  Y  |  Y  |
| 7   | Procursus bootstrap        | Bootstrap filesystem + optional Sileo deb                                                                          |    -    |  -  |  Y  |
| 8   | BaseBin hooks              | `systemhook.dylib` / `launchdhook.dylib` / `libellekit.dylib` -> `/cores/` plus `/b` alias for `launchdhook.dylib` |    -    |  -  |  Y  |
| 9   | `TweakLoader.dylib`        | Lean user-tweak loader built from source and installed to `/var/jb/usr/lib/TweakLoader.dylib`                      |    -    |  -  |  Y  |

### `kern.hv_vmm_present` user-mode patcher (EXP only)

Companion to the EXP kernel patcher (`KernelEXPPatcher.patchHvVmmRename`).
Mangles byte 5 of every `kern.hv_vmm_present` cstring inside DSC dylibs
EXCEPT those in `DONT_PATCH_INSTALL_NAMES` (sign-in / device-likeness
consumers, ~15 entries). Patched dylibs query the renamed OID and get the
truthful 1 (graphics + accel passthrough); blacklisted dylibs keep the
original cstring, hit ENOENT on the renamed kernel, and defensively cache 0
("not running on a VM") for sign-in / device-attestation surfaces.
Source-of-truth research: `research/hv_vmm_present_usermode_xrefs.md`.

JB and other variants are NOT affected by this patcher.

**Patch shape (every site)** — cstring mangle:

```
Before (cstring section bytes, 20 bytes total):
    "kern.hv_vmm_present\0"
    6B 65 72 6E 2E 68 76 5F 76 6D 6D 5F 70 72 65 73 65 6E 74 00

After (1 byte change at offset 0):
    "Xern.hv_vmm_present\0"
    58 65 72 6E 2E 68 76 5F 76 6D 6D 5F 70 72 65 73 65 6E 74 00
    ^^
```

The kernel's name-to-MIB translation fails with `ENOENT` when the
caller asks for `"Xern.hv_vmm_present"`, so `sysctlbyname` returns
-1. The canonical post-call check (`cbnz w0, skip` or
`cmp w0,#0 ; b.ne skip`) then takes the skip-cache path; the cached
"is_vmm" byte stays at its initial value (BSS-zero = 0).

We don't modify executable code at all — only one byte of read-only
string data. The kernel call still happens (with the wrong name), so
any sysctl-tracing infrastructure can still see activity.

Idempotent: a re-scan for the literal `"kern.hv_vmm_present\0"` finds
no occurrences in already-mangled dylibs, so the patcher does no work
on a re-run.

**DSC-side patches** — driven by an explicit whitelist
(`PATCH_INSTALL_NAMES` in `scripts/patchers/cfw_patch_hv_vmm_dsc.py`)
applied to chunks under
`SystemOS/System/Library/Caches/com.apple.dyld/`. Comment a line in
the whitelist to skip that dylib on the next install — useful for
bisecting which consumer is responsible for an observable change.

| Dylib                                                     | Component role (paraphrased)                                  |
| --------------------------------------------------------- | ------------------------------------------------------------- |
| `usr/lib/libMobileGestalt.dylib`                          | Backs `MGCopyAnswer("hv-vmm-present")` — highest fan-in       |
| `PrivateFrameworks/AAAFoundation.framework/AAAFoundation` | Apple ID anti-abuse plumbing                                  |
| `PrivateFrameworks/AuthKit.framework/AuthKit`             | Sign-in-with-Apple-ID / iCloud auth                           |
| `PrivateFrameworks/IDSFoundation.framework/IDSFoundation` | Apple Identity Service core (iMessage / FaceTime backbone)    |
| `PrivateFrameworks/DeviceIdentity.framework/DeviceIdentity` | Device-binding / device class identity                     |
| `PrivateFrameworks/DeviceCheckInternal.framework/...`     | DeviceCheck attestation                                       |
| `PrivateFrameworks/MobileActivation.framework/...`        | Activation flow                                               |
| `PrivateFrameworks/ApplePushService.framework/...`        | APNS client (claims device characteristics on connect)        |
| `PrivateFrameworks/AppStoreUtilities.framework/...`       | Store / IAP support                                           |
| `PrivateFrameworks/CorePrescription.framework/...`        | Health prescription store sync gate                           |
| `PrivateFrameworks/CoreCDP.framework/CoreCDP`             | CDP (cloud key-vault / iCloud Drive plumbing)                 |
| `PrivateFrameworks/EmailFoundation.framework/...`         | Mail account heuristics                                       |
| `PrivateFrameworks/PhotoFoundation.framework/...`         | Photos asset visibility heuristics                            |
| `PrivateFrameworks/FindMyBase.framework/FindMyBase`       | Find My anti-spoof                                            |
| `PrivateFrameworks/AirPlaySupport.framework/...`          | AirPlay receiver gate                                         |
| `PrivateFrameworks/TrialServer.framework/TrialServer`     | A/B / trial-rollout exclude-VM gate                           |
| `PrivateFrameworks/VisionKitCore.framework/VisionKitCore` | VisionKit                                                     |
| `PrivateFrameworks/DVTInstrumentsUtilities.framework/...` | Xcode Instruments support                                     |
| `PrivateFrameworks/WatchdogServiceManagement.framework/...` | Watchdog manager                                            |
| `Frameworks/CoreVideo.framework/CoreVideo`                | CoreVideo pipeline                                            |

**Standalone-binary patches (6 files, applied to the device rootfs
over SSH)**

| Path                                                                                              | Role                                                          |
| ------------------------------------------------------------------------------------------------- | ------------------------------------------------------------- |
| `/System/Library/DataClassMigrators/MobileActivationMigrator.migrator/MobileActivationMigrator`   | Activation migration helper                                   |
| `/Applications/CheckerBoard.app/CheckerBoard`                                                     | Apple internal accessibility test app                         |
| `/Applications/StoreKitUISceneService.app/StoreKitUISceneService`                                 | StoreKit UI host                                              |
| `/System/Library/Frameworks/StoreKit.framework/Support/storekitd`                                 | StoreKit / IAP daemon                                         |
| `/System/Library/PrivateFrameworks/AppStoreDaemon.framework/Support/appstored`                    | App Store daemon                                              |
| `/System/Library/PrivateFrameworks/CorePrescription.framework/XPCServices/CorePrescriptionService.xpc/CorePrescriptionService` | CorePrescription XPC service       |

**Explicitly NOT patched (compute / accel — patching here turns off
VM fast-paths that exist so the lib doesn't try to touch real silicon
ANE / AGX / hardware codecs):**

```
System/Library/Frameworks/CoreML.framework/CoreML
System/Library/PrivateFrameworks/Espresso.framework/Espresso
System/Library/PrivateFrameworks/AppleNeuralEngine.framework/AppleNeuralEngine
System/Library/PrivateFrameworks/CoreRE.framework/CoreRE
System/Library/PrivateFrameworks/RenderBox.framework/RenderBox
System/Library/PrivateFrameworks/WebGPU.framework/WebGPU
System/Library/PrivateFrameworks/caulk.framework/caulk
System/Library/PrivateFrameworks/IOSurfaceAccelerator.framework/IOSurfaceAccelerator
System/Library/ExtensionKit/Extensions/HostInferenceProviderService.appex/HostInferenceProviderService
```

**Wiring**

* `scripts/patchers/cfw_patch_hv_vmm.py` — standalone cstring patcher
  (used for the on-device files): finds the `"kern.hv_vmm_present\0"`
  cstring in the Mach-O's __cstring section and rewrites its first
  byte (`'k'` → `'X'`).
* `scripts/patchers/cfw_dsc_chunks.py` — chunked-DSC byte-level helper
  (`DSCChunks(chunks_dir)`): vmaddr↔chunk-fileoff mapping, cstring
  scan over executable mappings, byte read/write at a vmaddr, and
  Mach-O header walk-back to resolve a vmaddr to the dylib install
  name (LC_ID_DYLIB).
* `scripts/patchers/cfw_patch_hv_vmm_dsc.py` — DSC-native orchestrator.
  No external `ipsw` dependency. For every `"kern.hv_vmm_present\0"`
  occurrence in any executable mapping, walks back to the containing
  dylib's Mach-O header, reads `LC_ID_DYLIB`, and — if the install
  name is in the explicit `PATCH_INSTALL_NAMES` whitelist — rewrites
  the first byte of the cstring through `DSCChunks.write_at_vma`.
  Pure Python. Whitelist-based by design so an operator can comment
  out individual entries to bisect.
* `scripts/patchers/cfw.py patch-hv-vmm <binary>` —
  standalone-Mach-O subcommand (used for the 6 on-device files).
* `scripts/patchers/cfw.py patch-hv-vmm-dsc <chunks_dir>` —
  DSC subcommand (used while the SystemOS Cryptex DMG is still
  mounted on the host, before the device copy).
* `scripts/patch_hv_vmm_userland.sh` — thin wrapper used by the
  install scripts.
* `scripts/cfw_install_exp.sh` — EXP install script. Pre-step before
  invoking `cfw_install.sh`: decrypts the SysOS Cryptex into the cache
  location `cfw_install.sh` already uses, mounts it, applies the
  DSC patch, unmounts. The unmodified `cfw_install.sh` then sees the
  cached (already-patched) DMG. Standalone watchdogd is patched later
  via SSH at step `[EXP-JB-3.5]`.
* `scripts/cfw_install_jb.sh` and `scripts/cfw_install_dev.sh` —
  unchanged from pre-experimental baseline. Neither runs the DSC
  patcher.

### `kern.hv_vmm_present` kernel patcher — Part A + Part B (EXP only)

The `KernelEXPPatchHvVmmRename` Swift patcher (in `KernelEXPPatcher.findAll()`,
chained after `KernelPatcher` and `KernelJBPatcher` for the `.exp` variant only)
renames the sysctl OID and rewrites every kernel-internal occurrence of the
old name so kexts continue to find it under the new name. Two parts. JB and
other variants do NOT run this patcher.

**Part A — OID name rename.** Finds the OID's `oid_name` cstring as
the NUL-delimited bytes `\0hv_vmm_present\0` (exactly one match
required in the kernelcache; on iPhone17,3 / iOS 26.1 this lives at
file offset `0x964e0` inside `com.apple.kernel`). Flips byte 0 of the
cstring `'h'` (0x68) → `'X'` (0x58). After the patch, the kernel's
`sysctl_register_oid` keeps the OID's MIB and value (1) intact but
the name resolver returns `ENOENT` for `kern.hv_vmm_present` and
returns 1 for `kern.Xv_vmm_present`.

**Part B — kernel-internal caller mangle.** After Part A, any
kernel-side `sysctlbyname("kern.hv_vmm_present", …)` call gets
ENOENT and falls into the caller's "not in a VM" branch — which on
the bring-up build caused AMFI to panic with `AMFI: No PMGR?
(ConfigurationSettings.cpp:388)` during ramdisk boot. Part B mangles
every kernel-internal occurrence of the `kern.hv_vmm_present` name
so callers continue to find the renamed OID. The mangle flips byte
5 of the inner cstring (`'h'` after `kern.`) → `'X'`, producing
`kern.Xv_vmm_present`.

Two byte-aligned forms are searched, both anchored at the
`kern.hv_vmm_present` substring:

| Form | Needle | Where it lives | Mangle delta within needle |
|------|--------|----------------|----------------------------|
| (i) NUL-delimited cstring | `\0kern.hv_vmm_present\0` | `__TEXT,__cstring` of any kext that calls sysctlbyname by full name | +6 (skip leading NUL + 5) |
| (ii) Sandbox-profile name token | `kern.hv_vmm_present\x0f` | Inside a compiled sandbox-profile blob within `com.apple.security.sandbox`. The `\x0f` byte is the sandbox-profile end-of-name marker; the token has no leading NUL. | +5 |

On iPhone17,3 / iOS 26.1 / 23B85 the universe is 5 occurrences
(verified by raw substring scan over the kernelcache buffer):

| File offset | Fileset entry | Form |
|-------------|---------------|------|
| `0x541d56` | `com.apple.driver.AppleMobileFileIntegrity` | (i) cstring |
| `0x81bdc3` | `com.apple.iokit.IOCryptoAcceleratorFamily` | (i) cstring |
| `0xa6618b` | `com.apple.security.sandbox` | (ii) sandbox-profile name token |
| `0xbb0d55` | `com.apple.security.sandbox` | (i) cstring |
| `0xbce1f9` | `com.apple.filesystems.apfs` | (i) cstring |

Part B emits one patch record per match (5 total, plus Part A's 1)
under patch IDs `kernelcache_exp.hv_vmm_internal_caller_mangle` and
`kernelcache_exp.hv_vmm_oid_rename`. Idempotent: a re-run detects
already-mangled bytes (`kern.Xv_vmm_present` instead of
`kern.hv_vmm_present`) and reports the patch as already applied.

**Note on the sandbox-profile occurrence.** This was missed by the
original Part B because its needle required NUL on both sides. The
sandbox-profile blob stores OID names as TLV-framed tokens where the
trailing byte is `\x0f` (sandbox EOT) rather than a NUL. Without the
second needle, sandboxed callers that interpret the profile's
`kern.hv_vmm_present`-matching rule would still match against the
OLD name, while the OID itself has been renamed — so the rule's
ALLOW/DENY/audit action would never fire. With the second needle,
the rule's name token is rewritten to `kern.Xv_vmm_present` and
sandboxed callers that hit the renamed OID match the (rewritten)
rule as intended. Covered occurrence verified on
iPhone17,3 / iOS 26.1 / 23B85 at file offset `0xa6618b`.

### `watchdogd` surgical hv_vmm_present cache patch (EXP only)

**Why a dedicated patch.** After the EXP kernel-side OID rename
(`KernelEXPPatchHvVmmRename`), `sysctlbyname("kern.hv_vmm_present", ...)`
returns `ENOENT` on this image. `/usr/libexec/watchdogd` caches that
answer at startup. On `ENOENT` the cached byte stays at its BSS-zero
default (`0`) and the downstream `cbz w0, ...` at the IOWatchdog-lookup
site (`+0x58e0`) takes a branch into a `_os_crash` wrapper that does
`brk #1`. launchd's `_PanicOnCrash → PanicOnConsecutiveCrash = true`
flag in `com.apple.watchdogd.plist` escalates the SIGTRAP to a kernel
panic. The cstring-mangle approach used elsewhere doesn't apply here
because we want this binary to behave as if the sysctl returned `1`,
not as if it returned `ENOENT`.

**Patch shape.** Two-instruction surgical edit at every site in
watchdogd that has the canonical caching shape:

```
adrp x0, <page>
add  x0, x0, #<off>          ; "kern.hv_vmm_present"
...arg setup...
bl   _sysctlbyname
cbnz w0, <skip>              ; <-- patched: NOP
ldur w8, [x29, #-4]
cmp  w8, #0
cset wN, ne                  ; <-- patched: mov wN, #1
adrp xM, <page>
strb wN, [xM, #<imm>]        ; cached "am I a VM?" byte
```

Net effect: the cached byte is forced to `1` regardless of the sysctl
result, and watchdogd's pre-existing "detected virtual machine
environment, exiting..." clean-exit branch runs instead of the trap
path. Two functions in watchdogd match this shape on
`iPhone17,3 / iOS 26.1`; both are patched.

**Code signing.** The byte edit invalidates the SHA-256 slot hashes
for the 4 KiB pages containing the modifications in watchdogd's own
`CS_CodeDirectory`. The patcher recomputes those slot hashes in place
via `cfw_macho_codesign.reattest_modified_offsets` (4 KiB page size
read from the CD, correct tail-slot length, all present CDs). The
resulting CD mutation also changes the cdHash, but the existing JB
kernel patch `patch_amfi_cdhash_in_trustcache` accepts any cdHash, so
AMFI's trust-cache check still passes at execve. The patcher does NOT
re-sign with `ldid` — preserving the original Apple-issued code-signing
identifier (`com.apple.watchdogd`) is required for launchd's boot-task
identity validation; an earlier attempt to re-sign other rootfs
binaries with `ldid_sign` tripped this check on `mobile_obliterator`.

**Wiring.**

* `scripts/patchers/cfw_macho_codesign.py` — standalone-Mach-O
  page-hash re-attestation (parallel to `cfw_dsc_codesign.py` but
  parses `LC_CODE_SIGNATURE` directly, uses page size from the CD
  header, handles short tail slot, updates every present CD).
* `scripts/patchers/cfw_patch_watchdogd.py` — capstone-anchored
  pattern matcher + Keystone-assembled 2-insn patch + slot reattest.
  Idempotent.
* `scripts/patchers/cfw.py patch-watchdogd <binary>` — CLI subcommand.
* `scripts/patch_hv_vmm_userland.sh watchdogd <binary>` — thin shim
  used by the install script.
* `scripts/cfw_install_exp.sh` — invokes the patcher at step `[EXP-JB-3.5]`
  on the live `/mnt1/usr/libexec/watchdogd` (scp-down, patch, scp-up,
  chmod 0755). JB and DEV install scripts do NOT run this step.

### DeviceTree `/product/camera` node addition at fw_patch time (EXP only)

`DeviceTreePatcher` carries an `experimentalNodeAdditions` list with one
entry — a `/device-tree/product/camera` child node. Applied only when
`includeIdentityPatches` is true (i.e. variant `.exp`); other variants
leave the product subtree unchanged.

| Property                            | Type          | Value | Purpose                                                 |
|-------------------------------------|---------------|-------|---------------------------------------------------------|
| `name`                              | cstring       | `camera` | DT node name (auto-added from `nodeName`).           |
| `aggregate-camera`                  | uint32        | `1`   | Backs MG `aggregateCameraCapability` getter.            |
| `auto-focus`                        | uint32        | `1`   | Backs MG `autoFocusCameraCapability` getter.            |
| `flash`                             | uint32        | `1`   | Backs MG `cameraFlashCapability` getter.                |
| `pearl-camera`                      | uint32        | `1`   | Backs MG `pearlCameraCapability` getter.                |
| `panorama`                          | uint32        | `1`   | Backs MG `panoramaCameraCapability` getter.             |
| `pipelined-stillimage-capability`   | uint32        | `1`   | Backs MG `pipelinedStillImageCaptureCapability`.        |
| `rear-burst`, `front-burst`         | uint32        | `1`   | Backs MG burst-capability getters.                      |
| `video-cap`                         | uint32        | `2`   | Video capture level (real D47AP value).                 |
| `camera-hdr-version`                | uint32        | `3`   | HDR version (real D47AP value).                         |
| `camera-ui-version`                 | uint32        | `2`   | UI version selector (real D47AP value).                 |

Why this is necessary: `libMobileGestalt.dylib` resolves
`MGGetBoolAnswer("still-camera")` (cstring at vmaddr `0x1b1c5fedd`) via a
chain that reads `IODeviceTree:/product/camera` (cstring at vmaddr
`0x1b1c5832a`, **65 ADRP+ADD xrefs in the same dylib's `__text`**). The
canonical iPhone17,3 D47AP DT carries this node with 64 capability
properties; the vphone600AP DT ships **zero** `camera`, `audio`,
`facetime`, or `back-camera` references under `/product`. Without
the node, SpringBoard's `SBAppTags = ["still-camera"]` filter hides
Camera.app's icon and refuses to launch the bundle.

The node alone is not enough: the SBAppTags resolver also chains
through `/product` direct properties (`assistant`, `dictation`,
`compatible-device-fallback`, `chrome-identifier`, …), most of which
ship as 12-byte `'syscfg/XXXX'` cstring placeholders on vphone600 and
read back as NO. Tier 1d (below) rewrites those.

Idempotent: re-running against an already-patched DT detects the
existing child and skips.

### Camera DSC patch (EXP only)

`apply_all_camera_patches` in `scripts/patchers/cfw_patch_camera_dsc.py`
runs two patch families. Symbols are resolved per-build via
`ipsw dyld symaddr` against the cryptex's `dyld_shared_cache_arm64e`
header.

| # | Target | Framework | Effect |
|---|---|---|---|
| 1 | `+[_NUStyleTransfer{,Apply,Thumbnail,Learn,Interpolate}Processor processWithInputs:arguments:output:error:]` (5 entry points) | NeutrinoCore | Each replaced with `mov w0, #0; ret`. Camera's CIImageProcessorKernel chain that drives the style preview thumbnails short-circuits before reaching `+[_NUStyleEngine usingSharedStyleEngineForUsage:...]` → `_NUStyleEngineMemoryResource initWithDevice:descriptor:` which would otherwise assert on a nil descriptor (root cause is an upstream ANE-detection gate in `CMIStyleEngineCommonSettings`; we workaround at the consumer instead of unblocking it). |
| 2 | `+[AVCaptureDevice authorizationStatusForMediaType:]` | AVFCapture | Replaced with `mov w0, #3; ret` (AVAuthorizationStatusAuthorized = 3). Any process probing camera/audio/etc. media-type authorization gets "Authorized" without going through TCC. Stage 0 of the vcam stack — makes apps stop bailing on the auth check. Audio still doesn't work on the VM, so the broader scope is harmless (audio consumers would have failed downstream regardless). Downstream pipeline (cameracaptured rewrite, vcamd daemon) still owed for actual frame delivery. |

Wired into `cfw_install_exp.sh` immediately after the hv_vmm DSC step,
inside the same `hdiutil attach` block (one mount/unmount per install).
Page-hash re-attestation keeps the cryptex's CodeDirectory slots
consistent with the modified pages so `amfid` / TXM accepts the DSC at
next boot.

### DeviceTree identity properties at fw_patch time (EXP only)

`DeviceTreePatcher` carries two property-patch lists: `basePropertyPatches`
(4 entries — `serial-number`, `home-button-type`, `artwork-device-subtype`,
`island-notch-location`) applied for every variant, and
`identityPropertyPatches` (8 entries) applied **only when `includeIdentityPatches`
is true**, which `FirmwarePipeline` sets exactly when `variant == .exp`.

The 8 EXP-only identity properties (no restore-fatal ones — those go through
EXP-JB-6 post-restore):

| # | Node path                                          | Property              | Old → New                     | Risk    |
|---|----------------------------------------------------|-----------------------|-------------------------------|---------|
| 1 | `device-tree`                                      | `target-sub-type`     | `VPHONE600AP` → `D47AP`       | HIGHER  |
| 2 | `device-tree`                                      | `compatible[1]`       | `iPhone99,11` → `iPhone17,3` (slot-preserving) | LOW |
| 3 | `device-tree/product`                              | `fdr-product-type`    | `iPhone99,11` → `iPhone17,3`  | HIGHER  |
| 4 | `device-tree/product`                              | `sub-product-type`    | `iPhone99,11` → `iPhone17,3`  | LOW     |
| 5 | `device-tree/product`                              | `unique-model`        | `VPHONE600AP` → `D47AP`       | LOW     |
| 6 | `device-tree/arm-io`                               | `device_type`         | `vresearch1-io` → `t8140-io`  | MEDIUM  |
| 7 | `device-tree/arm-io`                               | `soc-generation`      | `VResearch1` → `H17`          | MEDIUM-LOW |
| 8 | `device-tree/product/vphone600-gestalt-variants`   | `name` (node rename)  | `vphone600-gestalt-variants` → `d47-gestalt-variants` | LOW-MEDIUM |

Root `model` and root `target-type` are deliberately NOT in this list —
both have been empirically shown to break restore. Those edits run
post-restore as EXP-JB-6.

Bulk `/product` direct-property completion (rewriting the ~30
`'syscfg/XXXX'` placeholders to D47AP integer/string values) was
attempted to make `MGGetBoolAnswer("still-camera")` answer YES via the
DT path alone. It broke screen rendering on the VM (the display
pipeline / framebuffer pulls one or more `/product` capability props
during init and chooses a render path the VM can't service). Reverted.
A narrower set targeted at the Camera-icon resolver chain (Tier B + C
+ F, below) does work without breaking display.

### DeviceTree Camera-icon completion (Tier B + C + F, EXP only)

Two `PropertyPatch` entries in `identityPropertyPatches`, three
`AddChildNodePatch` entries appended to `experimentalNodeAdditions`
for `/product/*` children, and five more for `/arm-io/*` stubs.
Empirically: this is the set that makes Camera.app's icon visible on
the home screen and in Spotlight without breaking screen rendering.

**Tier B — `/product` cam-offset rewrites.** vphone600 ships these
as 12-byte `'syscfg/{fcof,rcof}'` cstring placeholders. d47ap carries
20-byte little-endian geometry blobs. Consumed by Camera.app / ARKit
/ FaceTime for image-centering math.

| Property | Old length | New length | New value (hex) |
|----------|:----------:|:----------:|------------------|
| `/product::front-cam-offset-from-center` | 12 | 20 | `61000100921c0000d8130000e803000000000000` |
| `/product::rear-cam-offset-from-center`  | 12 | 20 | `eda50000b256000059080000e803000000000000` |

**Tier C — new `/product/*` child nodes.** d47ap carries three
sibling nodes to `/product/camera`. vphone600 has none of them.

| Node | Props | Camera relevance |
|------|:-----:|------------------|
| `/product/facetime` | 9 (excl. AAPL,phandle) | Front-camera video-call config — bitrates, codec encoding/decoding, tnr-mode-back/front. |
| `/product/audio` | 31 (excl. AAPL,phandle) | Carries `supports-spatial-audio-capture=1` + `supports-spatial-facetime=1` (camera-joint). Rest is audio config. |
| `/product/iopm` | 2 (excl. AAPL,phandle) | `aot-mode=13` + `aot-linger-time-ms=0`. Always-On Technology mode. |

All property values copied byte-for-byte from
`ipsws/iPhone17,3_26.5_23F77_Restore_extracted/Firmware/all_flash/DeviceTree.d47ap.im4p`.

**Tier F — `/arm-io/*` minimal camera-flag stubs.** d47ap carries
`/arm-io/isp` (65 props), `/arm-io/ispRtb` (53 props), and a deep
`/arm-io/smc/iop-smc-nub/smc-ext-charger` chain (3 levels of node).
vphone600 has none of these paths. We add minimal stub nodes carrying
ONLY the camera-* properties and the mandatory auto-`name`,
deliberately omitting `compatible`/`device_type`/`reg`/`interrupts`,
so no IOKit kext finds a matching `compatible=` and tries to probe
non-existent ISP / SMC hardware.

| Path | Property | Value |
|------|----------|-------|
| `/arm-io/smc` | (stub — parent for chain) | — |
| `/arm-io/smc/iop-smc-nub` | (stub — parent for charger) | — |
| `/arm-io/smc/iop-smc-nub/smc-ext-charger` | `camera-driver` | str `'AppleH16CamIn'` |
| `/arm-io/isp` | `camera-front`, `camera-rear` | int32:1, int32:1 |
| `/arm-io/ispRtb` | `camera-front`, `camera-rear` | int32:1, int32:1 |

Dependency order: the patcher walks `experimentalNodeAdditions` in
array order against the in-memory tree, so each entry that resolves
to a parent added by an earlier entry resolves correctly.

Idempotent: re-running the patcher against an already-modified DT
detects the existing child by name and skips. The DT IM4P that ships
on subsequent boots is signed by Apple but the existing iBSS/iBEC/LLB
`image4_validate_property_callback` bypass accepts arbitrary payloads.

### Post-restore DT identity rewrite (EXP-JB-6, EXP only)

After the restore daemon's BuildManifest identity check has passed,
`cfw_install_exp.sh` step `[EXP-JB-6]` scp's `devicetree.img4` down from the
mounted rootfs (`/mnt5/<boot-hash>/usr/standalone/firmware/`), runs
`scripts/patchers/cfw_patch_post_restore_dt.py`, and scp's the rewritten
img4 back. The Python patcher unwraps the IM4P via `pyimg4`, parses the
DT flat-binary, rewrites three restore-fatal root properties, and repacks
preserving the IMG4's original IM4M ticket. The iBSS/iBEC/LLB
`image4_validate_property_callback` bypass (existing JB patch) accepts
the modified payload at next boot.

| # | Property         | Old → New                                                              |
|---|------------------|------------------------------------------------------------------------|
| 1 | root `model`       | `iPhone99,11` → `iPhone17,3`                                          |
| 2 | root `target-type` | `VPHONE600` → `D47`                                                   |
| 3 | root `compatible`  | reorder `["VPHONE600AP", "iPhone99,11", "AVP-ARM"]` → `["D47AP", "VPHONE600AP", "AVP-ARM"]` (keeps `VPHONE600AP` in second slot so IOKit's `AppleVMApple1IO` kext binding still resolves; userland reads only the first entry for `hw.model`) |

Idempotent. Skipped if already-rewritten DT is detected.

### SystemVersion.plist `ProductBuildVersion` rewrite (EXP-JB-7, EXP only, opt-in)

Gated on the `SPOOF_BUILD` env var. When `cfw_install_exp.sh` is invoked
with e.g. `SPOOF_BUILD=23F77`, step `[EXP-JB-7]` runs
`scripts/patchers/cfw_patch_build_version.py` (plistlib-based,
format-preserving) on both the rootfs and cryptex copies of
`SystemVersion.plist` to rewrite the `ProductBuildVersion` key to the
specified id. Without `SPOOF_BUILD`, the step is skipped and the build
version stays at the original IPSW value.

| File                                                                              | Touched if `SPOOF_BUILD=<id>` |
|-----------------------------------------------------------------------------------|:------------------------------:|
| `/mnt1/System/Library/CoreServices/SystemVersion.plist` (rootfs)                  | Y                              |
| `/mnt5/Cryptexes/OS/System/Library/CoreServices/SystemVersion.plist` (cryptex)    | Y                              |

`kern.osversion` is unaffected — that comes from a kernel global
initialized from boot args, not from this plist. Userland MG cache
picks up the new build identifier on first boot after the gestalt
cache rebuild.

### CFW Installer Flow Matrix (Script-Level)

| Flow Item                                     | Regular (`cfw_install.sh`)      | Dev (`cfw_install_dev.sh`) | JB (`cfw_install_jb.sh`)                      | EXP (`cfw_install_exp.sh`)                            |
| --------------------------------------------- | ------------------------------- | -------------------------- | --------------------------------------------- | ----------------------------------------------------- |
| Base CFW phases (1/7 -> 7/7)                  | Runs directly                   | Runs directly              | Runs via `CFW_SKIP_HALT=1 zsh cfw_install.sh` | Runs via `CFW_SKIP_HALT=1 zsh cfw_install.sh`         |
| Dev overlay (`rpcserver_ios` replacement)     | -                               | Y (`apply_dev_overlay`)    | -                                             | -                                                     |
| SSH readiness wait before install             | Y (`wait_for_device_ssh_ready`) | -                          | Y (inherited from base run)                   | Y (inherited from base run)                           |
| launchd jetsam patch (`patch-launchd-jetsam`) | -                               | Y (base-flow injection)    | Y (JB-1)                                      | Y (JB-1)                                              |
| launchd dylib injection (`inject-dylib /b`)   | -                               | -                          | Y (JB-1, opt-out via `DISABLE_LAUNCHD_HOOK=1`) | Y (JB-1, opt-out via `DISABLE_LAUNCHD_HOOK=1`)        |
| Procursus bootstrap deployment                | -                               | -                          | Y (JB-2)                                      | Y (JB-2)                                              |
| BaseBin hook deployment (`*.dylib` -> `/mnt1/cores`) | -                        | -                          | Y (JB-3)                                      | Y (JB-3)                                              |
| First-boot JB finalization (`vphone_jb_setup.sh`) | -                           | -                          | Y (post-boot)                                 | Y (post-boot)                                         |
| DSC pre-patch (`kern.hv_vmm_present` byte-5 mangle + slot reattest) | -         | -                          | -                                             | Y (pre-step, before base CFW)                         |
| DSC camera patches (12 patches across CMCapture / CoreMediaIO / AVFCapture / libMobileGestalt) | - | -                  | -                                             | Y (pre-step, same cryptex mount as hv_vmm)            |
| `watchdogd` surgical 2-insn patch + slot reattest | -                           | -                          | -                                             | Y (EXP-JB-3.5)                                        |
| Post-restore DT identity rewrite (`devicetree.img4`)| -                         | -                          | -                                             | Y (EXP-JB-6)                                          |
| `SystemVersion.plist` `ProductBuildVersion` rewrite | -                         | -                          | -                                             | Y (EXP-JB-7, opt-in via `SPOOF_BUILD`)                |
| Additional input resources                    | `cfw_input`                     | `cfw_input` + `resources/cfw_dev/rpcserver_ios` | `cfw_input` + `cfw_jb_input` | `cfw_input` + `cfw_jb_input`        |
| Extra tool requirement beyond base            | -                               | -                          | `zstd`                                        | `zstd`                                                |
| Halt behavior                                 | Halts unless `CFW_SKIP_HALT=1`  | Halts unless `CFW_SKIP_HALT=1` | Always halts after JB phases              | Always halts after EXP phases                         |

## Summary

| Component                          | Regular | Dev |  JB | EXP |
| ---------------------------------- | ------: | --: | --: | --: |
| AVPBooter                          |       1 |   1 |   1 |   1 |
| iBSS                               |       2 |   2 |   3 |   3 |
| iBEC                               |       4 |   4 |   4 |   4 |
| LLB                                |       6 |   6 |   6 |   6 |
| TXM                                |       1 |  12 |  12 |  12 |
| Kernel (base)                      |      28 |  29 |  28 |  28 |
| Kernel (JB methods)                |       - |   - |  59 |  59 |
| Kernel (EXP methods, `hv_vmm`)     |       - |   - |   - |   6 |
| DeviceTree base properties         |       4 |   4 |   4 |   4 |
| DeviceTree EXP identity properties |       - |   - |   - |   8 |
| DeviceTree EXP node additions      |       - |   - |   - |   1 (`/product/camera`) |
| Boot chain total                   |      46 |  58 | 117 | 132 |
| CFW binary patches (base)          |       4 |   5 |   6 |   6 |
| CFW EXP-only steps                 |       - |   - |   - |   5 (hv_vmm DSC, camera DSC ×12, watchdogd EXP-JB-3.5, post-restore DT EXP-JB-6, build-version EXP-JB-7 opt-in) |
| CFW installed components           |       6 |   7 |   9 |   9 |
| CFW total                          |      10 |  12 |  15 |  31 |
| Grand total                        |      56 |  70 | 132 | 163 |

## Ramdisk Variant Matrix

| Variant        | Pre-step             | `Ramdisk/txm.img4`               | `Ramdisk/krnl.ramdisk.img4`                                                      | `Ramdisk/krnl.img4`                            | Effective kernel used by `ramdisk_send.sh`          |
| -------------- | -------------------- | -------------------------------- | -------------------------------------------------------------------------------- | ---------------------------------------------- | --------------------------------------------------- |
| `RAMDISK`      | `make fw_patch`      | release TXM + base TXM patch (1) | base kernel (28), legacy `*.ramdisk` preferred else derive from pristine CloudOS | restore kernel from `fw_patch` (28)            | `krnl.ramdisk.img4` preferred, fallback `krnl.img4` |
| `DEV+RAMDISK`  | `make fw_patch_dev`  | release TXM + base TXM patch (1) | base kernel (28), same derivation rule                                           | restore kernel from `fw_patch_dev` (29)        | `krnl.ramdisk.img4` preferred, fallback `krnl.img4` |
| `JB+RAMDISK`   | `make fw_patch_jb`   | release TXM + base TXM patch (1) | base kernel (28), same derivation rule                                           | restore kernel from `fw_patch_jb` (28+59)      | `krnl.ramdisk.img4` preferred, fallback `krnl.img4` |
| `EXP+RAMDISK`  | `make fw_patch_exp`  | release TXM + base TXM patch (1) | base kernel (28), same derivation rule                                           | restore kernel from `fw_patch_exp` (28+59+6)   | `krnl.ramdisk.img4` preferred, fallback `krnl.img4` |

## Cross-Version Dynamic Snapshot

| Case                | TXM_JB_PATCHES | KERNEL_JB_PATCHES |
| ------------------- | -------------: | ----------------: |
| PCC 26.1 (`23B85`)  |             14 |                59 |
| PCC 26.3 (`23D128`) |             14 |                59 |
| iOS 26.1 (`23B85`)  |             14 |                59 |
| iOS 26.3 (`23D127`) |             14 |                59 |

## Swift Migration Notes (2026-03-10)

- Swift `FirmwarePatcher` now matches the Python reference patch output across all checked components:
  - `avpbooter` 1/1
  - `ibss` 4/4
  - `ibec` 7/7
  - `llb` 13/13
  - `txm` 1/1
  - `txm_dev` 12/12
  - `kernelcache` 28/28
  - `ibss_jb` 1/1
  - `kernelcache_jb` 84/84
- JB parity fixes completed in Swift:
  - C23 `vnode_getattr` resolution now follows the Python backward BL scan and resolves `0x00CD44F8`.
  - C22 syscallmask cave encodings were corrected and centralized in `ARM64Constants.swift`.
  - Task-conversion matcher masks and kernel-text scan range were corrected, restoring the patch at `0x00B0C400`.
  - `jbDecodeBranchTarget()` now correctly decodes `cbz/cbnz`, restoring the real `_bsd_init` rootauth gate at `0x00F7798C`.
  - IOUC MACF matching now uses Python-equivalent disassembly semantics for the aggregator shape, restoring the deny-to-allow patch at `0x01260644`.
- C24 `kcall10` cave instruction bytes were re-verified against macOS `clang`/`as`; no Swift byte changes were needed.
- The Swift pipeline is now directly invokable from the product binary:
  - `vphone-cli patch-firmware --vm-directory <dir> --variant {regular|dev|jb}`
  - `vphone-cli patch-component --component {txm|kernel-base} --input <file> --output <raw>` is available for non-firmware tooling that still needs a single patched payload during ramdisk packaging
  - default loader now preserves IM4P containers via `IM4PHandler`
  - DeviceTree patching now uses the real Swift `DeviceTreePatcher` in the pipeline
  - project `make fw_patch`, `make fw_patch_dev`, and `make fw_patch_jb` targets now invoke this Swift pipeline via the unsigned debug `vphone-cli` build, while the signed release build remains reserved for VM boot/DFU paths
  - on 2026-03-11, the legacy Python firmware patcher entrypoints and patch modules were temporarily restored from pre-removal history for parity/debug work.
  - after byte-for-byte parity was revalidated against Python on `26.1` and `26.3` for `regular`, `dev`, and `jb`, those legacy firmware-patcher Python sources and transient comparison/export helpers were removed again so the repo keeps Swift as the single firmware-patching implementation.
- Swift pipeline follow-up fixes completed after CLI bring-up:
  - `findFile()` now supports glob patterns such as `AVPBooter*.bin` instead of treating them as literal paths.
  - JB variant sequencing now runs base iBSS/kernel patchers first, then the JB extension patchers.
  - Sequential pipeline application now merges each patcher's `PatchRecord` writes onto the shared output buffer while keeping later patcher searches anchored to the original payload, matching the standalone Swift/Python validation model.
  - `apply()` now reuses an already-populated `patches` array instead of re-running `findAll()`, so `patch-firmware` / `patch-component` no longer double-scan or double-print the same component diagnostics on a single invocation.
  - unaligned integer reads across the firmware patcher now go through a shared safe `Data.loadLE(...)` helper, fixing the JB IM4P crash (`Swift/UnsafeRawPointer.swift:449` misaligned raw pointer load).
  - `TXMPatcher` now preserves pristine Python parity by preferring the legacy trustcache binary-search site when present, and only falls back to the selector24 hash-flags call chain (`ldr x1, [x20,#0x38]` -> `add x2, sp, #4` -> `bl` -> `ldp x0, x1, [x20,#0x30]` -> `add x2, sp, #8` -> `bl`) when rerunning on a VM tree that already carries the dev/JB selector24 early-return patch.
  - `scripts/fw_prepare.sh` now deletes stale sibling `*Restore*` directories in the working VM directory before patching continues, so a fresh `make fw_prepare && make fw_patch` cannot accidentally select an older prepared firmware tree (for example `26.1`) when a newer one (for example `26.3`) was just generated.
- IM4P/output parity fixes completed after synthetic full-pipeline comparison:
  - `IM4PHandler.save()` no longer forces a generic LZFSE re-encode.
  - Swift now rebuilds IM4Ps in the same effective shape as the Python patch flow and only preserves trailing `PAYP` metadata for `TXM` (`trxm`) and `kernelcache` (`krnl`).
  - `IBootPatcher` serial labels now match Python casing exactly (`Loaded iBSS`, `Loaded iBEC`, `Loaded LLB`).
  - `DeviceTreePatcher` now serializes the full patched flat tree, matching Python `dtree.py`, instead of relying on in-place property writes alone.
- Synthetic CLI dry-run status on 2026-03-10 using IM4P-backed inputs under `ipsws/patch_refactor_input`:
  - regular: 58 patch records
  - dev: 69 patch records
  - jb: 154 patch records
- Full synthetic Python-vs-Swift pipeline comparison status on 2026-03-10 using `scripts/compare_swift_python_pipeline.py`:
  - regular: all 7 component payloads match
  - dev: all 7 component payloads match
  - jb: all 7 component payloads match
- Real prepared-firmware Python-vs-Swift pipeline comparison status on 2026-03-10 using `vm/` after `make fw_prepare`:
  - historical note: the now-removed `scripts/compare_swift_python_pipeline.py` cloned only the prepared `*Restore*` tree plus `AVPBooter*.bin`, `AVPSEPBooter*.bin`, and `config.plist`, avoiding `No space left on device` failures from copying `Disk.img` after `make vm_new`.
  - regular: all 7 component payloads match
  - dev: all 7 component payloads match
  - jb: all 7 component payloads match
- Runtime validation blocker observed on 2026-03-10:
  - `NON_INTERACTIVE=1 SKIP_PROJECT_SETUP=1 make setup_machine JB=1` reaches the Swift patch stage and reports `[patch-firmware] applied 154 patches for jb`, then fails when the flow transitions into `make boot_dfu`.
  - `make boot_dfu` originally failed at launch-policy time with exit `137` / signal `9` because the release `vphone-cli` could not launch on this host.
  - `amfidont` was then validated on-host:
    - it can attach to `/usr/libexec/amfid`
    - the initial path allow rule failed because `AMFIPathValidator` reports URL-encoded paths (`/Volumes/My%20Shared%20Files/...`)
    - rerunning `amfidont` with the encoded project path and the release-binary CDHash allows the signed release `vphone-cli` to launch
    - this workflow is now packaged as `make amfidont_allow_vphone` / `scripts/start_amfidont_for_vphone.sh`
  - With launch policy bypassed, `make boot_dfu` advances into VM setup, emits `vm/udid-prediction.txt`, and then fails with `VZErrorDomain Code=2 "Virtualization is not available on this hardware."`
  - `VPhoneAppDelegate` startup failure handling was tightened so these fatal boot/DFU startup errors now exit non-zero; `make boot_dfu` now reports `make: *** [boot_dfu] Error 1` for the nested-virtualization failure instead of incorrectly returning success.
  - The host itself is a nested Apple VM (`Model Name: Apple Virtual Machine 1`, `kern.hv_vmm_present=1`), so the remaining blocker is lack of nested Virtualization.framework availability rather than firmware patching or AMFI bypass.
  - `boot_binary_check` now uses strict host preflight and fails earlier on this class of host with `make: *** [boot_binary_check] Error 3`, avoiding a wasted VM-start attempt once the nested-virtualization condition is already known.
  - Added `make boot_host_preflight` / `scripts/boot_host_preflight.sh` to capture this state in one command:
    - model: `Apple Virtual Machine 1`
    - `kern.hv_vmm_present`: `1`
    - SIP: disabled
    - `allow-research-guests`: disabled
    - current `kern.bootargs`: empty
    - next-boot `nvram boot-args`: `amfi_get_out_of_my_way=1 -v` (staged on 2026-03-10; requires reboot before it affects launch policy)
    - `spctl --status`: assessments enabled
    - `spctl --assess` rejects the signed release binary
    - unsigned debug `vphone-cli --help`: exit `0`
    - signed release `vphone-cli --help`: exit `137`
    - freshly signed debug control binary `--help`: exit `137`

## Automation Notes (2026-03-06)

- `scripts/setup_machine.sh` non-interactive flow fix: renamed local variable `status` to `boot_state` in first-boot log wait and boot-analysis wait helpers to avoid zsh `status` read-only special parameter collision.
- `scripts/setup_machine.sh` non-interactive first-boot wait fix: replaced `(( waited++ ))` with `(( ++waited ))` in `monitor_boot_log_until` to avoid `set -e` abort when arithmetic expression evaluates to `0`.
- `scripts/jb_patch_autotest.sh` loop fix for sweep stability under `set -e`: replaced `((idx++))` with `(( ++idx ))`.
- `scripts/jb_patch_autotest.sh` zsh compatibility fix: renamed per-case result variable `status` to `case_status` to avoid `status` read-only special parameter collision.
- `scripts/jb_patch_autotest.sh` selection logic update:
  - default run now excludes methods listed in `KernelJBPatcher._DEV_SINGLE_WORKING_METHODS` (pending-only sweep).
  - set `JB_AUTOTEST_INCLUDE_WORKING=1` to include already-working methods and run the full list.
- Sweep run record:
  - `setup_logs/jb_patch_tests_20260306_114417` (2026-03-06): aborted at `[1/20]` with `read-only variable: status` in `jb_patch_autotest.sh`.
  - `setup_logs/jb_patch_tests_20260306_115027` (2026-03-06): rerun after `status` fix, pending-only mode (`Total methods: 19`).
- Final run result from `jb_patch_tests_20260306_115027` at `2026-03-06 13:17`:
  - Finished: 19/19 (`PASS=15`, `FAIL=4`, all fails `rc=2`).
  - Failing methods at that time: `patch_bsd_init_auth`, `patch_io_secure_bsd_root`, `patch_vm_fault_enter_prepare`, `patch_cred_label_update_execve`.
  - 2026-03-06 follow-up: `patch_io_secure_bsd_root` failure is now attributed to a wrong-site patch in `AppleARMPE::callPlatformFunction` (`"SecureRoot"` gate at `0xFFFFFE000836E1F0`), not the intended `"SecureRootName"` deny-return path. The code was retargeted the same day to `0xFFFFFE000836E464` and re-enabled for the next restore/boot check.
  - 2026-03-06 follow-up: `patch_bsd_init_auth` was retargeted after confirming the old matcher was hitting unrelated code; keep disabled in default schedule until a fresh clean-baseline boot test passes.
  - Final case: `[19/19] patch_syscallmask_apply_to_proc` (`PASS`).
  - 2026-03-06 re-analysis: that historical `PASS` is now treated as a false positive for functionality, because the recorded bytes landed at `0xfffffe00093ae6e4`/`0xfffffe00093ae6e8` inside `_profile_syscallmask_destroy` underflow handling, not in `_proc_apply_syscall_masks`.
  - 2026-03-06 code update: `scripts/patchers/kernel_jb_patch_syscallmask.py` was rebuilt to target the real syscallmask apply wrapper structurally and now dry-runs on `PCC-CloudOS-26.1-23B85 kernelcache.research.vphone600` with 3 writes: `0x02395530`, `0x023955E8`, and cave `0x00AB1720`. User-side boot validation succeeded the same day.
- 2026-03-06 follow-up: `patch_kcall10` was rebuilt from the old ABI-unsafe pseudo-10-arg design into an ABI-correct `sysent[439]` cave. Focused dry-run on `PCC-CloudOS-26.1-23B85 kernelcache.research.vphone600` now emits 4 writes: cave `0x00AB1720`, `sy_call` `0x0073E180`, `sy_arg_munge32` `0x0073E188`, and metadata `0x0073E190`; the method was re-enabled in `_GROUP_C_METHODS`.
  - Observed failure symptom in current failing set: first boot panic before command injection (or boot process early exit).
- Post-run schedule change (per user request):
  - commented out failing methods from default `KernelJBPatcher._PATCH_METHODS` schedule in `scripts/patchers/kernel_jb.py`:
    - `patch_bsd_init_auth`
    - `patch_io_secure_bsd_root`
    - `patch_vm_fault_enter_prepare`
    - `patch_cred_label_update_execve`
- 2026-03-06 re-research note for `patch_cred_label_update_execve`:
  - old entry-time early-return strategy was identified as boot-unsafe because it skipped AMFI exec-time `csflags` and entitlement propagation entirely.
  - implementation was reworked to a success-tail trampoline that preserves normal AMFI processing and only clears restrictive `csflags` bits on the success path.
  - default JB schedule still keeps the method disabled until the reworked strategy is boot-validated.
- Manual DEV+single (`setup_machine` + `PATCH=<method>`) working set now includes:
  - `patch_amfi_cdhash_in_trustcache`
  - `patch_amfi_execve_kill_path`
  - `patch_task_conversion_eval_internal`
  - `patch_sandbox_hooks_extended`
  - `patch_post_validation_additional`
- 2026-03-07 host-side note:
  - reviewed private Virtualization.framework display APIs against the recorder pipeline in `sources/vphone-cli/VPhoneScreenRecorder.swift`.
  - replaced the old AppKit-first recorder path with a private-display-only implementation built around hidden `VZGraphicsDisplay._takeScreenshotWithCompletionHandler:` capture.
  - added still screenshot actions that can copy the captured image to the pasteboard or save a PNG to disk using the same private capture path.
  - `make build` is used as the sanity check path; live VM validation is still needed to confirm the exact screenshot object type returned on macOS 15.
- 2026-03-15 tooling source sync update:
  - removed ad-hoc `git clone` source fetching from `scripts/setup_tools.sh` and `scripts/setup_libimobiledevice.sh`.
  - added pinned git-submodule sources under `scripts/repos/` for: `trustcache`, `insert_dylib`, `libplist`, `libimobiledevice-glue`, `libusbmuxd`, `libtatsu`, `libimobiledevice`, `libirecovery`, `idevicerestore`.
  - setup scripts now initialize required submodules via `git submodule update --init --recursive <path>` and stage build copies under local tool build directories.
- 2026-06-15 cloudOS 26.5 (23F77) JB retargeting — P0 (sudo/setuid):
  - **JB-04 `patch_hook_cred_label_update_execve` (P0, sudo/setuid) — FIXED.**
    Root cause: `findVfsContextCurrentByShape()` pinned a 5-word prologue ending
    in `ldr x1, [x0, #0x3E0]`; the uthread offset drifted to `#0x3F0` on 26.5
    (`0x3E8` on macOS 26.5.1 KDK), so the exact match returned 0 hits.
    Fix: resolve `vfs_context_current` generically — symbol first, else the stable
    4-word prologue prefix (`pacibsp; stp x29,x30,[sp,#-0x10]!; mov x29,sp;
    mrs x0,tpidr_el1`) followed by *any* `ldr x1,[x0,#imm]` (imm left unpinned);
    uniqueness still required. Reveal: on the decompressed kernelcache the prefix
    matches 5 sites, exactly one followed by an `ldr x1,[x0,#imm]` →
    `vfs_context_current` @ va `0x8D7F39C` (foff `0x1D7B39C`). Validated via
    `make test_jb_patches`: both `jb.hook_cred_label.{ops_retarget,c23_cave}` emit.
  - Symbol oracle for the above: macOS 26.5.1 KDK (`KDK_26.5.1_25F80`) —
    `kernel.release.vmapple` + `Sandbox.kext`/`AMFI.kext` (arm64e) carry full nlist
    symbol tables for the XNU/Sandbox functions stripped from the vphone600 cache.
  - Remaining 26.5 JB failures (8) still open: `task_conversion_eval` (inlined),
    `proc_security_policy` + `proc_pidinfo` (shared `_proc_info` switch refactored,
    `cmp #0x21` bound gone), `io_secure_bsd_root` (iOS-only, absent from KDK),
    `mac_mount`, `spawn_validate_persona` (iOS-only), `vm_map_protect`,
    `kcall10`/`sysent`.
- 2026-06-16 cloudOS 26.5 (23F77) JB retargeting — the 8 remaining P1 failures, all FIXED.
  Ground truth: IDA (idasql) on the decompressed `kernelcache.research.vphone600`,
  symbolicated via the macOS KDK oracle; XNU source cross-check. Validation:
  `make test_jb_patches` → every supported cloudOS kernel applies with **0** `[-]`
  failures (84 patches each). All anchors are version-independent
  (semantic/Capstone/call-graph), no pinned offsets/indices.
  - **JB-11 `proc_security_policy` + JB-12 `proc_pidinfo` (shared root cause).**
    The `sub wN,wM,#1 ; cmp wN,#0x21` switch anchor matched TWO sites on 26.5; the
    naive first-match grabbed the wrong one (`decodeWakeReason`, lower address).
    Replaced the whole `findProcInfoAnchor` with two source-backed finders in
    `KernelJBPatcherBase.swift`: `findProcSecurityPolicy()` locates the unique
    function that loads `PRIV_GLOBAL_PROC_INFO` (1002 = `0x3EA`, a stable
    `bsd/sys/priv.h` ABI value) into `w1` ahead of `priv_check_cred` →
    `_proc_security_policy` @ va `0x927E330` (stub entry `mov x0,#0; ret`);
    `findProcInfoInternal()` = its sole caller via `blIndex` → `_proc_info_internal`
    @ `0x927B38C` (proc_pidinfo is now inlined there). proc_pidinfo NOPs the unique
    `ldr x0,[x0,#0x18]; cbz x0; bl; cbz/cbnz wN; mov w0,#0x16(EINVAL); sub wN,wM,#1`
    guard pair → `0x927BDA8` / `0x927BDB0`.
  - **JB-08 `task_conversion_eval_internal`.** Inlined; recovered via the unique
    `"…pineapple on pizza…"` panic-string function (`task_get_special_port_from_user`).
    The 26.1 matcher failed only because the compare operands swapped
    (`cmp x0,x9` vs `cmp x9,x0`). Rewrote `collectTaskConversionCandidates` to accept
    the kernel_task-vs-{X0,X1} compare in EITHER operand order. Unique hit
    `cmp x0,x9 → cmp xzr,xzr` @ va `0x8D087A8`.
  - **JB-?? `io_secure_bsd_root`.** `AppleARMPE::callPlatformFunction` (refs both
    `"SecureRoot"`+`"SecureRootName"`). The match-bit compare-context moved >0xA0 back
    (sync code inserted), breaking the old lookback. Re-anchored on the unique
    `csel Wd,wzr,Wn,<cond>` whose `Wn` is built as `kIOReturnNotPrivileged`
    (`movk Wn,#0xE000,lsl#16` — IOKit error high half). `csel w22,wzr,w9,ne →
    mov w22,#0` @ va `0x7B30E10`. Dropped the pinned `[x19,#0x11A]` field offset.
  - **JB-?? `mac_mount`.** Wrapper still uniquely identified by the twin gates among
    `mount_common` callers (`__mac_mount` @ `0x8EC04F0`). Site 1 (`tbnz wFlags,#5 →
    mov w?,#1` preboot reject) unchanged → NOP @ `0x8EC06FC`. Site 2 folded on 26.5:
    `add x?,#0x70 ; ldrb w8,[x?,#1] ; tbz w8,#6` → `ldrb w8,[x16,#0x71] ; tbnz w8,#6`.
    Re-anchored `findStateGate` on the `ldrb wN,[x,#imm] ; tbz/tbnz wN,#6` pair (the
    `#6` role bit is the stable semantic) and clear the loaded reg → `mov x8,xzr`
    @ `0x8EC072C`.
  - **JB-?? `spawn_validate_persona`** @ `0x91C0D4C` (reached from the spawn
    entitlement wrapper, intact). The trailing `mov x?,#0 ; ldr x?,[x?,#0x490] ; casa`
    corroboration lowered differently on 26.5; re-anchored `matchPersonaHelper` on the
    dual sibling reject `ldr [base,#8];cbz / ldr [base,#0xc];cbz` (same base + same
    deny target + deny `mov w?,#1`), preceded by the `[_,#0x18]` sibling guard. NOP
    both cbz → `0x91C0DF8` / `0x91C0E00`.
  - **JB-25 `vm_map_protect`** @ `0x8DCA0A8`. The 26.1 `mov #6;bics;b.ne;tbnz#22;and
    #~X` block was recompiled; the per-entry apply path now narrows protection with a
    runtime W^X mask register before `pmap_protect_options`
    (`lsr wT,wFlags,#7 ; and w3,wT,wMask`, `mov wMask,#5`). Widening the mask `#5 → #7`
    makes the AND a pass-through so the requested protection (incl. the stripped bit)
    reaches the pmap — strictly permissive (`prot&7 ⊇ prot&5`). `mov w27,#5 → mov
    w27,#7` @ `0x8DCA30C`.
  - **JB-?? `kcall10` / sysent.** `findNosys()` matched an unrelated tiny
    `mov w0,#0x4e; ret` stub; the real `_nosys` is a large handler the sysent rows
    actually point to (112/558 entries). Rewrote `findSysentTable()` to find the table
    STRUCTURALLY (no `_nosys` dependency): the longest run of valid 24-byte `sysent`
    rows (chained auth-rebase `sy_call` into __TEXT_EXEC + sane
    `sy_return_type/sy_narg/sy_arg_bytes`). Base @ foff `0x7693B0` (558 rows);
    `sysent[439]` (`SYS_kas_info`) @ foff `0x76BCD8`; cave + 3 entry writes emit.
