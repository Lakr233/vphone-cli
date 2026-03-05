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

TXM patch composition by variant:

- Regular: `txm.py` (1 patch).
- Dev: `txm.py` (1 patch) + `txm_dev.py` (11 patches) = 12 total.
- JB: same as Dev (selector24 bypass now in `txm_dev.py`, no separate JB patcher).

| #   | Patch                                             | Purpose                                                     | Regular | Dev | JB  |
| --- | ------------------------------------------------- | ----------------------------------------------------------- | :-----: | :-: | :-: |
| 1   | Trustcache binary-search bypass                   | `bl hash_cmp` → `mov x0, #0`                                |    Y    |  Y  |  Y  |
| 2   | Selector24 bypass: `mov w0, #0xa1`                | Return PASS (byte 1 = 0) after prologue                     |    —    |  Y  |  Y  |
| 3   | Selector24 bypass: `b <epilogue>`                 | Skip validation, jump to register restore                   |    —    |  Y  |  Y  |
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

Regular and Dev share the same 28 base kernel patches. JB adds 34 additional patches.

#### Base patches (all variants)

| #     | Patch                      | Function                         | Purpose                                                                                   | Regular | Dev | JB  |
| ----- | -------------------------- | -------------------------------- | ----------------------------------------------------------------------------------------- | :-----: | :-: | :-: |
| 1     | NOP `tbnz w8,#5`           | `_apfs_vfsop_mount`              | Skip "root snapshot" sealed volume check                                                  |    Y    |  Y  |  Y  |
| 2     | NOP conditional            | `_authapfs_seal_is_broken`       | Skip "root volume seal" panic                                                             |    Y    |  Y  |  Y  |
| 3     | NOP conditional            | `_bsd_init`                      | Skip "rootvp not authenticated" panic                                                     |    Y    |  Y  |  Y  |
| 4–5   | `mov w0,#0; ret`           | `_proc_check_launch_constraints` | Bypass launch constraints                                                                 |    Y    |  Y  |  Y  |
| 6–7   | `mov x0,#1` (2x)           | `PE_i_can_has_debugger`          | Enable kernel debugger                                                                    |    Y    |  Y  |  Y  |
| 8     | NOP                        | `_postValidation`                | Skip AMFI post-validation                                                                 |    Y    |  Y  |  Y  |
| 9     | `cmp w0,w0`                | `_postValidation`                | Force comparison true                                                                     |    Y    |  Y  |  Y  |
| 10–11 | `mov w0,#1` (2x)           | `_check_dyld_policy_internal`    | Allow dyld loading                                                                        |    Y    |  Y  |  Y  |
| 12    | `mov w0,#0`                | `_apfs_graft`                    | Allow APFS graft                                                                          |    Y    |  Y  |  Y  |
| 13    | `cmp x0,x0`                | `_apfs_vfsop_mount`              | Skip mount check                                                                          |    Y    |  Y  |  Y  |
| 14    | `mov w0,#0`                | `_apfs_mount_upgrade_checks`     | Allow mount upgrade                                                                       |    Y    |  Y  |  Y  |
| 15    | `mov w0,#0`                | `_handle_fsioc_graft`            | Allow fsioc graft                                                                         |    Y    |  Y  |  Y  |
| 16    | `NOP` (3x)                 | `handle_get_dev_by_role`         | Bypass APFS role-lookup deny gates for boot mounts (context + entitlement + role==2 path) |    Y    |  Y  |  Y  |
| 17–26 | `mov x0,#0; ret` (5 hooks) | Sandbox MACF ops table           | Stub 5 sandbox hooks                                                                      |    Y    |  Y  |  Y  |

Base-patch verification note (2026-03-05):
- Non-JB validation report for #1-#5 (clean `fw_prepare` kernel, locator uniqueness + IDA path checks):
  [`research/kernel_patch_base_first5_validation_2026-03-05.md`](kernel_patch_base_first5_validation_2026-03-05.md)
- Non-JB validation report for #16-#20 (APFS get-dev-by-role deny gates + sandbox `file_check_mmap`/`mount_check_mount`):
  [`research/kernel_patch_base_16_20_validation_2026-03-05.md`](kernel_patch_base_16_20_validation_2026-03-05.md)
