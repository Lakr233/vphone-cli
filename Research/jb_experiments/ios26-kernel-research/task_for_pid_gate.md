# `task_for_pid` gate on iOS 26.5.2 / 27.2 / 27.2.1 — static kernel disassembly (S6)

Scope: static only. Kernelcaches: `23F84` (iPhone 13, iOS 26.5.2), `24B156` (iPhone 17 Pro Max, iOS 27.2.1), `24B119` (iOS 27.2, Basil VM).
No device or VM was touched; no git branches/commits. Inputs: `patch_task_for_pid.md`, `patch_task_conversion_eval_internal.md`, prior notes 01–05/09.

Method: capstone over the decompressed fileset kernelcache (`/tmp/jbresearch/s6/kc.py`, `kdis.py`, `sigsearch.py`). No KDK, no symbols: the function names marked *(inf)* are inferred from code shape plus xnu-12377 `bsd/kern/kern_proc.c`, the only local source. Everything else is observation.

Conventions. VA = full 64-bit kernel VA. 24B156 fileset base is `0xfffffe000700c000`; 23F84/24B119 are `0xfffffff00700c000`. File offsets are into the *decompressed* kernelcache. Byte strings are raw file order (little-endian words).

Status legend: **[obs]** = read directly from disassembly; **[inf]** = inference from shape/source analogy.

## 0. Verdict

**S6 confirmed, with one refinement.** On all three builds, a root caller (uid 0, no task-port entitlements) is refused with `KERN_FAILURE` (5) by `task_for_pid` at exactly one instruction: the `cbnz w0` after the `bl` to the MACF `mac_proc_check_get_task` dispatcher. The rest of the root path passes or is skipped:

- `pid == 0` gate (S1 site) only refuses pid 0.
- `proc_find`, `task_for_pid_posix_check` (root → TRUE) and `task_is_ipc_active` (live task) pass.
- The `TASK_ACCESS_PORT` upcall is skipped for root.
- `task_conversion_eval_internal` is **not** a `kr = 5` source: its failure yields `kr = 0` with `*t = MACH_PORT_DEAD`.

Refinement vs the hypothesis as posed: the refusal is not "a small number of checks" but, for root with a live target, **one** check; the entitlements named by the orchestrator (`com.apple.system-task-ports.*`, `get-task-allow`, `task_for_pid-allow`) are read by the *AMFI implementation* of that hook, not by `task_for_pid` itself.

## 1. Signature search (task b) [obs]

| signature | build | VA | fileoff | bytes | location |
|---|---|---|---|---|---|
| S1 `cbz wPid` (pid==0 gate) | 23F84 | `0xfffffff00a30559c` | `0x330159c` | `180d0034` (`cbz w24`) | `task_for_pid` @ `0xfffffff00a30555c` |
| | 24B156 | `0xfffffe000b1514e0` | `0x414d4e0` | `f7070034` (`cbz w23`) | `task_for_pid` @ `0xfffffe000b1514a0` |
| | 24B119 | `0xfffffff00b1ab0a0` | `0x41a70a0` | `f7070034` (`cbz w23`) | `task_for_pid` @ `0xfffffff00b1ab060` |
| S1 twin (same matcher window) | 23F84 | `0xfffffff00a306a70` | `0x3302a70` | `b70d0034` | `task_name_for_pid` *(inf)*, different cbz word |
| | 24B156 | `0xfffffe000b152300` | `0x414e300` | `f7090034` | idem |
| | 24B119 | `0xfffffff00b1abec0` | `0x41a7ec0` | `f7090034` | idem |
| S2 `cmp x0,x9` in `task_conversion_eval_internal` | 23F84 | `0xfffffff009e30708` | `0x2e2c708` | `1f0009eb` | doc gives `3f0100eb` (`cmp x9,x0`); registers are swapped on all three |
| | 24B156 | `0xfffffe000ac1a7a4` | `0x3c167a4` | `1f0009eb` | |
| | 24B119 | `0xfffffff00ac8c248` | `0x3c88248` | `1f0009eb` | |

The vphone Swift matcher, emulated over the whole kernel `__text` (`sigsearch.py`), yields exactly 2 hits per build: `task_for_pid` and `task_name_for_pid`. This refutes `01_patchfinder_and_first_patch.md` ("0 pairs") and open question 2 in `05_open_questions_and_next.md` ("not found on A15/A19").

