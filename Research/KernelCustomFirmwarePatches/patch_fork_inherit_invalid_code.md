# `patchForkInheritInvalidCode` (`kernel-exp-frida_fork_inherit_invalid_code`)

## Scope

Opt-in Frida patch in `com.vphone.patchset.kernel.frida`, off in every preset
but `experimental`, gated to cloudOS 26.4+. Written for vp-fuzzer's AFL++
forkserver, which must `fork()` a process Frida Gum has already instrumented.

Semantic, and nothing wider: **when a process forks, the child inherits the
parent's permission to execute the code pages the parent rewrote, but only if
the parent holds Apple's debugger entitlement `com.apple.private.cs.debugger`.**

The key is Apple's own, the one TXM's debugger gate asks for; vphone adds no
entitlement of its own. Tools that already carry it (debugserver, Frida-style
loaders, vp-fuzzer's fuzz loader) need no new signing. `get-task-allow` was not
chosen: every Xcode debug build carries it, and a process without the debugger
key can still rewrite and run its own code (see Runtime Validation), so it
would widen the patch to far more processes.

What it does not change:

- A parent without the entitlement: its child is copied exactly as today.
- `execve` and `posix_spawn`: neither runs `vm_map_fork`, so a new image is
  validated as today.
- Any other region: only entries that were debug regions in the parent
  (`vme_xnu_user_debug`) are touched; ordinary signed code is associated as before.
- Code-signing flags: the child keeps `CS_KILL | CS_HARD`, gets no `CS_DEBUGGED`,
  and `cs_invalid_page` is not touched. What it gets back is the per-region
  association its parent already had, nothing a debugger grant would add.

## Problem

Gum's Interceptor (and Stalker's code writer) change code the way a debugger
does: `vm_protect(VM_PROT_COPY | RW)`, write, `vm_protect(RX)`. The parent runs
those pages. With AFL's deferred forkserver (`##SIG_AFL_DEFER_FORKSRV##`) every
forked child died inside `_libc_fork_child`, and so does the minimal case
`gum_init_embedded(); fork();`:

```text
EXC_BAD_ACCESS / KERN_PROTECTION_FAILURE, signal SIGKILL
termination: namespace CODESIGNING, indicator "Invalid Page"
vmregioninfo: __TEXT 18045d000-180460000 r--/rw- SM=PRV /usr/lib/system/libdyld.dylib
```

The child's copy of the rewritten page is `r--/rw-`: execute has been taken
from both protections. In the parent the same region is `r-x/rwx`.

## What the parent has that the child lacks (xnu-12377, confirmed on 26.4)

The research kernel runs a code-signing monitor (SPTM/TXM,
`CODE_SIGNING_MONITOR`). The first guess — process code-signing flags — is
wrong: `forkproc()` copies `p_csflags` (everything but `CS_KILLED`), and the
parent itself is not `CS_DEBUGGED` (`csops` shows `VALID GET_TASK_ALLOW
ENFORCEMENT PLATFORM` in both). The parent can run its rewritten pages because
of **per-mapping state in the monitor**:

1. `vm_protect(RX)` on the private copy reaches `vm_map_protect`'s "a
   !csm_associated mapping becoming executable" branch, which calls
   `vm_map_entry_cs_associate(map, entry, vmkf_remap_prot_copy)`.
2. With `vmkf_remap_prot_copy` that function takes its debug path:
   `csm_associate_debug_region(pmap, start, size)` registers the range with TXM
   as a debug region, then the entry gets `vme_xnu_user_debug` (bit 27 of the
   flags word at `[entry, #0x38]`) and, on success, `csm_associated` (bit 23) and
   `vme_permanent` (bit 19).
3. A fault on a `csm_associated` entry defers to the monitor
   (`vm_fault_cs_check_violation` skips `vm_page_validate_cs`), and TXM allows
   the debug region.

`vm_map_fork` copies each entry without that state, and nothing rebuilds it:

- `vm_map_entry_copy` → `vm_map_entry_copy_csm_assoc` clears `csm_associated`
  and, off macOS, `vme_xnu_user_debug` (in the 26.4 binary: `and w8, w9,
  #0xe07fffff`, clearing bits 23–28).
- `csm_fork_prepare` → `txm_fork_prepare` is a no-op ("TXMTODO"), so the child's
  TXM address space has no debug regions.
- The new entry is linked with `vm_map_store_entry_link(new_map, …, NONE)`,
  which itself calls `vm_map_entry_cs_associate(map, entry, NONE)`: the entry is
  associated as **ordinary signed code**. The monitor refuses a modified page,
  and the failure path strips `VM_PROT_ALLEXEC` from `protection` and
  `max_protection` — the `r--/rw-` above. The child's execute fault then ends
  in `cs_invalid_page` with `CS_KILL` → `CODESIGNING "Invalid Page"`.

