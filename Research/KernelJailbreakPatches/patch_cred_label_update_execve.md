# C21 `patch_cred_label_update_execve`

## Scope

- Kernel used for reverse engineering: `kernelcache.research.vphone600`.
- IDA symbol / address: `__Z25_cred_label_update_execveP5ucredS0_P4procP5vnodexS4_P5labelS6_S6_PjPvmPi` at `0xFFFFFE000864DEFC`.
- XNU semantic reference: `research/reference/xnu/security/mac_vfs.c`, `research/reference/xnu/bsd/kern/kern_exec.c`, `research/reference/xnu/bsd/kern/kern_credential.c`, `research/reference/xnu/osfmk/kern/cs_blobs.h`.

This note is a fresh re-analysis. Older notes for this patch were treated as untrusted and not reused as ground truth.

## Call Stack

Exec-time path in XNU source:

1. `exec_handle_sugid()` asks `mac_cred_check_label_update_execve(...)` whether any MAC policy wants an exec-time credential transition.
2. If yes, `exec_handle_sugid()` calls `kauth_proc_label_update_execve(...)`.
3. `kauth_proc_label_update_execve(...)` allocates / updates the new credential and calls `mac_cred_label_update_execve(...)`.
4. `mac_cred_label_update_execve(...)` iterates `mac_policy_list` and invokes each policy's `mpo_cred_label_update_execve` hook.
5. AMFI's hook is `_cred_label_update_execve` in `com.apple.driver.AppleMobileFileIntegrity`.

Relevant source anchors:

- `research/reference/xnu/bsd/kern/kern_exec.c:6854`
- `research/reference/xnu/bsd/kern/kern_exec.c:6950`
- `research/reference/xnu/bsd/kern/kern_credential.c:4367`
- `research/reference/xnu/security/mac_vfs.c:777`

## What The Function Actually Does

Reverse engineering of `0xFFFFFE000864DEFC` shows that AMFI's hook is not just a boolean kill gate.

It performs all of the following before returning success or failure:

- validates the exec target / `cs_blob` and reports AMFI analytics;
- checks multiple kill conditions and returns `1` on rejection;
- mutates `*csflags` during successful exec handling;
- derives extra flags from entitlement state;
- performs final bookkeeping before returning `0`.

Observed kill / deny subpaths in IDA:

- completely unsigned code path;
- Restricted Execution Mode denials;
- legacy VPN plugin rejection;
- dyld signature verification failure;
- helper failure from `sub_FFFFFE000864E5A0(...)` with reason string.

All of those failure edges converge on the shared kill return at `0xFFFFFE000864E38C` (`mov w0, #1`).

Observed success-path `csflags` mutations in IDA:

- `0xFFFFFE000864E1E8`: ORs `0x2200` or `0x200` into `*csflags` depending on dyld / helper state.
- `0xFFFFFE000864E200`: ORs `0x802A00` into `*csflags` when AMFI-derived entitlement flags require SIP-style inheritance.
- `0xFFFFFE000864E4EC`, `0xFFFFFE000864E500`, `0xFFFFFE000864E51C`, `0xFFFFFE000864E534`: OR installer / rootless / datavault / NVRAM-related bits into `*csflags`.
- `0xFFFFFE000864E570`: ORs `0x2A00` into `*csflags` in the final success tail.

The relevant flag meanings from XNU are in `research/reference/xnu/osfmk/kern/cs_blobs.h:32`.

## Why The Old Patch Broke Boot

The previous implementations were both too broad:

1. the original shellcode version forged new `csflags` at function exit;
2. the later "low-risk" version simply returned from function entry.

The entry-return strategy is fundamentally wrong for boot stability because it skips AMFI's normal exec-time work entirely.

That means it bypasses:

- `cs_blob` / signature-state handling;
- AMFI auxiliary analytics / bookkeeping;
- entitlement-derived `csflags` propagation;
- final per-exec state setup that later code expects to have happened.

In short: `_cred_label_update_execve` is on the boot-critical exec path, so turning it into an unconditional `return 0` is not a safe jailbreak strategy.

## Repaired Patch Strategy

The current C21-v1 patcher no longer returns from function entry and no
longer hijacks the beginning of the success tail.

Instead it:

1. keeps AMFI's full exec-time logic intact;
2. finds the canonical epilogue at `0xFFFFFE000864E390`;
3. redirects the shared deny return (`0xFFFFFE000864E38C`) and both late
   success exits (`0xFFFFFE000864E580`, `0xFFFFFE000864E588`) into one
   common trampoline;
4. reloads `u_int *csflags` from the function's own stack slot in the cave,
   so the cave works for both deny and success exits;
5. clears only the restrictive execution bits from `*csflags`;
6. forces `w0 = 0` and branches into the original epilogue.

The current trampoline clears this mask:

- `CS_HARD`
- `CS_KILL`
- `CS_CHECK_EXPIRATION`
- `CS_RESTRICT`
- `CS_ENFORCEMENT`
- `CS_REQUIRE_LV`

Bitmask used by the patcher: `0xFFFFC0FF`.

This preserves AMFI's normal validation / entitlement work while removing the sticky exec-time restrictions that are most hostile to jailbreak tooling.

## C21-v1 Scope