- Non-JB validation report for #11-#15 (dyld/apfs-graft/mount-upgrade/fsioc-graft target-site checks):
  [`research/kernel_patch_base_11_15_validation_2026-03-05.md`](kernel_patch_base_11_15_validation_2026-03-05.md)
- Non-JB validation report for #21-#26 (remaining sandbox hook index-to-entry verification):
  [`research/kernel_patch_sandbox_hooks_21_26_validation_2026-03-05.md`](kernel_patch_sandbox_hooks_21_26_validation_2026-03-05.md)

#### JB-only kernel patches

| #   | Patch                        | Function                             | Purpose                                    | Regular | Dev | JB  |
| --- | ---------------------------- | ------------------------------------ | ------------------------------------------ | :-----: | :-: | :-: |
| 26  | Function rewrite             | `AMFIIsCDHashInTrustCache`           | Always return true + store hash            |    —    |  —  |  Y  |
| 27  | Shellcode + branch           | `_cred_label_update_execve`          | Set cs_flags (platform+entitlements)       |    —    |  —  |  Y  |
| 28  | `cmp w0,w0`                  | `_postValidation` (additional)       | Force validation pass                      |    —    |  —  |  Y  |
| 29  | Shellcode + branch           | `_syscallmask_apply_to_proc`         | Patch zalloc_ro_mut for syscall mask (legacy-signature mismatch on current fw; temporarily skipped) |    —    |  —  | SKIP |
| 30  | Inline trampoline + cave     | `_hook_cred_label_update_execve`     | vnode_getattr ownership + suid propagation |    —    |  —  |  Y  |
| 31  | `mov x0,#0; ret` (20+ hooks) | Sandbox MACF ops (extended)          | Stub remaining 20+ sandbox hooks           |    —    |  —  |  Y  |
| 32  | `cmp xzr,xzr`                | `_task_conversion_eval_internal`     | Allow task conversion                      |    —    |  —  |  Y  |
| 33  | `mov x0,#0; ret`             | `_proc_security_policy`              | Bypass security policy                     |    —    |  —  |  Y  |
| 34  | NOP (2x)                     | `_proc_pidinfo`                      | Allow pid 0 info                           |    —    |  —  |  Y  |
| 35  | `b` (skip panic)             | `_convert_port_to_map_with_flavor`   | Skip kernel map panic                      |    —    |  —  |  Y  |
| 36  | NOP                          | `_vm_fault_enter_prepare`            | Skip fault check                           |    —    |  —  |  Y  |
| 37  | `b` (skip check)             | `_vm_map_protect`                    | Allow VM protect                           |    —    |  —  |  Y  |
| 38  | NOP deny-branch (+optional `mov x8,xzr`) | `___mac_mount`             | Bypass MAC mount deny path (strict site)   |    —    |  —  |  Y  |
| 39  | NOP (strict in-function match) | `_dounmount`                       | Allow unmount (unsafe broad fallback removed) |    —    |  —  |  Y  |
| 40  | `mov x0,#0`                  | `_bsd_init` (2nd)                    | Skip auth at @%s:%d                        |    —    |  —  |  Y  |
| 41  | NOP (2x)                     | `_spawn_validate_persona`            | Skip persona validation                    |    —    |  —  |  Y  |
| 42  | NOP                          | `_task_for_pid`                      | Allow task_for_pid                         |    —    |  —  |  Y  |
| 43  | `b` (skip check)             | `_load_dylinker`                     | Allow dylinker loading                     |    —    |  —  |  Y  |
| 44  | `cmp x0,x0`                  | `_shared_region_map_and_slide_setup` | Force shared region                        |    —    |  —  |  Y  |
| 45  | NOP BL                       | `_verifyPermission` (NVRAM)          | Allow NVRAM writes                         |    —    |  —  |  Y  |
| 46  | `b` (strict policy branch)   | `_IOSecureBSDRoot`                   | Skip secure root check (guard-site filter) |    —    |  —  |  Y  |
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

### CFW Installer Flow Matrix (Script-Level)

