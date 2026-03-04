# Patch Comparison: Regular / Development / Jailbreak

Three firmware variants are available, each building on the previous:

- **Regular** (`make fw_patch` + `make cfw_install`) — Minimal patches for VM boot with signature bypass and SSV override.
- **Development** (`make fw_patch_dev` + `make cfw_install_dev`) — Regular + TXM entitlement/developer-mode bypasses + launchd jetsam fix. Enables debugging and code signing flexibility without full jailbreak.
- **Jailbreak** (`make fw_patch_jb` + `make cfw_install_jb`) — Regular + comprehensive security bypass across iBSS, TXM, kernel, and userland. Full code execution, sandbox escape, and package management.

## Boot Chain Patches

### AVPBooter

| #   | Patch        | Purpose                          | Regular | Dev | JB  |
| --- | ------------ | -------------------------------- | :-----: | :-: | :-: |
| 1   | `mov x0, #0` | DGST signature validation bypass |    Y    |  Y  |  Y  |

### iBSS

| #   | Patch                             | Purpose                                                     | Regular | Dev | JB  |
| --- | --------------------------------- | ----------------------------------------------------------- | :-----: | :-: | :-: |
| 1   | Serial labels (2x)                | "Loaded iBSS" in serial log                                 |    Y    |  Y  |  Y  |
| 2   | image4_validate_property_callback | Signature bypass (`b.ne` → NOP, `mov x0,x22` → `mov x0,#0`) |    Y    |  Y  |  Y  |
| 3   | Skip generate_nonce               | Keep apnonce stable for SHSH (`tbz` → unconditional `b`)    |    —    |  —  |  Y  |

### iBEC

| #   | Patch                             | Purpose                                   | Regular | Dev | JB  |
| --- | --------------------------------- | ----------------------------------------- | :-----: | :-: | :-: |
| 1   | Serial labels (2x)                | "Loaded iBEC" in serial log               |    Y    |  Y  |  Y  |
| 2   | image4_validate_property_callback | Signature bypass                          |    Y    |  Y  |  Y  |
| 3   | Boot-args redirect                | ADRP+ADD → `serial=3 -v debug=0x2014e %s` |    Y    |  Y  |  Y  |

### LLB

| #   | Patch                             | Purpose                                   | Regular | Dev | JB  |
| --- | --------------------------------- | ----------------------------------------- | :-----: | :-: | :-: |
| 1   | Serial labels (2x)                | "Loaded LLB" in serial log                |    Y    |  Y  |  Y  |
| 2   | image4_validate_property_callback | Signature bypass                          |    Y    |  Y  |  Y  |
| 3   | Boot-args redirect                | ADRP+ADD → `serial=3 -v debug=0x2014e %s` |    Y    |  Y  |  Y  |
| 4   | Rootfs bypass (5 patches)         | Allow edited rootfs loading               |    Y    |  Y  |  Y  |
| 5   | Panic bypass                      | NOP `cbnz` after `mov w8,#0x328` check    |    Y    |  Y  |  Y  |

### TXM

The three variants use different TXM patchers. Regular uses `txm.py` (1 patch), Dev uses `txm_dev.py` (10 patches), JB uses `txm_jb.py` (12 patches).

| #   | Patch                                             | Purpose                                                     | Regular | Dev | JB  |
| --- | ------------------------------------------------- | ----------------------------------------------------------- | :-----: | :-: | :-: |
| 1   | Trustcache binary-search bypass                   | `bl hash_cmp` → `mov x0, #0`                                |    Y    |  Y  |  Y  |
| 2   | Selector24 hash extraction: NOP LDR X1            | Bypass CS hash flag extraction                              |    —    |  —  |  Y  |
| 3   | Selector24 hash extraction: NOP BL                | Bypass CS hash flag check                                   |    —    |  —  |  Y  |
| 4   | get-task-allow (selector 41\|29)                  | `bl` → `mov x0, #1` — allow get-task-allow                  |    —    |  Y  |  Y  |
| 5   | Selector42\|29 shellcode: branch to cave          | Redirect dispatch stub to shellcode                         |    —    |  Y  |  Y  |
| 6   | Selector42\|29 shellcode: NOP pad                 | UDF → NOP in code cave                                      |    —    |  Y  |  Y  |
| 7   | Selector42\|29 shellcode: `mov x0, #1`            | Set return value to true                                    |    —    |  Y  |  Y  |
| 8   | Selector42\|29 shellcode: `strb w0, [x20, #0x30]` | Set manifest flag                                           |    —    |  Y  |  Y  |
| 9   | Selector42\|29 shellcode: `mov x0, x20`           | Restore context pointer                                     |    —    |  Y  |  Y  |
| 10  | Selector42\|29 shellcode: branch back             | Return from shellcode to stub+4                             |    —    |  Y  |  Y  |
| 11  | Debugger entitlement (selector 42\|37)            | `bl` → `mov w0, #1` — allow `com.apple.private.cs.debugger` |    —    |  Y  |  Y  |
| 12  | Developer mode bypass                             | NOP conditional guard before deny path                      |    —    |  Y  |  Y  |

### Kernelcache

