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
| 3   | Skip generate_nonce               | Keep apnonce stable for SHSH            |  —   |  Y  |

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

| #   | Patch                                      | Purpose                           |                     Base                     | JB  |
| --- | ------------------------------------------ | --------------------------------- | :------------------------------------------: | :-: | --- |
| 1   | Trustcache binary search bypass            | `bl hash_cmp → mov x0,#0`         |                      Y                       |  Y  |
| 2   | CodeSignature selector 24 (3x mov x0,#0)   | Bypass CS validation return paths |                      —                       |  Y  |
| 3   | CodeSignature selector 24                  | 0xA1 (2x nop)                     |             Bypass CS error path             |  —  | Y   |
| 4   | get-task-allow (selector 41                | 29)                               |      `mov x0,#1` — allow get-task-allow      |  —  | Y   |
| 5   | Selector 42                                | 29 + shellcode                    | Branch to shellcode that sets flag + returns |  —  | Y   |
| 6   | com.apple.private.cs.debugger (selector 42 | 37)                               |   `mov w0,#1` — allow debugger entitlement   |  —  | Y   |
| 7   | Developer mode bypass                      | NOP developer mode enforcement    |                      —                       |  Y  |

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

| #   | Patch                      | Function                             | Purpose                                    | Base | JB  |
| --- | -------------------------- | ------------------------------------ | ------------------------------------------ | :--: | :-: |
| 26  | Rewrite function           | `AMFIIsCDHashInTrustCache`           | Always return true + store hash            |  —   |  Y  |
| 27  | Shellcode + branch         | `_cred_label_update_execve`          | Set cs_flags (platform+entitlements)       |  —   |  Y  |
| 28  | cmp w0,w0                  | `_postValidation` (additional)       | Force validation pass                      |  —   |  Y  |
| 29  | Shellcode + branch         | `_syscallmask_apply_to_proc`         | Patch zalloc_ro_mut for syscall mask       |  —   |  Y  |
| 30  | Shellcode + ops redirect   | `_hook_cred_label_update_execve`     | vnode_getattr ownership propagation + suid |  —   |  Y  |
| 31  | mov x0,#0; ret (20+ hooks) | Sandbox MACF ops table (extended)    | Stub remaining 20+ sandbox hooks           |  —   |  Y  |
| 32  | cmp xzr,xzr                | `_task_conversion_eval_internal`     | Allow task conversion                      |  —   |  Y  |
| 33  | mov x0,#0; ret             | `_proc_security_policy`              | Bypass security policy                     |  —   |  Y  |
| 34  | NOP (2x)                   | `_proc_pidinfo`                      | Allow pid 0 info                           |  —   |  Y  |
| 35  | b (skip panic)             | `_convert_port_to_map_with_flavor`   | Skip kernel map panic                      |  —   |  Y  |
| 36  | NOP                        | `_vm_fault_enter_prepare`            | Skip fault check                           |  —   |  Y  |
| 37  | b (skip check)             | `_vm_map_protect`                    | Allow VM protect                           |  —   |  Y  |
| 38  | NOP + mov x8,xzr           | `___mac_mount`                       | Bypass MAC mount check                     |  —   |  Y  |
| 39  | NOP                        | `_dounmount`                         | Allow unmount                              |  —   |  Y  |
| 40  | mov x0,#0                  | `_bsd_init` (2nd)                    | Skip auth at @%s:%d                        |  —   |  Y  |
| 41  | NOP (2x)                   | `_spawn_validate_persona`            | Skip persona validation                    |  —   |  Y  |
| 42  | NOP                        | `_task_for_pid`                      | Allow task_for_pid                         |  —   |  Y  |
| 43  | b (skip check)             | `_load_dylinker`                     | Allow dylinker loading                     |  —   |  Y  |
| 44  | cmp x0,x0                  | `_shared_region_map_and_slide_setup` | Force shared region                        |  —   |  Y  |
| 45  | NOP                        | `_verifyPermission` (NVRAM)          | Allow NVRAM writes                         |  —   |  Y  |
| 46  | b (skip check)             | `_IOSecureBSDRoot`                   | Skip secure root check                     |  —   |  Y  |
| 47  | Syscall 439 + shellcode    | kcall10 (SYS_kas_info replacement)   | Kernel arbitrary call from userspace       |  —   |  Y  |
| 48  | Zero out                   | `_thid_should_crash`                 | Prevent GUARD_TYPE_MACH_PORT crash         |  —   |  Y  |

## CFW (cfw_install)

| #   | Patch                | Binary               | Purpose                        | Base | JB  |
| --- | -------------------- | -------------------- | ------------------------------ | :--: | :-: |
| 1   | /%s.gl → /AA.gl      | seputil              | Gigalocker UUID fix            |  Y   |  Y  |
| 2   | NOP cache validation | launchd_cache_loader | Allow modified launchd.plist   |  Y   |  Y  |
| 3   | mov x0,#1; ret       | mobileactivationd    | Activation bypass              |  Y   |  Y  |
| 4   | Plist injection      | launchd.plist        | bash/dropbear/trollvnc daemons |  Y   |  Y  |
| 5   | b (skip jetsam)      | launchd              | Prevent jetsam panic on boot   |  —   |  Y  |
| 6   | procursus bootstrap  | `/mnt5/<hash>/jb-vphone` | Install procursus userspace + optional Sileo payload |  —   |  Y  |

### JB Install Flow (`make cfw_install_jb`)

- Entry: `scripts/cfw_install_jb.sh` (wrapper) -> `scripts/cfw_install.sh` with `CFW_JB_MODE=1`.
- Added JB phases in install pipeline:
  - `JB-1`: patch `/mnt1/sbin/launchd` via `patch-launchd-jetsam` (dynamic string+xref).
  - `JB-2`: unpack procursus bootstrap (`bootstrap-iphoneos-arm64.tar.zst`) into `/mnt5/<bootManifestHash>/jb-vphone/procursus`.
- JB resources now packaged in:
  - `scripts/resources/cfw_jb_input.tar.zst`
  - contains:
    - `jb/bootstrap-iphoneos-arm64.tar.zst`
    - `jb/org.coolstar.sileo_2.5.1_iphoneos-arm64.deb`

## Summary

| Binary      |  Base  | JB-only  |  Total   |
| ----------- | :----: | :------: | :------: |
| iBSS        |   2    |    1     |    3     |
| iBEC        |   3    |    0     |    3     |
| LLB         |   6    |    0     |    6     |
| TXM         |   1    |   ~13    |   ~14    |
| Kernelcache |   25   |   ~23+   |   ~48+   |
| CFW         |   4    |    1     |    5     |
| **Total**   | **41** | **~38+** | **~79+** |

## Dynamic Implementation Log (fw_patch_jb)

### TXM (Completed)

All TXM JB patches are now implemented with dynamic binary analysis and
keystone/capstone-encoded instructions only.

1. `selector24 hashcmp` (`bl -> mov x0,#0`, 2 residual sites in JB stage)
   - Locator: global instruction motif `mov w2,#0x14 ; bl ; cbz w0`.
   - Patch bytes: keystone `mov x0, #0`.
2. `selector24 A1` (`b.lo/cbz -> nop`)
   - Locator: unique guarded `mov w0,#0xa1` site with nearby `b.lo` and `cbz x9`.
   - Patch bytes: keystone `nop`.
3. `selector41|29 get-task-allow`
   - Locator: xref to `"get-task-allow"` + nearby `bl` followed by `tbnz w0,#0`.
   - Patch bytes: keystone `mov x0, #1`.
4. `selector42|29 shellcode trampoline`
   - Locator:
     - Find dispatch stub pattern `bti j ; mov x0,x20 ; bl ; mov x1,x21 ; mov x2,x22 ; bl ; b`.
     - Select stub whose second `bl` target is the debugger-gate function (pattern verified by string-xref + call-shape).
     - Find executable UDF cave dynamically.
   - Patch bytes:
     - Stub head -> keystone `b #cave`.
     - Cave payload -> `nop ; mov x0,#1 ; strb w0,[x20,#0x30] ; mov x0,x20 ; b #return`.
5. `selector42|37 debugger entitlement`
   - Locator: xref to `"com.apple.private.cs.debugger"` + strict nearby call-shape
     (`mov x0,#0 ; mov x2,#0 ; bl ; tbnz w0,#0`).
   - Patch bytes: keystone `mov w0, #1`.
6. `developer mode bypass`
   - Locator: xref to `"developer mode enabled due to system policy configuration"`
     + nearest guard branch on `w9`.
   - Patch bytes: keystone `nop`.

#### TXM Binary-Alignment Validation

- `patch.upstream.raw` generated from upstream-equivalent TXM static patch semantics.
- `patch.dyn.raw` generated by `TXMJBPatcher` on the same input.
- Result: byte-identical (`cmp -s` success, SHA-256 matched).

### Kernelcache (In Progress, Dynamic Ports Added)

Implemented in `scripts/patchers/kernel_jb.py` with capstone semantic matching
and keystone-generated patch bytes only:

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
4. Extended sandbox MACF hook stubs (JB-only set)
   - Locator: dynamic `mac_policy_conf -> mpc_ops` discovery, then hook-index resolution.
   - Patch per hook function: `mov x0,#0 ; ret`.
   - JB extended indices include vnode/proc hooks beyond base 5 hooks.

#### Cross-Version Dynamic Snapshot

Validated using pristine inputs from `updates-cdn/`:

| Case | TXM_JB_PATCHES | KERNEL_JB_PATCHES |
|------|----------------:|------------------:|
| PCC 26.1 (`23B85`) | 14 | 59 |
| PCC 26.3 (`23D128`) | 14 | 59 |
| iOS 26.1 (`23B85`) | 14 | 59 |
| iOS 26.3 (`23D127`) | 14 | 59 |