| Flow item | Regular (`cfw_install.sh`) | Dev (`cfw_install_dev.sh`) | JB (`cfw_install_jb.sh`) |
| --- | --- | --- | --- |
| Base CFW phases (1/7 → 7/7) | Runs directly | Runs directly | Runs via `CFW_SKIP_HALT=1 zsh cfw_install.sh` |
| Dev overlay (`rpcserver_ios` replacement in `iosbinpack64.tar`) | — | Y (`apply_dev_overlay`) | — |
| SSH readiness wait before install | Y (`wait_for_device_ssh_ready`) | — | Y (inherited from base run) |
| `remote_mount` behavior | Ensures mountpoint and verifies mount success (hard fail) | Best-effort mount only (`mount_apfs ... || true`) | Ensures mountpoint and verifies mount success (hard fail) |
| launchd jetsam patch (`patch-launchd-jetsam`) | — | Y (base-flow injection) | Y (JB-1) |
| launchd dylib injection (`inject-dylib /cores/launchdhook.dylib`) | — | — | Y (JB-1) |
| Procursus bootstrap deployment (`/mnt5/<bootHash>/jb-vphone/procursus`) | — | — | Y (JB-2) |
| BaseBin hook deployment (`*.dylib` → `/mnt1/cores`) | — | — | Y (JB-3) |
| Additional input resources | `cfw_input` | `cfw_input` + `resources/cfw_dev/rpcserver_ios` | `cfw_input` + `cfw_jb_input` |
| Extra tool requirement beyond base | — | — | `zstd` |
| Halt behavior | Halts unless `CFW_SKIP_HALT=1` | Halts unless `CFW_SKIP_HALT=1` | Always halts after JB phases |

## Summary

| Component                | Regular |  Dev   |   JB    |
| ------------------------ | :-----: | :----: | :-----: |
| AVPBooter                |    1    |   1    |    1    |
| iBSS                     |    2    |   2    |    3    |
| iBEC                     |    3    |   3    |    3    |
| LLB                      |    6    |   6    |    6    |
| TXM                      |    1    |   12   |   12    |
| Kernel                   |   28    |   28   |   62    |
| **Boot chain total**     | **41**  | **52** | **87**  |
|                          |         |        |         |
| CFW binary patches       |    4    |   5    |    6    |
| CFW installed components |    6    |   7    |    8    |
| **CFW total**            | **10**  | **12** | **14**  |
|                          |         |        |         |
| **Grand total**          | **51**  | **64** | **101** |

### What each variant adds

**Regular → Dev** (+13 patches):

- TXM: +11 patches (selector24 force-pass, get-task-allow, selector42|29 shellcode, debugger entitlement, developer mode bypass)
- CFW: +1 binary patch (launchd jetsam), +1 component (dev rpcserver_ios overlay)

**Regular → JB** (+50 patches):

- iBSS: +1 (nonce skip)
- TXM: +11 (same as dev — selector24, get-task-allow, selector42|29 shellcode, debugger entitlement, dev mode bypass)
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

## Ramdisk Variant Matrix (`make ramdisk_build`)

Why `ramdisk_build` still prints patch logs:

- Step 6 patches `Firmware/txm.iphoneos.release.im4p` via `patch_txm()` (1 trustcache-bypass patch), then signs `Ramdisk/txm.img4`.
- Step 7 may derive `kernelcache.research.vphone600.ramdisk` from pristine CloudOS and apply base `KernelPatcher` (28 patches), then signs `Ramdisk/krnl.ramdisk.img4`.
- Step 7 also always signs restore kernel as `Ramdisk/krnl.img4`.

| Variant       | Pre-step before `make ramdisk_build` | `Ramdisk/txm.img4`               | `Ramdisk/krnl.ramdisk.img4`                                                            | `Ramdisk/krnl.img4`                                      | Effective kernel used by `ramdisk_send.sh`            |
| ------------- | ------------------------------------ | -------------------------------- | -------------------------------------------------------------------------------------- | -------------------------------------------------------- | ----------------------------------------------------- |
| `RAMDISK`     | `make fw_patch`                      | release TXM + base TXM patch (1) | base kernel (28): use legacy `*.ramdisk` if present, else derive from pristine CloudOS | restore kernel from `fw_patch` (28)                      | `krnl.ramdisk.img4` (preferred), fallback `krnl.img4` |
| `DEV+RAMDISK` | `make fw_patch_dev`                  | release TXM + base TXM patch (1) | base kernel (28): same derivation rule as above                                        | restore kernel from `fw_patch_dev` (28)                  | `krnl.ramdisk.img4` (preferred), fallback `krnl.img4` |
| `JB+RAMDISK`  | `make fw_patch_jb`                   | release TXM + base TXM patch (1) | base kernel (28): same derivation rule as above                                        | restore kernel from `fw_patch_jb` (62 = 28 base + 34 JB) | `krnl.ramdisk.img4` (preferred), fallback `krnl.img4` |