Regular and Dev share the same 25 base kernel patches. JB adds 34 additional patches.

#### Base patches (all variants)

| #     | Patch                      | Function                         | Purpose                                  | Regular | Dev | JB  |
| ----- | -------------------------- | -------------------------------- | ---------------------------------------- | :-----: | :-: | :-: |
| 1     | NOP `tbnz w8,#5`           | `_apfs_vfsop_mount`              | Skip "root snapshot" sealed volume check |    Y    |  Y  |  Y  |
| 2     | NOP conditional            | `_authapfs_seal_is_broken`       | Skip "root volume seal" panic            |    Y    |  Y  |  Y  |
| 3     | NOP conditional            | `_bsd_init`                      | Skip "rootvp not authenticated" panic    |    Y    |  Y  |  Y  |
| 4–5   | `mov w0,#0; ret`           | `_proc_check_launch_constraints` | Bypass launch constraints                |    Y    |  Y  |  Y  |
| 6–7   | `mov x0,#1` (2x)           | `PE_i_can_has_debugger`          | Enable kernel debugger                   |    Y    |  Y  |  Y  |
| 8     | NOP                        | `_postValidation`                | Skip AMFI post-validation                |    Y    |  Y  |  Y  |
| 9     | `cmp w0,w0`                | `_postValidation`                | Force comparison true                    |    Y    |  Y  |  Y  |
| 10–11 | `mov w0,#1` (2x)           | `_check_dyld_policy_internal`    | Allow dyld loading                       |    Y    |  Y  |  Y  |
| 12    | `mov w0,#0`                | `_apfs_graft`                    | Allow APFS graft                         |    Y    |  Y  |  Y  |
| 13    | `cmp x0,x0`                | `_apfs_vfsop_mount`              | Skip mount check                         |    Y    |  Y  |  Y  |
| 14    | `mov w0,#0`                | `_apfs_mount_upgrade_checks`     | Allow mount upgrade                      |    Y    |  Y  |  Y  |
| 15    | `mov w0,#0`                | `_handle_fsioc_graft`            | Allow fsioc graft                        |    Y    |  Y  |  Y  |
| 16–25 | `mov x0,#0; ret` (5 hooks) | Sandbox MACF ops table           | Stub 5 sandbox hooks                     |    Y    |  Y  |  Y  |

#### JB-only kernel patches

| #   | Patch                        | Function                             | Purpose                                    | Regular | Dev | JB  |
| --- | ---------------------------- | ------------------------------------ | ------------------------------------------ | :-----: | :-: | :-: |
| 26  | Function rewrite             | `AMFIIsCDHashInTrustCache`           | Always return true + store hash            |    —    |  —  |  Y  |
| 27  | Shellcode + branch           | `_cred_label_update_execve`          | Set cs_flags (platform+entitlements)       |    —    |  —  |  Y  |
| 28  | `cmp w0,w0`                  | `_postValidation` (additional)       | Force validation pass                      |    —    |  —  |  Y  |
| 29  | Shellcode + branch           | `_syscallmask_apply_to_proc`         | Patch zalloc_ro_mut for syscall mask       |    —    |  —  |  Y  |
| 30  | Shellcode + ops redirect     | `_hook_cred_label_update_execve`     | vnode_getattr ownership + suid propagation |    —    |  —  |  Y  |
| 31  | `mov x0,#0; ret` (20+ hooks) | Sandbox MACF ops (extended)          | Stub remaining 20+ sandbox hooks           |    —    |  —  |  Y  |
| 32  | `cmp xzr,xzr`                | `_task_conversion_eval_internal`     | Allow task conversion                      |    —    |  —  |  Y  |
| 33  | `mov x0,#0; ret`             | `_proc_security_policy`              | Bypass security policy                     |    —    |  —  |  Y  |
| 34  | NOP (2x)                     | `_proc_pidinfo`                      | Allow pid 0 info                           |    —    |  —  |  Y  |
| 35  | `b` (skip panic)             | `_convert_port_to_map_with_flavor`   | Skip kernel map panic                      |    —    |  —  |  Y  |
| 36  | NOP                          | `_vm_fault_enter_prepare`            | Skip fault check                           |    —    |  —  |  Y  |
| 37  | `b` (skip check)             | `_vm_map_protect`                    | Allow VM protect                           |    —    |  —  |  Y  |
| 38  | NOP + `mov x8,xzr`           | `___mac_mount`                       | Bypass MAC mount check                     |    —    |  —  |  Y  |
| 39  | NOP                          | `_dounmount`                         | Allow unmount                              |    —    |  —  |  Y  |
| 40  | `mov x0,#0`                  | `_bsd_init` (2nd)                    | Skip auth at @%s:%d                        |    —    |  —  |  Y  |
| 41  | NOP (2x)                     | `_spawn_validate_persona`            | Skip persona validation                    |    —    |  —  |  Y  |
| 42  | NOP                          | `_task_for_pid`                      | Allow task_for_pid                         |    —    |  —  |  Y  |
| 43  | `b` (skip check)             | `_load_dylinker`                     | Allow dylinker loading                     |    —    |  —  |  Y  |
| 44  | `cmp x0,x0`                  | `_shared_region_map_and_slide_setup` | Force shared region                        |    —    |  —  |  Y  |
| 45  | NOP BL                       | `_verifyPermission` (NVRAM)          | Allow NVRAM writes                         |    —    |  —  |  Y  |
| 46  | `b` (skip check)             | `_IOSecureBSDRoot`                   | Skip secure root check                     |    —    |  —  |  Y  |
| 47  | Syscall 439 + shellcode      | kcall10 (`SYS_kas_info` replacement) | Kernel arbitrary call from userspace       |    —    |  —  |  Y  |
| 48  | Zero out                     | `_thid_should_crash`                 | Prevent GUARD_TYPE_MACH_PORT crash         |    —    |  —  |  Y  |