`cs_allow_invalid` (the ptrace grant) does not help, which is why an earlier
version of this patch that called it at `fork()` was dropped: a child that ran
`ptrace(PT_TRACE_ME)` itself (`CS_DEBUGGED`, `CS_KILL` clear) still faulted,
with SIGBUS instead of SIGKILL, because the region had already lost execute and
TXM still had no debug region for it. A forked child *can* register a debug
region of its own — rewriting a fresh shared-cache function in the child works
with no patch — so the only thing missing is the association of the inherited
entries.

## Approach — associate the child's copy as a debug region, at the link

The patch hooks the one `vm_map_store_entry_link` call that vm_map_fork's
share path and fast copy path share, and changes only its `vmk_flags`
argument (the fifth, `x4`, which the link passes straight to
`vm_map_entry_cs_associate`):

```asm
pacibsp
sub  sp, sp, #0x40
stp  x29, x30, [sp] ; stp x19, x20, [sp, #0x10] ; stp x21, x22, [sp, #0x20]
str  x23, [sp, #0x30]
mov  x29, sp
mov  x19…x23, x0…x4              ; the link's arguments
ldr  w8, [x28, #0x38]            ; the parent's entry (x28 in vm_map_fork)
tbz  w8, #27, link               ; not a debug region in the parent
mov  x0, #0                      ; IOTaskHasEntitlement(NULL = current task = parent, …)
adrp x1, key ; add x1, x1, #lo12
bl   IOTaskHasEntitlement
cbz  w0, link
movz x23, #0x400, lsl #32        ; vmkf_remap_prot_copy (bit 42), as vm_map_protect passes it
link:
mov  x0…x4, x19…x23
bl   vm_map_store_entry_link
ldr  x29, x30, x19…x23 ; add sp, sp, #0x40
retab
.asciz "com.apple.private.cs.debugger"   ; padded with 0xFF, never zero
```

With the flag, the link's own association takes the debug path on the child's
pmap — the same call the parent's `vm_protect(VM_PROT_COPY)` made — so the
child's entry ends `csm_associated | vme_xnu_user_debug | vme_permanent`,
keeps `r-x/rwx`, and its faults defer to the monitor. vm_map_fork runs on the
parent's thread (`fork1` → `cloneproc` → `task_create_internal`), so the
NULL-task entitlement query asks about the parent. It also runs for corpse
creation of an entitled process; a corpse map is never executed.

The slow copy path (`vm_map_fork_copy`: wired entries, `true_share` objects,
or a failed `vm_object_copy_quickly`) links through another site and is not
covered. The rewritten shared-cache pages and Gum's own allocations take the
fast path (verified below).

## Semantic Reveal Procedure

No offsets, VAs, registers or instruction words are hardcoded.

1. **vm_map_fork**: the function holding every reference to its panic
   `vm_map_fork(%p): attempting to fork from a kernel map @%s:%d`.
2. **vm_map_entry_cs_associate and vmkf_remap_prot_copy**: in vm_map_protect
   (its panic `vm_map_protect(%p,0x%llx,0x%llx) new=0x%x wired=%x @%s:%d`),
   the one `bl F` right after a single-bit `mov x2, #imm` whose callee tests that
   bit of x2 (`tbz/tbnz x2, #n`). That gives F and the flags word (`1 << 42`).
3. **vme_xnu_user_debug**: in F, the first single-bit
   `ldr wF, [x1, #0x38] ; orr wF, wF, #(1 << b) ; str wF, [x1, #0x38]` after a
   call — the store after `csm_associate_debug_region` (b = 27).