Notes:

- `scripts/fw_patch_jb.py` no longer creates a ramdisk snapshot file directly.
- Intent: keep ramdisk boot on a conservative base kernel while preserving full patched restore kernel for later JB flow.
- Investigation details and runtime evidence: `research/jb_mount_failure_investigation_2026-03-04.md`

## Dynamic Implementation Log (JB Patchers)

### TXM (`txm_dev.py`)

All TXM dev patches are implemented with dynamic binary analysis and
keystone/capstone-encoded instructions only.

1. `selector24 force-pass` (2 instructions after prologue)
   - Locator: unique guarded `mov w0,#0xa1` site, scan for `ldr x1,[xN,#0x38] ; add x2 ; bl ; ldp` pattern, walk back to PACIBSP.
   - Patch bytes: `mov w0, #0xa1 ; b <epilogue>` after prologue — returns 0xA1 (PASS) unconditionally.
   - Return code semantics: caller checks `tst w0, #0xff00` — byte 1 = 0 is PASS, non-zero is FAIL.
   - History: v1 was 2x NOP (LDR + BL) which broke flags extraction. v2 was `mov w0, #0x30a1; movk; ret` which returned FAIL (0x130A1 has byte 1 = 0x30). v3 (current) returns 0xA1 (byte 1 = 0 = PASS). See `research/txm_selector24_analysis.md`.
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
- `patch.dyn.raw` generated by `TXMPatcher` (txm_dev.py) on the same input.
- Result: byte-identical (`cmp -s` success, SHA-256 matched).

### Kernelcache (`kernel_jb.py`)

All 24 kernel JB patch methods are implemented in `scripts/patchers/kernel_jb.py`
with capstone semantic matching and keystone-generated patch bytes only:

- Runtime dispatch status: `KernelJBPatcher.find_all()` now enables the full A1-C24
  set (including A2/C23/C24), so JB patch application matches the documented 34
  JB-only kernel patches.

**Group A: Core patches**

1. `AMFIIsCDHashInTrustCache` function rewrite
   - Locator: semantic function-body matcher in AMFI text.
   - Patch: `mov x0,#1 ; cbz x2,+8 ; str x0,[x2] ; ret`.