This is intentionally the smallest credible C21-only design:

- it no longer needs `patch_amfi_execve_kill_path` in the same default schedule; on PCC 26.1 they overlap on the same shared deny-return site, so C21 supersedes A2 there;
- it does not patch function entry;
- it does not forge `CS_VALID`, `CS_PLATFORM_BINARY`, `CS_ADHOC`, or other
  high-risk identity bits;
- it only converts late exits in `_cred_label_update_execve` to success and
  normalizes the restrictive `0x3F00` cluster.

## C21-v1 Outcome

- User restore testing confirms C21-v1 boots successfully.
- That result validates the central design assumption: `_cred_label_update_execve`
  can be patched safely as long as AMFI's main body is preserved and only the
  final exits are redirected.

## Dry-Run Verification (extracted PCC 26.1 research kernel)

Dry-run patch generation against the extracted raw Mach-O from
`ipsws/PCC-CloudOS-26.1-23B85/kernelcache.research.vphone600` produced the
following C21-v1 shape:

- code cave: `0x00AB0F00`
- shared deny-return branch site: `0x0163C0FC`
- late success-exit branch sites: `0x0163C2F0`, `0x0163C2F8`

Emitted trampoline body:

- `ldr x26, [x29, #0x18]`
- `cbz x26, +0x10`
- `ldr w8, [x26]`
- `and w8, w8, #0xFFFFC0FF`
- `str w8, [x26]`
- `mov w0, #0`
- `b epilogue`

Observed C21-v1 raw patch count: `10`

- `7` instructions in the trampoline cave
- `3` patched branch sites in `_cred_label_update_execve`

## C21-v2 Refinement

After C21-v1 boot success, the patch was refined to separate deny and success
semantics instead of using one common cave for all exits.

### Reason for v2

C21-v1 proved that the late-exit structure is safe enough to boot, but it still
cleared `0x3F00` on the shared deny path. That is broader than necessary.

C21-v2 narrows that behavior:

- deny exit: force only `w0 = 0`, then return through the original epilogue;
- success exits: keep the late `csflags` normalization path.

### C21-v2 dry-run shape

- deny cave: `0x00AB02B8`
- success cave: `0x00AB0F00`
- deny-return branch site: `0x0163C0FC`
- late success-exit branch sites: `0x0163C2F0`, `0x0163C2F8`

Observed C21-v2 raw patch count: `12`

- `2` instructions in the deny cave
- `7` instructions in the success cave
- `3` patched branch sites in `_cred_label_update_execve`

## C21-v3 Refinement

After preparing the safer split-exit structure in v2, the next experimental
step adds only the smallest helper-bit subset from the older upstream idea.

### Reason for v3

The old upstream shellcode not only cleared restrictive flags, but also set a
much broader collection of identity / helper bits. Most of those are too risky
to restore directly.

C21-v3 keeps the v2 structure and adds only this success-only increment:

- `CS_GET_TASK_ALLOW` (`0x4`)
- `CS_INSTALLER` (`0x8`)

Combined set mask used by v3: `0x0000000C`

### C21-v3 dry-run shape

- deny cave: `0x00AB02B8`
- success cave: `0x00AB0F00`
- deny-return branch site: `0x0163C0FC`
- late success-exit branch sites: `0x0163C2F0`, `0x0163C2F8`

Observed C21-v3 raw patch count: `13`

- `2` instructions in the deny cave
- `8` instructions in the success cave
- `3` patched branch sites in `_cred_label_update_execve`

Success-cave body now becomes:

- `ldr x26, [x29, #0x18]`
- `cbz x26, +0x10`
- `ldr w8, [x26]`
- `and w8, w8, #0xFFFFC0FF`
- `orr w8, w8, #0xC`
- `str w8, [x26]`
- `mov w0, #0`
- `b epilogue`

## Intended Effect

After the repaired patch:

- AMFI still runs its normal exec-time hook and keeps boot-critical side effects intact.
- C21 now carries its own late deny→allow transition inside `_cred_label_update_execve`.
- Successfully launched processes end up with a less restrictive `csflags` set, especially around kill / hard / library-validation style behavior.

This is a much narrower and more defensible jailbreak patch than forcing an unconditional success return at function entry.

## Current Status

- Scheduler note (`2026-03-06`): C21 and A2 both target the shared deny-return site `0x0163C0FC` on the extracted PCC 26.1 research kernel (`0xFFFFFE00086400FC` VA). C21 is treated as the superset patch on this path, so A2 is removed from the default schedule instead of being stacked with C21.
- Patch implementation updated in `scripts/patchers/kernel_jb_patch_cred_label.py` as C21-v3.
- C21-v1 has already booted successfully in restore testing.
- Default schedule now keeps C21 enabled on the current PCC 26.1 path while removing A2 from the same default list, because C21 supersedes A2 at the shared deny-return site.
- Expected dry-run patch shape for C21-v3 is:
  - 1 deny cave;
  - 1 success cave;
  - 1 branch patch at the shared deny return;
  - 2 branch patches at the two late success exits.
- The current dry-run matches that expected shape exactly.
- If C21-v3 regresses boot, the most likely cause is not the split late-exit structure, but the newly added `0xC` helper-bit OR on the success path.
