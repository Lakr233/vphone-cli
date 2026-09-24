# C23 `patch_hook_cred_label_update_execve`

## Scope

- Kernel analyzed: `kernelcache.research.vphone600`
- Concrete target image: `ipsws/PCC-CloudOS-26.1-23B85/kernelcache.research.vphone600`
- Analysis date: `2026-03-06`
- Method: IDA MCP + local `research/reference/xnu` + focused Python dry-run
- Trust policy: historical notes for this patch were treated as untrusted and re-derived from the live PCC 26.1 research kernel

## Executive Verdict

`patch_hook_cred_label_update_execve` should be implemented as a **faithful upstream C23 wrapper trampoline**, not as an early-return patch.

The correct PCC 26.1 target is the sandbox `mac_policy_ops[18]` entry for `mpo_cred_label_update_execve`. On this kernel that table entry points to the wrapper at `0xfffffe00093bdb64` (`sub_FFFFFE00093BDB64`), not directly to the internal helper at `0xfffffe00093bbbf4` (`sub_FFFFFE00093BBBF4`).

The rebuilt repo implementation now follows upstream C23 behavior:

- retarget `ops[18]` to a code cave,
- assemble the cave body via keystone `asm()` instead of hardcoded instruction words,
- fetch file metadata with `vnode_getattr(vp, &vap, vfs_context_current())`,
- if `VSUID`/`VSGID` are present, copy owner UID/GID into the pending new credential,
- set `proc->p_flag |= P_SUGID` when either field changes,
- then branch back to the original wrapper.

This means C23 is **not** a direct sandbox-disable patch. It is a compatibility trampoline that preserves exec-time setugid credential state before the normal sandbox wrapper continues.

## Verified Binary Facts

### 1. The live PCC 26.1 `ops[18]` entry points to the wrapper

Focused dry-run and local pointer decode on `kernelcache.research.vphone600` show:

- sandbox `mac_policy_conf` at file offset `0x00A54428`
- `mpc_ops` table at file offset `0x00A54488`
- `ops[18]` entry at file offset `0x00A54518`
- original raw chained pointer: `0x8010EC79023B9B64`
- decoded target file offset: `0x023B9B64`
- decoded target VA: `0xfffffe00093bdb64`

So on this kernel, `ops[18]` is the wrapper `sub_FFFFFE00093BDB64`.

### 2. The wrapper calls the internal helper

IDA MCP on the same PCC 26.1 research kernel shows:

- wrapper: `sub_FFFFFE00093BDB64`
- inner helper: `sub_FFFFFE00093BBBF4`
- call site inside wrapper: `0xfffffe00093be8d0`

So the runtime call chain is:

- sandbox policy table `ops[18]`
- wrapper `sub_FFFFFE00093BDB64`
- internal helper `sub_FFFFFE00093BBBF4`

### 3. Faithful upstream C23 branches back to the wrapper, not the helper

The rebuilt C23 cave uses the same high-level structure as upstream:

- save argument registers,
- call `vfs_context_current`,
- call `vnode_getattr`,
- update pending credential UID/GID from vnode owner when `VSUID`/`VSGID` are set,
- set `P_SUGID`,
- restore registers,
- branch back to the original wrapper entry.

For PCC 26.1, the resolved helper targets are:

- `vfs_context_current` body at file offset `0x00B756DC`
- `vnode_getattr` body at file offset `0x00CC91B4`
- branch-back target wrapper at file offset `0x023B9B64`

## XNU Cross-Reference

Open-source XNU confirms the field semantics used by the faithful C23 shellcode:

- `VSUID` / `VSGID` are defined in `research/reference/xnu/bsd/sys/vnode.h:807`
- `struct vnode_attr::{va_uid, va_gid, va_mode}` are defined in `research/reference/xnu/bsd/sys/vnode.h:690`
- `struct ucred::cr_uid` is defined in `research/reference/xnu/bsd/sys/ucred.h:155`
- `cr_gid` aliases `cr_groups[0]` in `research/reference/xnu/bsd/sys/ucred.h:211`
- `P_SUGID` is defined in `research/reference/xnu/bsd/sys/proc.h:177`
- exec-time MAC label update reaches this area through `kauth_proc_label_update_execve(...)` in `research/reference/xnu/bsd/kern/kern_credential.c:4367`
- exec path setugid handling is in `exec_handle_sugid(...)` in `research/reference/xnu/bsd/kern/kern_exec.c:6833`

## What C23 Does After Rebuild

### Facts

The rebuilt C23 now does exactly two writes in focused dry-run, and the cave body is keystone-generated rather than hand-written as raw instruction words:

1. retarget `ops[18]` from the original wrapper pointer to the code cave
2. emit a `0xB8`-byte cave implementing the setugid fixup trampoline

Focused dry-run output on `ipsws/PCC-CloudOS-26.1-23B85/kernelcache.research.vphone600`:

- `0x00A54518` — retarget `ops[18]` to faithful C23 cave
- `0x00AB1720` — faithful upstream C23 cave body

The patched chained-pointer qword becomes:

- new raw entry: `0x8010EC7900AB1720`

### Inference

C23’s role in the jailbreak patchset is best understood as a **boot-safety / semantic-preservation shim** around exec-time sandbox transition handling.

It does **not** directly remove the sandbox wrapper. Instead it ensures that setuid/setgid-derived credential state is already reflected in the pending exec credential before the original sandbox wrapper runs. That is consistent with the historical upstream choice to preserve exec-time credential semantics while other jailbreak patches relax deny decisions elsewhere.

## Validation Status

### Syntax validation

Passed:

- `python3 -m py_compile scripts/patchers/kernel_jb_patch_hook_cred_label.py scripts/patchers/kernel_jb.py`

### Focused dry-run validation

Passed in-memory only; no firmware image was written back.

Observed output:

- 2 patches emitted
- `ops[18]` correctly decoded and retargeted
- cave placed at `0x00AB1720`
- cave branches back to wrapper `0x023B9B64`
- cave encodes BL calls to `vfs_context_current` and `vnode_getattr`

## Repo Status After This Pass

- `scripts/patchers/kernel_jb_patch_hook_cred_label.py` now implements faithful upstream C23 semantics
- `scripts/patchers/kernel_jb.py` includes `patch_hook_cred_label_update_execve` in the active Group C schedule
- `research/0_binary_patch_comparison.md` should describe C23 as a faithful wrapper trampoline, not as a mis-targeted early-return patch

## Practical Effect

After the rebuild, C23 should provide the following effect on the current PCC 26.1 research kernel:

- preserve exec-time `VSUID` / `VSGID` credential transfer,
- preserve `P_SUGID` marking,
- keep the original sandbox wrapper execution path alive,
- avoid the broader boot-risk of replacing the whole wrapper with an immediate success return.

That is the main reason this direction is safer than the old “return 0 from the hook path” interpretations.