The twin's cbz word differs (`b70d0034` / `f7090034`), because its branch distance differs. Consequence: a patcher that replaces the `task_for_pid` cbz word `f7070034` by exact byte search over the whole file would also hit unrelated code (11 occurrences of `f7070034` in 24B119), and a window matcher must pick the hit whose function is `task_for_pid` (lower VA on all three builds), not the twin.

## 2. `task_for_pid` return paths (task c) [obs]

Entry: 23F84 `0xfffffff00a30555c` (fileoff `0x330155c`); 24B156 `0xfffffe000b1514a0` (`0x414d4a0`); 24B119 `0xfffffff00b1ab060` (`0x41a7060`).

Args on all builds: `x0 = &args`; `[x0]` = target_tport (w), `[x0+8]` = pid (w), `[x0+0x10]` = `*t` out pointer, `[x0+0x18]` = flavor. This matches `struct task_for_pid_args`.

Return register: 24B119/24B156 `w24`, 23F84 `w23`. `*t` is written only on the success path (`copyout` of 4 bytes from `[sp+0x1c]`).

### 2a. 24B119 and 24B156 (identical shape)

| # | instruction (24B119 / 24B156) | condition | result |
|---|---|---|---|
| 1 | `0x…b1ab0a0 cbz w23` / `0x…b1514e0 cbz w23` | `pid == 0` | kr=5 (`0x…b1ab19c` / `0x…b1515dc`) — **S1 site** |
| 2 | `0x…b1ab0b8 cbz x0` / `0x…b1514f8 cbz x0` after `bl port_name_to_task(target_tport,0,0,0,0)` | caller's own task port invalid | kr=5 (join of #1) |
| 3 | `0x…b1ab0cc cbz x0` / `0x…b15150c cbz x0` after `bl proc_find(pid)` | no such process | kr=5 (`0x…b1ab1b4` / `0x…b1515f4`) |
| 4 | `0x…b1ab0f8 cbz w0` / `0x…b151538 cbz w0` after `bl task_for_pid_posix_check(p, 0)` | caller not privileged | kr=5 (join of #3) |
| 5 | `0x…b1ab108 tbz w8,#1` (`[p+0x448]`); `0x…b1ab110 cbz x22` / `0x…b151548`, `0x…b151550` | `!P_LHASTASK` or `task (p+0x768) == NULL` | **kr=0, `*t = MACH_PORT_NULL`** (`0x…b1ab248` / `0x…b151688`) |
| 6 | `0x…b1ab128 tbz w8,#5` (`[task+0x6c8]`) / `0x…b151568` | `!task_is_ipc_active(task)` | kr=5 (`0x…b1ab23c` / `0x…b15167c`) |
| 7 | **`0x…b1ab140 cbnz w0`** / **`0x…b151580 cbnz w0`** after `bl mac_proc_check_get_task(p_ucred, &pident, 0)` at `0x…b1ab13c` / `0x…b15157c` | a MACF policy returns nonzero | **kr=5** — the refusal for root |
| 8 | `0x…b1ab148 cbz w8` (`cr_uid == 0`); `0x…b1ab150 b.eq` (`p == kernproc`) / `0x…b151588`, `0x…b151590` | root or self | jump to `0x…b1ab204` / `0x…b151644` (skip upcall) |
| 9 | `0x…b1ab168 cbnz w0`, `0x…b1ab170 cbz x0` / `0x…b1515a8`, `0x…b1515b0` after `bl task_get_task_access_port(task, 9, 0, &port)` at `0x…b1ab164` / `0x…b1515a4` | no TASK_ACCESS_PORT | jump to `0x…b1ab204` / `0x…b151644` |
| 10 | `0x…b1ab178 b.eq` (`port == IP_DEAD`) / `0x…b1515b8` | access port is dead | kr=2 (KERN_PROTECTION_FAILURE) (`x21 = 0; w24 = 2` at `0x…b1ab1c0` / `0x…b151600`) |
| 11 | `0x…b1ab1e4 cbz w0` after `bl check_task_access_with_flavor` at `0x…b1ab1e0` / `0x…b151620` | upcall returned `MACH_MSG_SUCCESS` | continue at `0x…b1ab204` / `0x…b151644` |
| 12 | `0x…b1ab1f4 b.ne` / `0x…b151634` | result ≠ `MACH_RCV_INTERRUPTED` (`0x10004005`) | kr=5 (join of #6) |
| 13 | fallthrough of #12 | result == `MACH_RCV_INTERRUPTED` | kr=0xe (KERN_ABORTED) |
| 14 | `0x…b1ab230 cbz w0` / `0x…b151670 cbz w0` after `bl 0xacd02a8(task)` *(inf: corpse check)* | not a corpse | **kr=0**, `*t = ipc_port_copyout_send(convert_task_to_port(task,0,0), ipcspace)`, `str w0,[sp+0x1c]` at `0x…b1ab274` / `0x…b151750` |
| 15 | fallthrough of #14 | corpse | `task_deallocate` (`0x…b1ab238` / `0x…b151678`), kr=5 |

Common tail (`0x…b1ab248` / `0x…b151688`): `task_deallocate(t1)` via ldaddl on `t1+0x10`; on the success branch `x25 = task` was set (`0x…b1ab244` / `0x…b151684`) so `task_deallocate(task)` runs too; `ipc_port_release_send` of a leftover access-port right (`0x…b1ab280`); `proc_rele(p)` (`0x…b1ab2b0`); `copyout(&[sp+0x1c], args->t, 4)` at `0x…b1ab274` / `0x…b1516b4`; return `w24`. `[sp+0x1c]` was zeroed at entry, so every kr≠0 path yields `*t = 0`.

The `task_for_pid_posix_check` callee: `[p+8] = p_ucred` → `cred`, returns TRUE when `[cred+0x18] == 0` (inlined `kauth_cred_issuser`). [obs]

### 2b. 23F84 (xnu-12377 family)

| # | instruction | condition | result |
|---|---|---|---|
| 1 | `0x…a30559c cbz w24` | `pid == 0` | kr=5 (`0x…a30573c`) — **S1 site** |
| 2 | `0x…a3055b4 cbz x0` after `bl 0x9e327dc` | caller's task port invalid | kr=5 (join of #1) |
| 3 | `0x…a3055c8 cbz x0` after `bl proc_find(pid)` | no such process | kr=5 (`0x…a305774`) |
| 4 | `0x…a3055f4 cbz w0` after `bl task_for_pid_posix_check(p, 0)` | not privileged | kr=5 (join of #3) |
| 5 | `0x…a305604 tbz w8,#1` (`[p+0x458]`); `0x…a305614 cbz x22` | `!P_LHASTASK` or `task == NULL` (task at `p + [0xa8d1520]`, a runtime offset global) | **kr=0, `*t = 0`** (`0x…a30577c`) |
| — | `0x…a305620–0x…a305678` | zone-membership check of the task pointer | panic on failure (`0x…a30596c`) |
| 6 | `0x…a3056bc tbz w8,#4 → 0x…a3056c4`; `0x…a3056c0 tbz w10,#4 → 0x…a30598c` | flag bit set in the task refcount word after the inline `task_reference` | second inline `task_reference` on the way back (`0x…a30587c` / `0x…a305880` same tests → return), else `bl 0x9e5697c(…,0,0)` at `0x…a30588c`; in all cases **kr=0, `*t = 0`** (return at `0x…a305750`). Exact meaning of bit 4 not identified |
| 7 | `0x…a3056c8 tbz w8,#0` (byte `[task+0x15]`) | `!task_is_ipc_active(task)` | kr=5 (`0x…a30572c`) |
| 8 | **`0x…a3056e0 cbnz w0`** after `bl mac_proc_check_get_task(cred, &pident, 0)` at `0x…a3056dc` → `0xa5e7e50` | a MACF policy returns nonzero | **kr=5** — the refusal for root |
| 9 | `0x…a3056e4 cmp w8,#0; ccmp x21,x27,#4,ne; b.ne` | `uid != 0 && p != kernproc` | goes to the upcall (`0x…a305894`); root falls through |
| 10 | `0x…a3058a8 cbnz w0`, `0x…a3058b0 cbz x0` after `bl 0x9e30920(task, 9, 0, &port)` | no TASK_ACCESS_PORT | skip upcall (`0x…a3056f4`) |
| 11 | `0x…a3058b8 b.eq` | access port is dead | kr=2 (`0x…a30591c`) |
| 12 | `0x…a305950 b.ne` after `bl 0xa305ac8` | result ≠ `MACH_RCV_INTERRUPTED` | kr=5 (join of #7) |
| 13 | fallthrough of #12 | result == `MACH_RCV_INTERRUPTED` | kr=0xe |
| 14 | `0x…a305720 cbz w0` after `bl 0x9e6b4cc(task)` | not a corpse | **kr=0**, `*t = ipc_port_copyout_send(convert_task_to_port(task,0,0), …)`, `str w0,[sp+0x1c]` at `0x…a305914` |
| 15 | fallthrough of #14 | corpse | `task_deallocate`, kr=5 |

Common tail: `task_deallocate(t1)`, release `[sp+0x10]`, release `x26`, return `w23`.

## 3. The MACF hook (task d) 

### Observed

- The dispatcher (`24B119 0xfffffff00b49f700`, `24B156 0xfffffe000b44c9b4`, `23F84 0xfffffff00a5e7e50`) iterates the registered policy list, loads `[policy+0x20]` (`mpc_ops`) then `[ops+0x310]` (slot 98), and calls it with `(x0 = cred, x1 = &pident, x2 = flavor)` via `blraa`. It folds return codes by priority: `0xb` (EPERM, the initial value) → `0x16` (EINVAL) → `3` (ESRCH) → `2` → `0xd` (EACCES) → `1`. If no policy registers the slot, it returns 0.
- **The hook is 3-argument on all three builds.** (An earlier pass of mine claimed 4 arguments for 13432; that was wrong.)
- AMFI contains the entitlement strings `get-task-allow`, `task_for_pid-allow`, `com.apple.system-task-ports.read`, `.inspect`, `.control`, and a function that reads them with 3 arguments:

| build | AMFI `mpo_proc_check_get_task`-shaped function | fileoff | `task_for_pid-allow` xref in it |
|---|---|---|---|
| 23F84 | `0xfffffff008bb3494` | `0x1baf494` | `0xfffffff008bb3594` |
| 24B156 | `0xfffffe000927e534` | `0x227a534` | `0xfffffe000927e634` |
| 24B119 | `0xfffffff009273be4` | `0x226fbe4` | `0xfffffff009273ce4` |

Deny-path log string `"AMFI: task_for_pid() not allowed\n"`: 23F84 `0xfffffff00754f394` (fileoff `0x54b394`), 24B156 `0xfffffe000766e3af` (fileoff `0x66a3af`), 24B119 `0xfffffff00765f09f` (fileoff `0x65b09f`). On 24B119 the 3-arg function loads `0x765f09f` at `0x9273d40–0x9273d48` right before returning 1. [obs]

Decoded logic (24B119; the other two have the same instruction shape) [obs]:

```
x0 = cred, x1 = &pident, x2 = flavor
target = 0x928d6ec(x1)                    ; resolve target (inf: proc_ident → proc/cred)
if (!target) return 3;                    ; ESRCH
if (flavor == 3) return 0;
if (0x92700a0(target, "get-task-allow", &flag) ok && flag) return 0;
e21 = has_ent(cred, "com.apple.system-task-ports.inspect");
if (flavor >= 2 && e21) return 0;
w23 = !e21 && has_ent(cred, "com.apple.system-task-ports.read");
if (flavor != 0 && w23) return 0;
w22 = has_ent(cred, "com.apple.system-task-ports.control")
    | has_ent(cred, "task_for_pid-allow");
if (e21 || w23) return 0;
if (0x928d2cc(target) && w22) return 0;    ; inf: target is get-task-allow
log "AMFI: task_for_pid() not allowed …"; return 1;   ; EPERM
```

- A second AMFI function (24B119 `0xfffffff0092710d4`, 24B156 `0xfffffe000927ba24`, 23F84 `0xfffffff008bb0c8c`) also references `task_for_pid-allow` but takes 5 arguments and calls the string `"AMFI: allowing pid %u to inherit IPC ports"` family — it is `mpo_proc_check_inherit_ipc_ports`-shaped [inf], not the `task_for_pid` gate.
- For the `task_for_pid` call the flavor is `0` (`mov w2, #0` at `0x…b1ab138` / `0x…b151578` / `0x…a3056d8`). With flavor 0 the hook reduces to: allow iff the caller has `.inspect`, or `.read`, or (`target` is get-task-allow AND the caller has `.control` or `task_for_pid-allow`); otherwise return 1. The dispatcher keeps 1 (fold order 0xb, 0x16, 3, 2, 0xd, 1; once a code is recorded it is not replaced by a later one), so `task_for_pid` sees `w0 = 1`, takes `cbnz` and returns its own constant 5 — the hook's value is discarded.
- Consequence [obs from the decoded logic; the predicate `0x928d2cc(target)` is unnamed, read as "target is get-task-allow"]: `task_for_pid-allow` alone does not let a root caller get the port of a target that is not get-task-allow; `.inspect` or `.read` do.

### Inferences

- [inf] The 3-arg function above *is* AMFI's `mpo_proc_check_get_task`. Evidence: 3 args matching the dispatcher's call; reads exactly the entitlements that govern `task_for_pid`; returns EPERM/ESRCH; logs "task_for_pid() not allowed". Not proven: I did not locate the `mac_policy_ops` table statically (the runs I first took for ops tables were IOKit vtables — see §6), so the slot-98 binding itself is unverified.
- [inf] Which policy denies a given root caller at runtime is therefore AMFI (the only implementer I found), unless Sandbox also registers slot 98 — not checked.
- The orchestrator's phrase `com.apple.system-task-ports.get-task-allow` conflates two different things: `get-task-allow` is a property of the **target** process (its code signature / entitlement), while `com.apple.system-task-ports.{read,inspect,control}` and `task_for_pid-allow` are entitlements of the **caller**.

## 4. `task_conversion_eval_internal` and why S2 does not change `kr` [obs]

24B119 `0xfffffff00ac8c188`. `convert_task_to_port(task, 0, 0)` (`0xac8c7e4`) calls `eval(current_task(), task, 1, 0)`; on nonzero result it returns `IP_DEAD` (−1); `ipc_port_copyout_send` returns `-1` unchanged when `arg+1 < 2`; `task_for_pid` stores it and returns **kr = 0, `*t = MACH_PORT_DEAD`**.

So on a stock kernel, after S1 + S3, an entitled-less root caller would already get `kr = 0`; whether the port is usable depends on `task_conversion_eval_internal`. S2 (`cmp x0,x9` → `cmp xzr,xzr`, bytes `1f0009eb` → `ff031feb`, at `0x…c248`) forces the `b.eq` at `0x…c24c` (→ `0x…c284`, `return w8`, with `w8 = 0` set at `0x…c234`), which precedes the kernel_task-target and `0xacd0184` checks. It therefore makes the eval return 0 for every call that reaches that instruction, i.e. after the `[0x7e4d348]`, `task == target`, `w3`, and `0xacd02a8(target) != 0` checks have passed; it does not bypass those.

Eval's internal logic as read (names uncertain): `target == NULL → 0x23`; zone check target; global `[0x7e4d348]` bit0 set → 0; `task == target → 0`; `arg3 != 0 → 0`; `0xacd02a8(target) == 0 → 0x23` with an os_log when arg2 == 0; **`task == kernel_task → 0` (S2 site)**; `target == kernel_task → 0x23`; `0xacd0184(target) == 0 → 0`; `0xacd0184(task) == 0 → 0x23`; else 0. `0x23` (35) is not a `KERN_*` constant I can name.

Caveat: `0xacd02a8` returns bit 5 of `[obj+0x60]` for the zone-5 object at `task+0x3c8` whose `[obj+8] == task`. I did not identify it.

## 5. Per-build minimal patch description

All replacements are 4 bytes, in place, no length change. Apply to the *decompressed* kernelcache and re-sign/re-pack with the existing vphone pipeline.

| id | purpose | build | VA | fileoff | original | replacement |
|---|---|---|---|---|---|---|
| S1 | NOP the `pid == 0` `cbz` in `task_for_pid` | 23F84 | `0xfffffff00a30559c` | `0x330159c` | `18 0d 00 34` | `1f 20 03 d5` |
| | | 24B156 | `0xfffffe000b1514e0` | `0x414d4e0` | `f7 07 00 34` | `1f 20 03 d5` |
| | | 24B119 | `0xfffffff00b1ab0a0` | `0x41a70a0` | `f7 07 00 34` | `1f 20 03 d5` |
| S3 | NOP the `cbnz w0` after `mac_proc_check_get_task` | 23F84 | `0xfffffff00a3056e0` | `0x33016e0` | `60 02 00 35` | `1f 20 03 d5` |
| | | 24B156 | `0xfffffe000b151580` | `0x414d580` | `e0 07 00 35` | `1f 20 03 d5` |
| | | 24B119 | `0xfffffff00b1ab140` | `0x41a7140` | `e0 07 00 35` | `1f 20 03 d5` |
| S2 | `cmp x0, x9` → `cmp xzr, xzr` in `task_conversion_eval_internal` | 23F84 | `0xfffffff009e30708` | `0x2e2c708` | `1f 00 09 eb` | `ff 03 1f eb` |
| | | 24B156 | `0xfffffe000ac1a7a4` | `0x3c167a4` | `1f 00 09 eb` | `ff 03 1f eb` |
| | | 24B119 | `0xfffffff00ac8c248` | `0x3c88248` | `1f 00 09 eb` | `ff 03 1f eb` |

Notes on S3:

- NOP the `cbnz`, not the `bl`. NOPing the `bl` leaves `w0 = low 32 bits of the cred pointer` (set by `mov x0, x24` right before), which is nonzero → still kr=5.
- S3 alone is not sufficient: S1 is needed for pid 0 only, and the usable-port question is S2. For a root caller with a live, non-corpse target: S3 → kr=0 (`MACH_PORT_DEAD` if eval fails); S3 + S2 → kr=0 with a real port [inf for "real": eval forced to 0, `convert_task_to_port` returns the send right].
- S3 does not touch `task_name_for_pid`, `task_read_for_pid` or the corpse path; it only removes the MACF check inside `task_for_pid`.
- S3 is a behaviour change for every caller (not only root): non-root callers still need the access-port upcall, which will still fail without a port.

Doc corrections to carry: `patch_task_for_pid.md` gives only file offsets (0xFC383C / 0xF8783C) and no original bytes; `patch_task_conversion_eval_internal.md` gives `3f0100eb` while the three caches here encode `1f0009eb` (`cmp x0,x9`), so a byte-exact matcher for `3f0100eb` finds nothing on these builds.

## 6. Dead ends (so nobody repeats them)

- "Runs of chained pointers in kext `__DATA_CONST,__const` are `mac_policy_ops` tables": false. The entries decode (low 32 bits of `0x8011…` words = unslid VA) to kernel functions like `0xfffffff00b399344`, which are OSMetaClass `metaCast`-style methods (`autda x16, x20 ^ 0xcda1…`). They are IOKit vtables.
- No stored pointer (low-32 form) to AMFI's `"AMFI"` / `"AppleMobileFileIntegrity"` strings exists in the file, so the `mac_policy_conf` could not be located that way. The `mac_policy_ops` slot 98 binding is unverified (§3).
- `dyld_info -fixups` segfaults on these caches.

## 7. What was not done

- No runtime check of any kind. In particular the `kr=5` attribution to the MACF hook for the Basil VM case is a static conclusion: it assumes the target process was alive with an active IPC space and `proc_find` succeeded, which a `kr=5` (not `KERN_INVALID_TASK`/`ESRCH`) return is consistent with.
- `task_name_for_pid`, `task_read_for_pid`, `pid_for_task` and the `TASK_ACCESS_PORT` upcall path were not enumerated.
- Sandbox.kext (`com.apple.security.sandbox.kext`) was not checked for a slot-98 hook; the earlier `kc.load` for `com.apple.security.Sandbox` failed on a name mismatch and was not retried.
- Field semantics left unnamed: `[current_proc()+0x18]` (behaves as the current proc again for the is-self/kernproc compare), the object at `task+0x3c8`, the global `[0x7e4d348]`.
