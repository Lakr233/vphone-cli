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
| 3   | Boot-args redirect                  | ADRP+ADD -> `serial=3 -v debug=0x2014e %s`; iOS 18 base adds `if_attach_nx=0x3` (skywalk BSD_ONLY: disables fsw netagents so Network.framework uses BSD sockets, fixes mDNSResponder skywalk-channel crash-loop / DNS) |    Y    |  Y  |  Y  |
| 4   | Modern bootx-handoff panic bypass   | `IBootPatcher.patchBootxPrecondition` NOPs gate TBZ via structural anchor (no hash/line tied); no-op pre-26.4      |    Y    |  Y  |  Y  |
| 5   | Ramdisk boot-args overwrite         | `ramdisk_build.py:patch_ibec_bootargs` rewrites string to `... rd=md0 ... wdt=-1 ...` (ramdisk-send iBEC only)     |    Y    |  Y  |  Y  |

### LLB

| #   | Patch                               | Purpose                                                                                                            | Regular | Dev | JB  |
| --- | ----------------------------------- | ------------------------------------------------------------------------------------------------------------------ | :-----: | :-: | :-: |
| 1   | Serial labels (2x)                  | "Loaded LLB" in serial log                                                                                         |    Y    |  Y  |  Y  |
| 2   | `image4_validate_property_callback` | Signature bypass                                                                                                   |    Y    |  Y  |  Y  |
| 3   | Boot-args redirect                  | ADRP+ADD -> `serial=3 -v debug=0x2014e %s`; iOS 18 base adds `if_attach_nx=0x3` (skywalk BSD_ONLY: disables fsw netagents so Network.framework uses BSD sockets, fixes mDNSResponder skywalk-channel crash-loop / DNS) |    Y    |  Y  |  Y  |
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
| 27    | `PACIBSP→RET`              | `_thread_guard_violation`        | Disable fatal EXC_GUARD (Mach port guard) delivery. Dev variant always; regular/jb/exp gain it automatically on **iOS 18 bases** (18.6.2's runningboardd/SpringBoard trip `GUARD_TYPE_MACH_PORT` "flavor 10", a guard the 26.1 kernel enforces fatally, crash-looping the UI). 26.x bases boot without it and are unaffected. | 18† | Y | 18† |

† iOS 18 bases only — auto-detected in `FirmwarePipeline` from `iPhone-BuildManifest.plist`'s `ProductVersion` (the pre-hybrid manifest fw_prepare preserves; the live BuildManifest reads the cloudOS 26.1 version). Passed to `KernelPatcher` as `applyExcGuard`, which gates patch 27.

### JB-Only Kernel Methods (Reference List)

> **⚠ iOS-27 hard-gate (2026-07-20).** Every patch below whose Purpose cites "iOS 27" / "27.0 on the 26.4 kernel" is **hard-gated to a 27.x base** via `KernelJBPatcher.applyIOS27` — set by `FirmwarePipeline` from the iPhone base `ProductVersion` (mirroring the `applyExcGuard`/iOS-18 mechanism at patch 27 above; standalone `patch-component` defaults it true, override with `--target-os`). Gated set: **JB-02b, JB-02d, JB-09 (the `ops[124]` entry only — the 201..316 hooks stay), JB-10b, JB-26, JB-27, JB-28**. On an 18.x/26.x base **none** of them run. This supersedes the per-row "No-op-in-effect for version-matched userlands" notes: those describe the effect *if applied*, but **JB-27 is NOT a no-op on 26.x** — its `cmp 0x588→0x6e0` retarget makes the 26.x userclient reject its own native 0x588 SwapEnd → dead display (the 26.5 regression that motivated the hard-gate). **Verified 2026-07-20:** a 26.5 base produces a **byte-identical** kernelcache to pre-branch `main` (`patch-component --component kernel-jb --target-os 26.5` vs main's output — `cmp` clean, 83 records each), and a 27.0 base additionally emits exactly the 11 gated records.

| #     | Group | Method                                | Function                                                                                             | Purpose                                                                                                                                                                              | JB Enabled |
| ----- | ----- | ------------------------------------- | ---------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | :--------: |
| JB-01 | A     | `patch_amfi_cdhash_in_trustcache`     | `AMFIIsCDHashInTrustCache`                                                                           | Always return true + store hash                                                                                                                                                      |     Y      |
| JB-02 | A     | `patch_amfi_execve_kill_path`         | AMFI execve kill return site                                                                         | Convert shared kill return from deny to allow (superseded by C21; standalone only)                                                                                                   |     N      |
| JB-02b| C     | `patch_exec_security_policy_kill`     | XNU exec `imgp->ip_mac_return` gate (kern_exec, `os_reason_create(OS_REASON_EXEC, EXEC_EXIT_REASON_SECURITY_POLICY)` site) | Flip `cbz wN, <skip>` → unconditional `b <skip>` so the exec-time MAC-verdict `SECURITY_POLICY` kill is unreachable. **Needed to run a userland NEWER than the kernel (iOS 27.0 on the 26.4 kernel):** AMFI's exec hooks reject the newer binaries' code-sign validation category, setting `ip_mac_return != 0` → core daemons (backboardd/cfprefsd/containermanagerd/…) die at exec (`namespace 9 / code 0x8`) → boot deadlock. Validated on 27.0/26.4: 0 SECURITY_POLICY kills, daemons launch, networking + SSH come up. No-op-in-effect for version-matched userlands (ip_mac_return == 0 there, so the original cbz already skips). |     Y      |
| JB-02d| C     | `patch_container_manager_upcall`      | sandbox `_hook_cred_label_update_execve` container-manager upcall guard: the `cbz w0,<success>` after `bl <container_manager_get_process_containers>`, on the `"failed to upcall to containermanagerd for a platform app"` fall-through | Flip `cbz w0,<success>` → unconditional `b <success>` so a FAILED exec-time container-manager upcall takes the success path instead of autobox/kill. **Needed to run iOS 27.0 on the 26.4 kernel:** iOS 27 DELETED the kernel-side containermanagerd upcall — the stock 27 kernel has no `HOST_CONTAINERD_PORT` / `CM_KERN_*` protocol (container resolution moved out of the kernel), so 27's containermanagerd no longer implements the reply server. On the 26.4 kernel the exec upcall therefore fails (`MACH_SEND_INVALID_DEST`) for every 27 platform app → they are autoboxed into the restrictive `temporary-sandbox` profile, which denies e.g. `mach-lookup com.apple.backboard.display.services` → Campo (the wallpaper renderer) crash-loops (no wallpaper) + intelligencetasksd/feedbackd. Re-registering the container-manager host special port is NOT viable: the 26.4 kernel then SENDS the synchronous `CM_KERN` MIG request and BLOCKS for a reply 27 cannot produce → early-boot deadlock (verified: boot hangs, never reaches SpringBoard). Anchor is structural (string xref to `"failed to upcall to containermanagerd"` → the `cbz w0` immediately preceding the string-load `adrp`, itself immediately preceded by the upcall `bl`; backward branch to the success continuation; unique). Replacement `b` from the Keystone-backed `ARM64Encoder`. **VALIDATED on-device (2026-07-15, `17,3_27.0_24A5380h` + cloudOS 26.4 `c0ecdb4b…`, JB): iOS 27 wallpaper renders, Campo/SpringBoard/backboardd stable, boot clean (no freeze, no panic).** No-op-in-effect for version-matched userlands (there the upcall succeeds → the original cbz already branches to `<success>`). |     Y      |
| JB-03 | C     | `patch_cred_label_update_execve`      | `_cred_label_update_execve`                                                                          | Reworked C21-v3: C21-v1 already boots; v3 keeps split late exits and additionally ORs success-only helper bits `0xC` after clearing `0x3F00`; still disabled pending boot validation |     N      |
| JB-04 | C     | `patch_hook_cred_label_update_execve` | sandbox `mpo_cred_label_update_execve` wrapper (`ops[18]` -> `sub_FFFFFE00093BDB64`)                 | Faithful upstream C23 trampoline: copy `VSUID`/`VSGID` owner state into pending cred, set `P_SUGID`, then branch back to wrapper                                                     |     Y      |
| JB-05 | C     | `patch_kcall10`                       | `sysent[439]` (`SYS_kas_info` replacement)                                                           | Rebuilt ABI-correct kcall cave: `target + 7 args -> uint64 x0`; re-enabled after focused dry-run validation                                                                          |     Y      |
| JB-06 | B     | `patch_post_validation_additional`    | `_postValidation` (additional)                                                                       | Disable SHA256-only hash-type reject                                                                                                                                                 |     Y      |
| JB-07 | C     | `patch_syscallmask_apply_to_proc`     | syscallmask apply wrapper (`_proc_apply_syscall_masks` path)                                         | Faithful upstream C22: mutate installed Unix/Mach/KOBJ masks to all-ones via structural cave, then continue into setter; distinct from `NULL`-mask alternative                       |     Y      |
| JB-08 | A     | `patch_task_conversion_eval_internal` | `_task_conversion_eval_internal`                                                                     | Allow task conversion                                                                                                                                                                |     Y      |
| JB-09 | A     | `patch_sandbox_hooks_extended`        | Sandbox MACF ops (extended)                                                                          | Stub remaining 30+ sandbox hooks (incl. IOKit 201..210) + `mpo_proc_check_syscall_unix` (`ops[124]`) → allow. **The ops[124] hook is the iOS-27 DDI-mount syscall fix:** MobileStorageMounter's `mount_apfs` needs the `mount(2)` syscall (unix 167) to mount the personalized DDI at `/System/Developer`; on the 26.4-kernel / 27-userland hybrid the kernel Sandbox otherwise denies it (`Protobox: mount_apfs deny(1) syscall-unix 167`). Index calibrated against the reference-XNU `mac_policy_ops` struct order (co-verified: mpo_vnode_check_open=267, mpo_vnode_check_fsgetpath=316). Validated live on `c0ecdb4b` 26.4 (DDI auto-mounts). |     Y      |
| JB-10 | A     | `patch_iouc_failed_macf`              | IOUC MACF shared gate                                                                                | A5-v2: patch only the post-`mac_iokit_check_open` deny gate (`CBZ W0, allow` -> `B allow`) and keep the rest of the IOUserClient open path intact                                    |     Y      |
| JB-10b| A     | `patch_iouc_failed_sandbox`           | IOUC *sandbox* shared gate (string `"IOUC %s failed sandbox in process %s"`)                          | **THE iOS-27 display fix (CONFIRMED 2026-07-15).** Sibling to JB-10: the IOUserClient open path has a SEPARATE Sandbox gate beyond the MACF one. On 27 userland / 26.4 kernel it spuriously DENIES the render server (backboardd) its IOMobileFramebuffer/IOSurface/HID userclient opens (27-specific: ABSENT on native 26.4; backboardd absent from every `IOUserClientCreator`) → no present (no Apple logo) + `mainDisplay=nil` → SpringBoard FBSDisplayMonitor crash-loop. Gate shape (same fn as JB-10): `blraa` sandbox check (PAC-indirect) → `cmp w0,#0xe00002c7` (kIOReturnNotPermitted) `b.eq <ALLOW>`; `ldr w8,[sp,#x]; cbnz w8,<DENY>` (other error → deny block w/ fail-log ADRP → returns error); w0==0 path → `b <ALLOW>`. Patch rewrites `<DENY>`'s first insn → `b <ALLOW>` (deny → allow-proceed), leaving the w0==0 path intact. Anchor is structural (fail-log string xref → the CBNZ whose target encloses it → the preceding `b.eq` allow target). Verified: backboardd then holds an IOMFB userclient, `[CADisplay mainDisplay]` resolves to `LCD/primary`, SpringBoard runs with 0 crashes. |     Y      |
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
| JB-25 | B     | `patch_vm_map_protect`                | `_vm_map_protect`                                                                                    | Skip upstream write-downgrade gate. Shape A (26.1–26.4) active; **Shape B (26.5) disabled 2026-07-05** — widened the `~VM_PROT_WRITE` COW strip (vm_map.c:6202) instead of the RWX gate (vm_map.c:5997), breaking COW and crashing the debugger (SPTM `VIOLATION_ILLEGAL_MAP`). Retired on 26.5+: SPTM code-mod (debugger + Substrate tweaks) uses write-then-flip via `vm_protect(VM_PROT_COPY)` → `XNU_USER_DEBUG`, so no RWX patch is needed. |    Y/N     |
| JB-26 | B     | `patch_iomfb_swapend_variable_size`   | IOMFB userclient method-5 (SwapEnd) `__DATA_CONST` dispatch entry (`checkStructureInputSize`)        | **iOS-27 VZ-view fix, kernel half — paired with DSC force-kern (DSC-patch item 11).** The 26.4 userclient's method-5 dispatch entry hard-checks `checkStructureInputSize == 0x588`; forced-kern iOS 27 sends its native `0x6e0`. Rewrite the size field to `kIOUCVariableStructureSize (0xFFFFFFFF)` so `IOUserClient::externalMethod` accepts 27's struct and reaches the handler. Anchor (structural): the sole `__DATA_CONST` entry `{ptr(ptrauth, top-byte≥0x80), scalarIn=0, structIn=0x588, scalarOut=0, structOut=0}` (verified unique; decompressed file-off 0x9c7228). No-op-in-effect for version-matched 26.x (sends 0x588). Re-enabled 2026-07-15 (was disabled when 27 present-path was still unknown). |     Y      |
| JB-27 | B     | `patch_iomfb_swapend_handler_size`    | method-5 handler internal size gate (`cmp w2,#0x588 ; b.ne <err>`)                                   | Companion to JB-26: beyond the dispatch-table check the handler re-checks the struct size (`cmp w2,#0x588 ; b.ne <kIOReturnBadArgument>`; verified unique at decompressed file-off 0x16ae22c; success path forwards the raw struct ptr to a `vtable+0x590` paravirt swap method). Retarget the `cmp` immediate to `0x6e0` so forced-kern iOS 27's native SwapEnd reaches real swap processing (27's IOMFBSwapRec prefix matches 26.x → handler reads valid fields). Semantic anchor (`cmp w2,#imm` word + following `b.ne` decode). Enabled together with JB-26 + DSC force-kern for iOS 27. |     Y      |
| JB-28 | A     | `patch_disk_images2_client_abi`       | `com.apple.driver.AppleDiskImages2` kext: `DIDeviceCreatorUserClient::CreateDevice` + `DIDeviceIOUserClient::Connect` ABI-version gates, and the `AllocPortsArray`/`RegisterNotificationPort` notif-port sizing | **iOS-27 DDI (`/System/Developer`) auto-mount — attach layer.** `pymobiledevice3 mounter auto-mount` on the 26.4-kernel / 27-userland hybrid fails at attach: the kernel DiskImages2 driver is ABI v9, the 27 userland's DiskImages2 controller/daemon is ABI v11 (`DIDeviceCreatorUserClient::CreateDevice: Incompatible client: expected ABI version 9 actual 11`). Three layers: **GATE1** NOPs the CreateDevice controller-ABI `cmp #9 ; b.ne` reject; **GATE2b** NOPs the Connect daemon-ABI `cmp #9 ; b.ne` reject (both anchored on the C++ signature cstring → unique `cmp #9`/`b.ne`; version-robust; no-op-in-effect on version-matched userlands where ABI 9==9). **GATE2** (array + 2 bound checks) fixes a RegisterNotificationPort off-by-one (userland registers at index==maxPorts, one past the array) by widening the AllocPortsArray allocation (`lsl x1,xN,#3` → `mov x1,#0x4000`) AND both bound-check field loads (`ldrh [.,#0xd8]`/`ldr [.,#0xe8]` → `mov wD,#0x800`); applied **all-or-nothing** (widening the bound checks without the backing array would let RegisterNotificationPort write past it → corruption) and skipped/logged on builds whose notif-port codegen differs (the off-by-one is 26.4-hybrid-specific). Pairs with the sandbox ops[124] allow (JB-09) and the diskimagesiod userland patch (CFW binary-patch #13). Anchors structural (Capstone decode of the pinned function's instructions); replacement bytes from the Keystone-backed `ARM64Encoder`. **GATE2a anchor note:** the AllocPortsArray size-shift is matched on `lsl` mnemonic + destination `x1` (the unique size-writing lsl in the function) — NOT a 3-operand `lsl xd,xn,#imm` shape, because Capstone on this toolchain decodes the lsl-immediate (a UBFM alias) as **2 operands**; requiring 3 operands makes GATE2 silently skip (the all-or-nothing returns a harmless no-op). Verified on the `c0ecdb4b` 26.4 deployment kernel via `patch-component --component kernel-jb --records-out`: all five di2 records emit (`di2_createdevice_abi`, `di2_connect_abi`, `di2_allocports_size`, `di2_notif_boundcheck_d8`, `di2_notif_boundcheck_e8`) — always verify the di2 records EMIT, not merely that the JB suite reports "no failures". No-op-in-effect for version-matched userlands. |     Y      |

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
| 9   | `mov w3,#<size>` -> `mov w3,#<base-size>` in `_kern_SwapEnd` — **26.0/26.0.1 and 18.x** | DSC `IOMobileFramebuffer` | Fixes host VZ GUI black-screen with the available PCC vphone600 userclient: the userclient does an exact `checkStructureInputSize` check on external-method-5 (SwapEnd) input, so a userland whose `_kern_SwapEnd` sends a different-sized state gets `kIOReturnBadArgument` and the host display stays black (guest still renders — the Apple logo is visible over VNC, just not in the vphone-cli view). **The accepted size is a property of the base kernel, not the userland**: 26.1 base -> **0x560**, 26.4 base (xnu-12377) -> **0x588**. The 0x588 value is confirmed two ways: the sole dispatch-shaped entry in `kernelcache.*.vphone600` with `checkStructureInputSize==0x588` (scalarIn=0, scalarOut=0, structOut=0, preceded by a ptrauth code ptr, at decompressed file offset 0x9c7228), and empirically — native 26.5 userland sends 0x588 and displays correctly on this stack. Source (userland-sent) sizes observed: 18.6.2 = 0x514, 26.0/26.0.1 = 0x548, 27.0 (24A5380h) = 0x6e0. The patcher is semantic (anchors on `mov w1,#5` -> `mov w3,#imm` -> `mov x4,#0`/`mov x5,#0` -> `bl` inside `_kern_SwapEnd`) and idempotent — rewrites the size to `--target-size` regardless of source and re-attests the modified DSC page. Install gate: `26.0*` / `18.*` -> 0x560 (26.1 base). Validated after host install on `17,3_26.0_23A341`, `17,3_26.0.1_23A355`, and `17,3_18.6.2_22G100` (Apple logo renders) against the 26.1 base. **CORRECTION (2026-07-15): iOS 27.0 is NO LONGER handled here.** 27 presents the paravirt display via IOMFB's `_virt_*` callback path — external method 5 is NEVER called — so no SwapEnd *size* change can help 27 (confirmed by kernel trace + live AppleParavirtGPU idle scheduler). iOS 27 now uses **force-kern (item 11)** to route present back onto method 5; this row applies to 26.0/26.0.1/18.x only. |    Y    |  Y  |  Y  |
| 10  | Zero `maxSlide` in `dyld_cache_header` (`@0xF0`) — **iOS 27.0 / any userland whose cache overflows the 6 GiB region** | DSC `dyld_shared_cache_arm64e` header | Fixes pid-1 `launchd` panic at boot on the vphone600 26.x kernel. The kernel reserves `SHARED_REGION_SIZE_ARM64 = 0x180000000` (6 GiB) and, at map time, needs room for the cache's mapped span **plus** the header `maxSlide` (ASLR range). iOS 27.0's cache (span `0x17c830000` ≈ 5.95 GiB) + `maxSlide 0x20000000` = `0x19c830000` > 6 GiB, so `_shared_region_map_and_slide` returns `ENOMEM`, dyld cannot map `libSystem.B.dylib`, and `launchd` panics (`initproc failed to start`). Zeroing `maxSlide` (LE u64) in the main chunk maps the cache at slide 0 (fits with ~58 MiB spare). Install gate: **`27.*`** (hard-gated in `cfw_install.sh` as of 2026-07-20 — an 18.x/26.x base skips it entirely). The patcher additionally self-gates (`patch-dsc-maxslide`): no-op unless span + maxSlide > `0x180000000`, kept as defense-in-depth so 26.x / 18.x are untouched even if the install gate were removed. **No** page re-attestation (header metadata, not a `cs_validate`'d code page — confirmed empirically). Validated on `17,3_27.0_24A5380h` + cloudOS 26.4 (`c0ecdb4b…`): `dyld cache mapped system-wide`, launchd reaches first unlock, vphoned connects as iOS 27.0.0, 0 panics. See `scripts/patchers/cfw_patch_dsc_maxslide.py`. |    Y    |  Y  |  Y  |
| 11  | Retarget public `_IOMobileFramebufferSwap*` trampolines -> `b _kern_Swap*` (force-kern) — **iOS 27.0** | DSC `IOMobileFramebuffer` | **iOS-27 VZ-view (host paravirt-GPU scanout) fix, userland half.** The host `VZVirtualMachineView` is fed by the guest `AppleParavirtGPU` scanout, which the 26.4 kernel drives ONLY from the IOMFB userclient SwapEnd (external method 5) — the `_kern_Swap*` path. iOS 27 defaults the paravirt display's present to IOMFB's parallel `_virt_Swap*` path (`_virt_SwapEnd` does no userclient call — it invokes an in-process callback `blraaz [conn+0xe68]` and hands the IOSurface to a virtual-display consumer), so the paravirt GPU never scans out → host VZ window black (guest still composites; GUI visible over in-guest TrollVNC; AppleParavirtGPU `SchedulerState` idle). The public `_IOMobileFramebufferSwap*` entrypoints are thin trampolines (`cbz x0; ldr xN,[x0,#slot]; cbz xN; braaz xN`) that tail-call the per-connection swap fp (kern or virt impl). This patch rewrites each trampoline's first insn to `b _kern_Swap<Name>`, forcing present onto method 5 regardless of how 27 classified the display (tail-call, args intact → behaviourally identical to selecting the kern fp). Fully dynamic: public + `_kern_` addrs resolved by name via `ipsw dyld symaddr`, trampoline shape verified by Capstone, branch bytes from Keystone `asm_at()`, modified DSC code pages re-attested. Requires ≥{SwapBegin,SwapEnd,SwapSetLayer} or raises (dry-run retargets 31 entrypoints on 24A5380h, skips 4 non-trampolines). **Pairs with the JB kernel patches (`patchIomfbSwapEndVariableSize` + `patchIomfbSwapEndHandlerSize`)** which relax the 26.4 userclient's two exact `0x588` size gates to accept 27's native `0x6e0` IOMFBSwapRec (prefix matches 26.x, so the paravirt swap handler reads valid fields). Install gate: `27.*`. See `scripts/patchers/cfw_patch_iomfb_force_kern.py`. **VALIDATED on-device (2026-07-15, `17,3_27.0_24A5380h` + cloudOS 26.4 `c0ecdb4b…`, JB): iOS 27 userland renders AND is interactive in the native VZ view (not just TrollVNC); clean boot — no `kIOReturnBadArgument`/SwapEnd rejection/panic.** Runtime confirmed 31 entrypoints retargeted (4 non-trampoline setters left on virt). |    Y    |  Y  |  Y  |
| 12  | NOP `-[_LSDModifyClient clientIsEntitledForEmbeddedRegistrationOperations]` entitlement gate + per-page re-attest — **iOS 27.0** | DSC `CoreServices` (LaunchServices) | **iOS-27 app-registration fix.** lsd gates `-[_LSDModifyClient performPostInstallationRegistration:operationUUID:reply:]` (and the containerized/rebuild registration paths) behind `clientIsEntitledForEmbeddedRegistrationOperations`, which does `xpc_connection_copy_entitlement_value` on the XPC peer for any of `com.apple.private.coreservices.lsaw` / `com.apple.private.installcoordinationd.daemon` / `com.apple.private.coreservices.can-register-install-results`. A client without one gets `NSOSStatusErrorDomain -54` (permErr, `LSDModifyService.mm:1639`), so `registerApplicationDictionary:` / `registerContainerizedApplicationWithInfoDictionaries:` fail and no app can (re)register — blocking vphoned's installer, TrollStore, and uicache/Sileo alike. The entitlement route is a dead end even for a launchd platform daemon (vphoned) whose validated csblob (`csops CS_OPS_ENTITLEMENTS_BLOB`) contains all three: LS registration is proxied, so the XPC peer lsd inspects is not the registering process. Fix: NOP the final `cbz w0, <not_entitled>` (the conditional branch whose fall-through sets the `mov w<reg>,#1` result) so the method always returns YES. Fully dynamic: method resolved via the DSC's own `.symbols` in-image local-symbol table (ipsw `symaddr -a`/`a2s` time out on this cache), gate located by control-flow shape in Capstone, NOP from Keystone `asm("nop")`, modified 16 KiB page re-attested (`cfw_dsc_codesign.py`; TXM enforces per-page). The resulting CDHash change is accepted by the JB always-true AMFI cdhash-trust patch. Install gate: **`27.*`** (hard-gated in `cfw_install.sh` as of 2026-07-20 — an 18.x/26.x base does not apply it). The patcher additionally self-gates (`patch-lsd-embedded-reg`): no-op on pre-iOS-27 userlands where the method is absent. **Pairs with vphoned's `vp_register_path` containerized-registration fallback** (`registerContainerizedApplicationWithInfoDictionaries:...:registrationError:`, treating a nil `registrationError` as success since it returns NO even when it registers). Also paired with **`/cores/vpregister`** (built + deployed by `cfw_install_jb.sh` / `cfw_install_exp.sh`, invoked by `vphone_jb_setup.sh` at first boot — 27-gated by DEPLOYMENT: `cfw_install_jb.sh`/`cfw_install_exp.sh` copy `/cores/vpregister` only when the mounted rootfs `SystemVersion.plist` is `27.*`, and the setup script's `[ -x /cores/vpregister ]` presence check is the runtime gate. Do NOT gate the invocation on a guest `sw_vers` check — the hybrid guest does not reliably report the 27 userland version at first boot, which silently skipped registration): it registers JB app bundles (Sileo) via the same containerized API, because `uicache -a`'s `registerApplicationDictionary:` is a deprecated no-op on iOS 27 (lsd logs *"you cannot use ... to register applications anymore. These interfaces have been deprecated for years."*). **VALIDATED (2026-07-17, `17,3_27.0_24A5380h` + cloudOS 26.4, JB): -54 gone; Sileo registers (`uicache -l` 0→1) via `vpregister`; vphoned installs+registers a test IPA (`com.vphone.vptest`) to `/var/containers/Bundle/Application/` end-to-end. Clean boot (re-attest correct; no CoreServices page rejection).** See `scripts/patchers/cfw_patch_lsd_embedded_reg.py` and `scripts/vphoned/vpregister.m`. |    Y    |  Y  |  Y  |
| 13  | `mov x0,#1; ret` on `-[DIDiskArb isMountCompleteWithExpectedCount:diskTracker:]` — **iOS 27.0** | `diskimagesiod` | **iOS-27 DDI (`/System/Developer`) auto-mount — mount-gate.** After the personalized DDI attaches (kernel side: JB-28 + JB-09), MobileStorageMounter waits on diskimagesiod's `-[DIDiskArb waitForDAMountWithExpectedCount:diskTracker:]` before it does the real (nobrowse) mount at `/System/Developer`. That wait loops until `isMountComplete` (= `callbackReached \|\| (appearedDiskCount>=expectedCount && mountedDiskCount>=mountableDiskCount)`) is YES; on the 26.4-kernel / 27-userland hybrid it never becomes true (not all of the DMG's IOMedia "appear" to diskimagesiod's DiskArbitration session, and diskarbitrationd never auto-mounts the volume), so the wait hangs and pmd3 times out. diskimagesiod itself does NOT mount the DDI (its `-[DIDiskArb mountWithDeviceName:...]` is dead code) — it only gates MobileStorageMounter. Forcing `isMountComplete` → YES lets the wait return so MobileStorageMounter proceeds. IMP resolved via LC_SYMTAB or ObjC metadata (selector → `__objc_selrefs` → `__TEXT,__objc_methlist` relative method list → IMP); prologue overwritten `mov x0,#1 ; ret` (safe — the method returns to the caller's unsigned LR without pushing a frame). **Gated to 27.\*** in `cfw_install.sh` (same `$IOS_VERSION` as the DSC patches): on a version-matched userland the native wait completes correctly and forcing it early could race the real mount, so it is NOT applied there. Embedded sandbox profile + private DA/apfs entitlements preserved on re-sign (`ldid_sign_ent`). **Validated on `c0ecdb4b` 26.4 + 27.0 userland: `pmd3 mounter auto-mount` → rc=0, DDI at `/System/Developer`, idempotent across fresh boots.** See `scripts/patchers/cfw_patch_diskimagesiod.py`. |    Y    |  Y  |  Y  |

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
| IOMobileFramebuffer SwapEnd payload-size patch (install-gated `26.0*`/`18.*` -> 0x560 / 26.1 base; **27.0 does NOT use this — it uses force-kern, next section**) | Y              | Y                          | Y (inherited from base run)                   | Y (inherited from base run)                           |
| dyld cache `maxSlide` zero (`patch-dsc-maxslide`; **install-gated `27.*`** as of 2026-07-20 — iOS 27's cache overflows the 6 GiB region; 18.x/26.x skip it) | Y | Y                     | Y (inherited from base run)                   | Y (inherited from base run)                           |
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
  - 26.0 and 26.0.1 GUI bring-up now patches installed DSC `IOMobileFramebuffer` only when `ProductVersion` starts with `26.0`: `_kern_SwapEnd` passes a 0x560-byte state to the 26.1 PCC userclient instead of the 26.0/26.0.1 0x548-byte state. JB host installs were validated on `17,3_26.0_23A341`, `17,3_26.0.1_23A355`, and unchanged `17,3_26.1_23B85`.
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