2. AMFI execve kill path bypass (shared return value)
   - Locator: string xref to `"AMFI: hook..execve() killing"` (fallback `"execve() killing"`),
     then backward scan from function end for `MOV W0, #1` + `LDP x29, x30` epilogue.
   - Patch: `MOV W0, #1 -> MOV W0, #0` at the shared kill-return instruction.
   - All kill paths (unsigned code, restricted exec mode, VPN plugin, dyld sig, etc.)
     converge on this single return value.
   - Previous approach (BL→MOV X0,#0 at two early sites) was patching vnode-type
     precondition assertions, not the actual kill checks — caused CBZ→panic.
3. `task_conversion_eval_internal` guard bypass
   - Locator: unique cmp/branch motif:
     `ldr xN,[xN,#imm] ; cmp xN,x0 ; b.eq ; cmp xN,x1 ; b.eq`.
   - Patch: `cmp xN,x0 -> cmp xzr,xzr`.
   - Hardening (2026-03-05):
     - default fail-closed fast matcher only (slow fallback requires
       `VPHONE_TASK_CONV_ALLOW_SLOW_FALLBACK=1`)
     - extra context fingerprint required before patch:
       `ADRP+LDR` preamble + post-sequence
       `mov x19,x0 ; mov x0,x1 ; bl ; cbz/cbnz w0`
     - both `b.eq` targets must be forward short branches.
4. Extended sandbox MACF hook stubs (25 hooks, JB-only set)
   - Locator: dynamic `mac_policy_conf -> mpc_ops` discovery, then hook-index resolution.
   - Patch per hook function: `mov x0,#0 ; ret`.
   - JB extended indices include vnode/proc hooks beyond base 5 hooks.

**Group B: Simple patches (string-anchored / pattern-matched)**

5. `_postValidation` additional CMP bypass
6. `_proc_security_policy` stub (mov x0,#0; ret) — FIXED: was patching copyio instead
   - Runtime optimization (2026-03-05): locator switched from capstone full-text scan to
     raw instruction-mask matching (`sub wN,wM,#1 ; cmp wN,#0x21`, strict W-form) + raw
     BL decode in `_proc_info` body; shared `_proc_info` anchor scan cache reused by
     `_proc_pidinfo`.
   - JB timing logger readability tweak (2026-03-05): per-method `[T]` and timing summary
     now only print slow methods (runtime `>=10s`), patch output/selection unchanged.
7. `_proc_pidinfo` pid-0 guard NOP (2 sites)
8. `_convert_port_to_map_with_flavor` panic skip — FIXED: was patching PAC check instead
9. `_vm_fault_enter_prepare` PMAP check NOP — FIXED: removed unsafe broad fallback
   - Strict locator (2026-03-05): resolve vm_fault function via symbol/string anchor only;
     in-function unique fingerprint required:
     `BL(rare target) -> LDRB wN,[xM,#0x2c] -> TBZ/TBNZ wN`.
   - Ambiguous/missing matches now fail-closed.
10. `_vm_map_protect` permission check skip
11. `___mac_mount` MAC check bypass — FIXED: patch deny branch (`CBNZ w0`) instead of NOP'ing BL
12. `_dounmount` MAC check NOP — FIXED: unsafe broad kern_text fallback removed (fail-closed)
13. `_bsd_init` auth bypass (mov x0,#0) — FIXED: candidate selection hardened
   - Strict selector (2026-03-05): keep candidates near rootvp anchor region and require
     boot-path `/dev/null` function fingerprint before patching.
   - Prevents high-offset plugin/kext false positives; unresolved cases fail-closed.
14. `_spawn_validate_persona` guard bypass — FIXED: removed global pattern scan
   - Strict locator (2026-03-05): resolve spawn anchor function via
     `com.apple.private.spawn-*` strings; no cross-kernel broad scan.
   - Newer layout support: patch persona gate branch (`tbz/tbnz ... #1`) to unconditional
     `b target` inside the anchored spawn function.
   - Legacy `LDR + TBNZ` two-site NOP path retained when present.
15. `_task_for_pid` proc_ro security copy NOP
16. `_load_dylinker` PAC rebase bypass
17. `_shared_region_map_and_slide_setup` force (cmp x0,x0)
18. `_verifyPermission` (NVRAM) NOP
19. `_IOSecureBSDRoot` check skip — FIXED: requires `SecureRoot`+`SecureRootName` function match and guard-site filtering
20. `_thid_should_crash` zero out

**Group C: Complex shellcode patches**

21. `_cred_label_update_execve` cs_flags shellcode
22. `_syscallmask_apply_to_proc` filter mask shellcode
    - 2026-03-05 revalidation: locator now rejects low-confidence matches and panic-target helper resolution (fail-closed on signature mismatch).
    - 2026-03-05 branch `patch-fix-C22`: temporarily commented out in `kernel_jb.py` for safe testing until new target path is re-derived.
23. `_hook_cred_label_update_execve` inline trampoline + vnode_getattr shellcode
    - Code cave restricted to **TEXT_EXEC only (**PRELINK_TEXT excluded due to KTRR)
    - Inline trampoline (B cave at function entry) replaces ops table pointer rewrite
    - Ops table pointer modification breaks chained fixup integrity → PAC failures
24. `kcall10` syscall 439 replacement shellcode
    - Sysent table base found via backward scan from first `_nosys` match (entry 0 is indirect syscall, not `_nosys`)
    - `sy_call` encoded as auth rebase chained fixup pointer (diversity=0xBCAD, key=IA, addrDiv=0)
    - Matches dispatch's `BLRAA X8, X17` with `X17=0xBCAD` PAC authentication
    - Chain `next` field preserved from original entry to maintain fixup chain integrity

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
> currently has 5 methods emitting 11 patches in txm_dev.py (selector24 force-pass = 2 emits);
> the kernel JB patcher has 24 methods. Actual emit counts depend on how many
> dynamic targets resolve per binary.

All patches are applied dynamically via string anchors, instruction patterns, and cross-reference analysis — no hardcoded offsets — ensuring portability across iOS versions.