4. **Hook and old-entry register**: in vm_map_fork, the inlined copy's
   "inherit permanent" step `ldr wA, [R, #0x38] ; and wA, wA, #(1 << 19)`
   followed by a store to `[N, #0x38]` names the old entry R and the new entry
   N (one pair only). The hook is the one `bl` preceded by `mov x0, xMap ;
   mov x1, xN ; mov x2, #0 ; mov x3, #0 ; mov x4, #0` (the slow-copy loop's link
   passes a copy entry, so it does not match). R must be x24…x28 (callee-saved
   and outside the cave's own x19…x23).
5. **IOTaskHasEntitlement**: the common call of every
   `com.apple.private.thread-set-state` reference (string in x1), whose entry
   resolves a NULL task to the current one (`cbnz x0 ; mrs x0, tpidr_el1`).
6. **Cave**: every word from `ARM64Encoder` / `ARM64`, Capstone round-tripped
   (mnemonic sequence, the old-entry base register, the tested bit, both branch
   targets, the flags immediate, both call targets). The string's padding is
   `0xFF` and every word of the blob is checked not to be `0`, `0xFFFFFFFF` or
   `udf #0`, the words `findCodeCave` treats as free. A 36-byte key puts its NUL
   at the start of a word; padded with zeros that word was free space, and on
   the iOS 27 research kernel `kernel-boot-hook_cred_label.c23_cave` landed on it
   and overwrote the terminator, so the entitlement query silently failed.
   (That was the first key, `com.vphone.fork.inherit-invalid-code`; the current
   30-byte key ends inside a word, and the check stays for any key.)

Any step that does not match exactly fails closed and leaves the kernel
unchanged. Two records: `.cave` and `.hook`.

## 26.4 Static Validation

| Kernel | vm_map_fork | hook | vm_map_entry_cs_associate | IOTaskHasEntitlement | cave |
|---|---|---|---|---|---|
| `kernelcache.release.vphone600`, cloudOS 26.4 23E5207q, UUID `281F97D7-1F00-0870-DDA8-1578B18B73D0` | `0x1CC2BD4` | `0x1CC3074` | `0x1CBEF08` | `0x23831A8` | `0x1B986F0` |
| `kernelcache.research.vphone600` restored into machine `27.01` (iOS 27.0.1 24A446 on cloudOS 26.4) | `0x1DCABD4` | `0x1DCB074` | `0x1DC6F08` | `0x248B1A8` | `0x1CA3630` |

File offsets. On both, the old entry is x28, the flags `0x40000000000`, the
debug bit 27. The hook replaces `bl vm_map_store_entry_link` with `bl cave`.
With the patch blocked, the kernel is byte-identical to the 2.15.0 release
patcher's output for the same selection.

## Runtime Validation

Probe: `VPhoneGuestComponents/Tests/ForkInheritProbe` (`build.zsh`).
`forkprobe` rewrites `cbrt` in a private copy of its libsystem_m page to
`mov w0, #42 ; ret` (VM_PROT_COPY, write, RX), runs it, forks, and the child
prints its region and runs it again. `forkgum` is the Frida form:
`gum_init_embedded()`, then `fork()`, the child exits 0 (Frida Gum 17.24.3
devkit, linked statically). `-inherit` carries the vp-fuzzer loader's
entitlements as they are, `-plain` the same set without
`com.apple.private.cs.debugger`. The `-ldid` forms are signed by `vphone-cli sign`.
Target `arm64e-apple-ios17.4`, run as root through vphoned's `proc.run`.

Guest: machine `27.01`, iOS 27.0.1 24A446 on cloudOS 26.4, preset
`experimental`, kernel swapped with `cfw update-kernel`; "patch off" is the same
selection with `--block kernel-exp-frida_fork_inherit_invalid_code`.

| Kernel | Binary | Child region | Result |
|---|---|---|---|
| patch off | forkprobe-plain, -plain-ldid | `r--/rw-` | SIGKILL, `CODESIGNING` "Invalid Page" |
| patch off | forkprobe-inherit, -inherit-ldid | `r--/rw-` | SIGKILL, `CODESIGNING` "Invalid Page" |
| patch off | forkgum-plain | — | SIGKILL, `CODESIGNING` "Invalid Page" (libdyld page) |
| patch off | forkgum-inherit | — | SIGKILL, `CODESIGNING` "Invalid Page" (libdyld page) |
| patch on | forkprobe-plain, -plain-ldid | `r--/rw-` | SIGKILL, `CODESIGNING` "Invalid Page" |
| patch on | forkprobe-inherit, -inherit-ldid | `r-x/rwx` | `cbrt(0) = 42`, exit 0 |
| patch on | forkgum-plain | — | SIGKILL |
| patch on | forkgum-inherit | — | "alive after fork", exit 0 |

Every parent, with or without the debugger key, rewrites `cbrt` and runs it
(`cbrt(0) = 42`, region `r-x/rwx`), so the key does not decide whether a
process may rewrite code, only whether its fork children keep it. The result is
the same whether the binary is signed by Apple's `codesign -s -` or by
`vphone-cli sign` (ldid's output). Only patch on with the entitlement changes
behaviour. Re-run 2026-11-04 with the debugger key, bundle `2.15.0-local.7282f0aa`;
that run recorded the signal only, and the "Invalid Page" reason is from the
first run's crash reports, which had the same signals and regions.

## Validation Requirements

- Dry run emits exactly two records, `.cave` and `.hook`; the hook is a `bl`
  to the cave in place of a `bl` inside vm_map_fork; no other record overlaps
  the cave (`KernelForkInheritInvalidCodeTests`, with `VPHONE_KERNEL_RAW`).
- Blocked, the kernel is byte-identical to the build without the patch.
- If any anchor does not match exactly once, the patch fails closed.
- On the guest, only an entitled parent's child keeps the rewritten region
  executable, and only with the patch on.