## CFW Installation Patches

### Binary patches applied over SSH ramdisk

| #   | Patch                   | Binary               | Purpose                                   | Regular | Dev | JB  |
| --- | ----------------------- | -------------------- | ----------------------------------------- | :-----: | :-: | :-: |
| 1   | `/%s.gl` → `/AA.gl`     | seputil              | Gigalocker UUID fix                       |    Y    |  Y  |  Y  |
| 2   | NOP cache validation    | launchd_cache_loader | Allow modified launchd.plist              |    Y    |  Y  |  Y  |
| 3   | `mov x0,#1; ret`        | mobileactivationd    | Activation bypass                         |    Y    |  Y  |  Y  |
| 4   | Plist injection         | launchd.plist        | bash/dropbear/trollvnc/vphoned daemons    |    Y    |  Y  |  Y  |
| 5   | `b` (skip jetsam guard) | launchd              | Prevent jetsam panic on boot              |    —    |  Y  |  Y  |
| 6   | LC_LOAD_DYLIB injection | launchd              | Load `/cores/launchdhook.dylib` at launch |    —    |  —  |  Y  |

### Installed components

| #   | Component                | Description                                                       | Regular | Dev | JB  |
| --- | ------------------------ | ----------------------------------------------------------------- | :-----: | :-: | :-: |
| 1   | Cryptex SystemOS + AppOS | Decrypt AEA + mount + copy to device                              |    Y    |  Y  |  Y  |
| 2   | GPU driver               | AppleParavirtGPUMetalIOGPUFamily bundle                           |    Y    |  Y  |  Y  |
| 3   | iosbinpack64             | Jailbreak tools (base set)                                        |    Y    |  Y  |  Y  |
| 4   | iosbinpack64 dev overlay | Replace `rpcserver_ios` with dev build                            |    —    |  Y  |  —  |
| 5   | vphoned                  | vsock HID/control daemon (built + signed)                         |    Y    |  Y  |  Y  |
| 6   | LaunchDaemons            | bash, dropbear, trollvnc, rpcserver_ios, vphoned plists           |    Y    |  Y  |  Y  |
| 7   | Procursus bootstrap      | Bootstrap filesystem + optional Sileo deb                         |    —    |  —  |  Y  |
| 8   | BaseBin hooks            | systemhook.dylib, launchdhook.dylib, libellekit.dylib → `/cores/` |    —    |  —  |  Y  |

## Summary

| Component                | Regular |  Dev   |   JB   |
| ------------------------ | :-----: | :----: | :----: |
| AVPBooter                |    1    |   1    |   1    |
| iBSS                     |    2    |   2    |   3    |
| iBEC                     |    3    |   3    |   3    |
| LLB                      |    6    |   6    |   6    |
| TXM                      |    1    |   10   |   12   |
| Kernel                   |   25    |   25   |   59   |
| **Boot chain total**     | **38**  | **47** | **84** |
|                          |         |        |        |
| CFW binary patches       |    4    |   5    |   6    |
| CFW installed components |    6    |   7    |   8    |
| **CFW total**            | **10**  | **12** | **14** |
|                          |         |        |        |
| **Grand total**          | **48**  | **59** | **98** |

### What each variant adds

**Regular → Dev** (+11 patches):

- TXM: +9 patches (get-task-allow, selector42|29 shellcode, debugger entitlement, developer mode bypass)
- CFW: +1 binary patch (launchd jetsam), +1 component (dev rpcserver_ios overlay)

**Regular → JB** (+50 patches):

- iBSS: +1 (nonce skip)
- TXM: +11 (hash extraction NOP, get-task-allow, selector42|29 shellcode, debugger entitlement, dev mode bypass)
- Kernel: +34 (trustcache, execve, sandbox, task/VM, memory, kcall10)
- CFW: +2 binary patches (launchd jetsam + dylib injection), +2 components (procursus + BaseBin hooks)

## JB Install Flow (`make cfw_install_jb`)

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

## Dynamic Implementation Log (JB Patchers)

### TXM (`txm_jb.py`)

All TXM JB patches are implemented with dynamic binary analysis and
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

### Kernelcache (`kernel_jb.py`)

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

## Cross-Version Dynamic Snapshot

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

All patches are applied dynamically via string anchors, instruction patterns, and cross-reference analysis — no hardcoded offsets — ensuring portability across iOS versions.
