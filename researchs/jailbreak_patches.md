# Jailbreak Patches vs Base Patches

Comparison of base boot-chain patches (`make fw_patch`) vs jailbreak-extended patches (`make fw_patch_jb`).

Base patches enable VM boot with signature bypass and SSV override.
Jailbreak patches add code signing bypass, entitlement spoofing, task/VM security bypass,
sandbox hook neutralization, and kernel arbitrary call (kcall10).

## iBSS

| #   | Patch                             | Purpose                                 | Base | JB  |
| --- | --------------------------------- | --------------------------------------- | :--: | :-: |
| 1   | Serial labels (2x)                | "Loaded iBSS" in serial log             |  Y   |  Y  |
| 2   | image4_validate_property_callback | Signature bypass (nop b.ne + mov x0,#0) |  Y   |  Y  |
| 3   | Skip generate_nonce               | Keep apnonce stable for SHSH            |  --  |  Y  |

## iBEC

| #   | Patch                             | Purpose                        | Base | JB  |
| --- | --------------------------------- | ------------------------------ | :--: | :-: |
| 1   | Serial labels (2x)                | "Loaded iBEC" in serial log    |  Y   |  Y  |
| 2   | image4_validate_property_callback | Signature bypass               |  Y   |  Y  |
| 3   | Boot-args redirect                | `serial=3 -v debug=0x2014e %s` |  Y   |  Y  |

No additional JB patches for iBEC.

## LLB

| #   | Patch                             | Purpose                            | Base | JB  |
| --- | --------------------------------- | ---------------------------------- | :--: | :-: |
| 1   | Serial labels (2x)                | "Loaded LLB" in serial log         |  Y   |  Y  |
| 2   | image4_validate_property_callback | Signature bypass                   |  Y   |  Y  |
| 3   | Boot-args redirect                | `serial=3 -v debug=0x2014e %s`     |  Y   |  Y  |
| 4   | Rootfs bypass (5 patches)         | Allow edited rootfs loading        |  Y   |  Y  |
| 5   | Panic bypass                      | NOP cbnz after mov w8,#0x328 check |  Y   |  Y  |

No additional JB patches for LLB.

## TXM

| #   | Patch                                          | Purpose                                      | Base | JB  |
| --- | ---------------------------------------------- | -------------------------------------------- | :--: | :-: |
| 1   | Trustcache binary search bypass                | `bl hash_cmp` -> `mov x0,#0`                 |  Y   |  Y  |
| 2   | CodeSignature selector 24 / 0xA1 (2x nop)      | NOP hash flags extract LDR+BL                |  --  |  Y  |
| 3   | get-task-allow (selector 41/29)                | `mov x0,#1` -- allow get-task-allow          |  --  |  Y  |
| 4   | Selector 42/29 + shellcode                     | Branch to shellcode that sets flag + returns |  --  |  Y  |
| 5   | com.apple.private.cs.debugger (selector 42/37) | `mov w0,#1` -- allow debugger entitlement    |  --  |  Y  |
| 6   | Developer mode bypass                          | NOP developer mode enforcement               |  --  |  Y  |

## Kernelcache

### Base patches (SSV + basic AMFI + sandbox)

| #     | Patch                    | Function                         | Purpose                               | Base | JB  |
| ----- | ------------------------ | -------------------------------- | ------------------------------------- | :--: | :-: |
| 1     | NOP panic                | `_apfs_vfsop_mount`              | Skip "root snapshot" panic            |  Y   |  Y  |
| 2     | NOP panic                | `_authapfs_seal_is_broken`       | Skip "root volume seal" panic         |  Y   |  Y  |
| 3     | NOP panic                | `_bsd_init`                      | Skip "rootvp not authenticated" panic |  Y   |  Y  |
| 4-5   | mov w0,#0; ret           | `_proc_check_launch_constraints` | Bypass launch constraints             |  Y   |  Y  |
| 6-7   | mov x0,#1 (2x)           | `PE_i_can_has_debugger`          | Enable kernel debugger                |  Y   |  Y  |
| 8     | NOP                      | `_postValidation`                | Skip AMFI post-validation             |  Y   |  Y  |
| 9     | cmp w0,w0                | `_postValidation`                | Force comparison true                 |  Y   |  Y  |
| 10-11 | mov w0,#1 (2x)           | `_check_dyld_policy_internal`    | Allow dyld loading                    |  Y   |  Y  |
| 12    | mov w0,#0                | `_apfs_graft`                    | Allow APFS graft                      |  Y   |  Y  |
| 13    | cmp x0,x0                | `_apfs_vfsop_mount`              | Skip mount check                      |  Y   |  Y  |
| 14    | mov w0,#0                | `_apfs_mount_upgrade_checks`     | Allow mount upgrade                   |  Y   |  Y  |
| 15    | mov w0,#0                | `_handle_fsioc_graft`            | Allow fsioc graft                     |  Y   |  Y  |
| 16-25 | mov x0,#0; ret (5 hooks) | Sandbox MACF ops table           | Stub 5 sandbox hooks                  |  Y   |  Y  |

### Jailbreak-only kernel patches

| #   | Patch                     | Function                             | Purpose                                    | Base | JB  |
| --- | ------------------------- | ------------------------------------ | ------------------------------------------ | :--: | :-: |
| 26  | Rewrite function          | `AMFIIsCDHashInTrustCache`           | Always return true + store hash            |  --  |  Y  |
| 27  | mov x0,#0 (2 BL sites)    | AMFI execve kill path                | Bypass AMFI execve kill helpers            |  --  |  Y  |
| 28  | Shellcode + branch        | `_cred_label_update_execve`          | Set cs_flags (platform+entitlements)       |  --  |  Y  |
| 29  | cmp w0,w0                 | `_postValidation` (additional)       | Force validation pass                      |  --  |  Y  |
| 30  | Shellcode + branch        | `_syscallmask_apply_to_proc`         | Patch zalloc_ro_mut for syscall mask       |  --  |  Y  |
| 31  | Shellcode + ops redirect  | `_hook_cred_label_update_execve`     | vnode_getattr ownership propagation + suid |  --  |  Y  |
| 32  | mov x0,#0; ret (25 hooks) | Sandbox MACF ops table (extended)    | Stub remaining 25 sandbox hooks            |  --  |  Y  |
| 33  | cmp xzr,xzr               | `_task_conversion_eval_internal`     | Allow task conversion                      |  --  |  Y  |
| 34  | mov x0,#0; ret            | `_proc_security_policy`              | Bypass security policy                     |  --  |  Y  |
| 35  | NOP (2x)                  | `_proc_pidinfo`                      | Allow pid 0 info                           |  --  |  Y  |
| 36  | b (skip panic)            | `_convert_port_to_map_with_flavor`   | Skip kernel map panic                      |  --  |  Y  |
| 37  | NOP                       | `_vm_fault_enter_prepare`            | Skip fault check                           |  --  |  Y  |
| 38  | b (skip check)            | `_vm_map_protect`                    | Allow VM protect                           |  --  |  Y  |
| 39  | NOP + mov x8,xzr          | `___mac_mount`                       | Bypass MAC mount check                     |  --  |  Y  |
| 40  | NOP                       | `_dounmount`                         | Allow unmount                              |  --  |  Y  |
| 41  | mov x0,#0                 | `_bsd_init` (2nd)                    | Skip auth at @%s:%d                        |  --  |  Y  |
| 42  | NOP (2x)                  | `_spawn_validate_persona`            | Skip persona validation                    |  --  |  Y  |
| 43  | NOP                       | `_task_for_pid`                      | Allow task_for_pid                         |  --  |  Y  |
| 44  | b (skip check)            | `_load_dylinker`                     | Allow dylinker loading                     |  --  |  Y  |
| 45  | cmp x0,x0                 | `_shared_region_map_and_slide_setup` | Force shared region                        |  --  |  Y  |
| 46  | NOP                       | `_verifyPermission` (NVRAM)          | Allow NVRAM writes                         |  --  |  Y  |
| 47  | b (skip check)            | `_IOSecureBSDRoot`                   | Skip secure root check                     |  --  |  Y  |
| 48  | Syscall 439 + shellcode   | kcall10 (SYS_kas_info replacement)   | Kernel arbitrary call from userspace       |  --  |  Y  |
| 49  | Zero out                  | `_thid_should_crash`                 | Prevent GUARD_TYPE_MACH_PORT crash         |  --  |  Y  |

## CFW (cfw_install)

| #   | Patch                       | Binary                   | Purpose                                              | Base | JB  |
| --- | --------------------------- | ------------------------ | ---------------------------------------------------- | :--: | :-: |
| 1   | /%s.gl -> /AA.gl            | seputil                  | Gigalocker UUID fix                                  |  Y   |  Y  |
| 2   | NOP cache validation        | launchd_cache_loader     | Allow modified launchd.plist                         |  Y   |  Y  |
| 3   | mov x0,#1; ret              | mobileactivationd        | Activation bypass                                    |  Y   |  Y  |
| 4   | Plist injection             | launchd.plist            | bash/dropbear/trollvnc daemons                       |  Y   |  Y  |
| 5   | b (skip jetsam) + LC inject | launchd                  | Prevent jetsam panic + load launchdhook.dylib        |  --  |  Y  |
| 6   | procursus bootstrap         | `/mnt5/<hash>/jb-vphone` | Install procursus userspace + optional Sileo payload |  --  |  Y  |
| 7   | BaseBin hooks               | `/mnt1/cores/*.dylib`    | Deploy systemhook/launchdhook/libellekit dylibs      |  --  |  Y  |

### JB Install Flow (`make cfw_install_jb`)

- Entry: `scripts/cfw_install_jb.sh` runs `scripts/cfw_install.sh` with `CFW_SKIP_HALT=1`, then continues with JB phases.
- Added JB phases in install pipeline:
  - `JB-1`: patch `/mnt1/sbin/launchd` via `inject-dylib` (adds `/cores/launchdhook.dylib` LC_LOAD_DYLIB) + `patch-launchd-jetsam` (dynamic string+xref).
  - `JB-2`: unpack procursus bootstrap (`bootstrap-iphoneos-arm64.tar.zst`) into `/mnt5/<bootManifestHash>/jb-vphone/procursus`.
  - `JB-3`: deploy BaseBin hook dylibs (`systemhook.dylib`, `launchdhook.dylib`, `libellekit.dylib`) to `/mnt1/cores/`, re-signed with ldid + signcert.p12.
- JB resources now packaged in:
  - `scripts/resources/cfw_jb_input.tar.zst`
  - contains:
    - `jb/bootstrap-iphoneos-arm64.tar.zst`
    - `jb/org.coolstar.sileo_2.5.1_iphoneos-arm64.deb`
    - `basebin/*.dylib` (BaseBin hooks for JB-3)

## Summary

| Binary      |  Base  | JB-only | Total  |
| ----------- | :----: | :-----: | :----: |
| iBSS        |   2    |    1    |   3    |
| iBEC        |   3    |    0    |   3    |
| LLB         |   6    |    0    |   6    |
| TXM         |   1    |    5    |   6    |
| Kernelcache |   25   |   24    |   49   |
| CFW         |   4    |    3    |   7    |
| **Total**   | **41** | **33**  | **74** |

> Note: Counts are logical patches (methods/operations), not individual instruction
> emit sites. For example, TXM JB has 5 patch methods that emit 11 individual
> instruction patches; the extended sandbox hook stub (#32) covers 25 hook entries
> but counts as one logical patch. Actual emit counts per binary depend on how many
> dynamic targets resolve (see cross-version snapshot below).

## Dynamic Implementation Log (fw_patch_jb)

### TXM (Completed)

All TXM JB patches are now implemented with dynamic binary analysis and
keystone/capstone-encoded instructions only.

1. `selector24 A1` (2x nop: LDR + BL)
   - Locator: unique guarded `mov w0,#0xa1` site, scan for `ldr x1,[xN,#0x38] ; add x2 ; bl ; ldp` pattern.
   - Patch bytes: keystone `nop` on the LDR and the BL.
2. `selector41/29 get-task-allow`
   - Locator: xref to `"get-task-allow"` + nearby `bl` followed by `tbnz w0,#0`.
   - Patch bytes: keystone `mov x0, #1`.
3. `selector42/29 shellcode trampoline`
   - Locator:
     - Find dispatch stub pattern `bti j ; mov x0,x20 ; bl ; mov x1,x21 ; mov x2,x22 ; bl ; b`.
     - Select stub whose second `bl` target is the debugger-gate function (pattern verified by string-xref + call-shape).
     - Find executable UDF cave dynamically.
   - Patch bytes:
     - Stub head -> keystone `b #cave`.
     - Cave payload -> `nop ; mov x0,#1 ; strb w0,[x20,#0x30] ; mov x0,x20 ; b #return`.
4. `selector42/37 debugger entitlement`
   - Locator: xref to `"com.apple.private.cs.debugger"` + strict nearby call-shape
     (`mov x0,#0 ; mov x2,#0 ; bl ; tbnz w0,#0`).
   - Patch bytes: keystone `mov w0, #1`.
5. `developer mode bypass`
   - Locator: xref to `"developer mode enabled due to system policy configuration"`
     - nearest guard branch on `w9`.
   - Patch bytes: keystone `nop`.

#### TXM Binary-Alignment Validation

- `patch.upstream.raw` generated from upstream-equivalent TXM static patch semantics.
- `patch.dyn.raw` generated by `TXMJBPatcher` on the same input.
- Result: byte-identical (`cmp -s` success, SHA-256 matched).

### Kernelcache (Completed)

All 24 kernel JB patch methods are implemented in `scripts/patchers/kernel_jb.py`
with capstone semantic matching and keystone-generated patch bytes only:

**Group A: Core patches**

1. `AMFIIsCDHashInTrustCache` function rewrite
   - Locator: semantic function-body matcher in AMFI text.
   - Patch: `mov x0,#1 ; cbz x2,+8 ; str x0,[x2] ; ret`.
2. AMFI execve kill path bypass (2 BL sites)
   - Locator: string xref to `"AMFI: hook..execve() killing"` (fallback `"execve() killing"`),
     then function-local early `bl` + `cbz/cbnz w0` pair matcher.
   - Patch: `bl -> mov x0,#0` at two helper callsites.
3. `task_conversion_eval_internal` guard bypass
   - Locator: unique cmp/branch motif:
     `ldr xN,[xN,#imm] ; cmp xN,x0 ; b.eq ; cmp xN,x1 ; b.eq`.
   - Patch: `cmp xN,x0 -> cmp xzr,xzr`.
4. Extended sandbox MACF hook stubs (25 hooks, JB-only set)
   - Locator: dynamic `mac_policy_conf -> mpc_ops` discovery, then hook-index resolution.
   - Patch per hook function: `mov x0,#0 ; ret`.
   - JB extended indices include vnode/proc hooks beyond base 5 hooks.

**Group B: Simple patches (string-anchored / pattern-matched)**

5. `_postValidation` additional CMP bypass
6. `_proc_security_policy` stub (mov x0,#0; ret)
7. `_proc_pidinfo` pid-0 guard NOP (2 sites)
8. `_convert_port_to_map_with_flavor` panic skip
9. `_vm_fault_enter_prepare` PMAP check NOP
10. `_vm_map_protect` permission check skip
11. `___mac_mount` MAC check bypass (NOP + mov x8,xzr)
12. `_dounmount` MAC check NOP
13. `_bsd_init` auth bypass (mov x0,#0)
14. `_spawn_validate_persona` NOP (2 sites)
15. `_task_for_pid` proc_ro security copy NOP
16. `_load_dylinker` PAC rebase bypass
17. `_shared_region_map_and_slide_setup` force (cmp x0,x0)
18. `_verifyPermission` (NVRAM) NOP
19. `_IOSecureBSDRoot` check skip
20. `_thid_should_crash` zero out

**Group C: Complex shellcode patches**

21. `_cred_label_update_execve` cs_flags shellcode
22. `_syscallmask_apply_to_proc` filter mask shellcode
23. `_hook_cred_label_update_execve` ops table + vnode_getattr shellcode
24. `kcall10` syscall 439 replacement shellcode

#### Cross-Version Dynamic Snapshot

Validated using pristine inputs from `updates-cdn/`:

| Case                | TXM_JB_PATCHES | KERNEL_JB_PATCHES |
| ------------------- | -------------: | ----------------: |
| PCC 26.1 (`23B85`)  |             14 |                59 |
| PCC 26.3 (`23D128`) |             14 |                59 |
| iOS 26.1 (`23B85`)  |             14 |                59 |
| iOS 26.3 (`23D127`) |             14 |                59 |

> Note: These emit counts were captured at validation time and may differ from
> the current source if methods were subsequently refactored. The TXM JB patcher
> currently has 5 methods emitting 11 patches; the kernel JB patcher has 24
> methods. Actual emit counts depend on how many dynamic targets resolve per binary.
