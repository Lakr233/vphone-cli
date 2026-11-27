# EVFILT_AIO / aio_workq_entry lifetime in 23F84 (iOS 26.5.2) and 24B156 (iOS 27.2.1)

Workflow `jb-hypotheses` S1 (static, kernel). Question: is the AIO-kevent UAF that lightsword
claims on iOS 26.2 (xnu-12377.62.10, "track B / B12") still present, i.e. can a knote outlive its
`aio_workq_entry` so that `filt_aioprocess` reads a freed 224-byte entry?

Static only. No device touched.

## Verdict: refuted for both builds

In both kernelcaches `filt_aioattach` takes a reference on the entry (`ldadd +1, [entry+0x2c]`)
right after storing the hook, and `filt_aiodetach` releases it. The entry is only freed at
refcount 0, so the knote cannot outlive the entry. 24B156 adds a second guard: the free path
panics if the entry's knote list (`entry+0xc0`) is non-empty.

`filt_aioprocess` itself is unchanged in shape from the 12377 source: it dereferences
`kn->kn_hook` with no liveness check. Those derefs are only reachable while the knote holds a
ref, so they are not dangling.

## Inputs

| Item | 23F84 | 24B156 |
|---|---|---|
| File | `/tmp/jbresearch/ipsw/x13/kc.decomp/kernelcache.release.iphone14.decompressed` | `/tmp/jbresearch/ipsw/x17/kc.decomp/kernelcache.release.v54.decompressed` |
| Device | iPhone 13, iOS 26.5.2 | iPhone 17 Pro Max, iOS 27.2.1 |
| Kernel base | `0xfffffff00700c000` | `0xfffffe000700c000` |
| `__TEXT_EXEC,__text` | `0xfffffff009de1000` + `0x8493e8` | `0xfffffe000ab95000` + `0x900618` |
| Pointer decode | `(raw & 0xffffffff) + 0xfffffff007004000` | `(raw & 0xffffffff) + 0xfffffe0007004000` |

Tools: `/tmp/jbresearch/evfilt_aio/{kc.py,kdis.py}` (`kdis.py <build> <vahex> [n]`),
venv `/tmp/jbresearch/venv/bin/python` (capstone). `xcrun dyld_info -fixups` segfaults on both
files; the kernelcache has no real chained fixups (0 imports), pointers are PAC'd.

Source reference: `/tmp/jbresearch/igmp/xnu/full/xnu-12377.121.6/bsd/kern/{kern_aio.c,kern_event.c}`.
Lineage: 11417.101.15 and 11417.140.69 have `[~EVFILT_AIO] = &bad_filtops` and `aio_sigev_validate`
rejects anything but SIGEV_SIGNAL/SIGEV_NONE, so `SIGEV_KEVENT` + `aio_filtops` are new in the
12377 line.

## Symbol locations

| Symbol | 23F84 VA | 23F84 file offset | 24B156 VA | 24B156 file offset |
|---|---|---|---|---|
| `sysfilt_ops[]` | `0xfffffff007ad9bc8` | `0xad5bc8` | `0xfffffe0007ea3578` | `0xe9f578` |
| `sysfilt_ops[2]` (= `~EVFILT_AIO`) | `0xfffffff007ad9bd8` | `0xad5bd8` | `0xfffffe0007ea3588` | `0xe9f588` |
| `aio_filtops` | `0xfffffff007ad9e90` | `0xad5e90` | `0xfffffe0007ea3848` | `0xe9f848` |
| `filt_aioattach` | `0xfffffff00a2baf38` | `0x32b6f38` | `0xfffffe000b10405c` | `0x410005c` |
| `filt_aiodetach` | `0xfffffff00a2badf8` | `0x32b6df8` | `0xfffffe000b103f60` | `0x40fff60` |
| `filt_aioevent` | `0xfffffff00a2bada0` | `0x32b6da0` | `0xfffffe000b103f08` | `0x40fff08` |
| `filt_aiotouch` | `0xfffffff00a2bad80` | `0x32b6d80` | `0xfffffe000b103ee8` | `0x40ffee8` |
| `filt_aioprocess` | `0xfffffff00a2baa6c` | `0x32b6a6c` | `0xfffffe000b103a0c` | `0x40ffa0c` |
| `aio_entry_unref` | inlined | | `0xfffffe000b103db0` | `0x40ffdb0` |
| `aio_free_request` (zfree path) | `0xfffffff00a2bacbc` | `0x32b6cbc` | inlined in `aio_entry_unref` (`0x…3dec`..`0x…3e88`) | |
| `aio_proc_remove_done_locked` | `0xfffffff00a2babcc` | `0x32b6bcc` | `0xfffffe000b103cb8` | `0x40ffcb8` |
| `aio_return` | `0xfffffff00a2bd6d8` | `0x32b96d8` | `0xfffffe000b1060b4` | `0x41020b4` |
| `do_aio_completion_and_unlock` | `0xfffffff00a2bb580` | `0x32b7580` | not located (not needed) | |
| `aio_klist` (global, lock at +8) | `0xfffffff00a97b928` / `0x930` | | removed; per-entry list at `entry+0xc0`, lock at `entry+0xd0`/`+0xd8` | |

`aio_filtops` raw words (f_isfd, f_attach, f_detach, f_event, f_touch, f_process):

- 23F84: `0, 0x8010e4fe032b6f38, 0x80102abe032b6df8, 0x801050c7032b6da0, 0x8010e4fe032b6d80, 0x8050e4fe032b6a6c`
- 24B156: `0, 0x8010e4fe0410005c, 0x80102abe040fff60, 0x801050c7040fff08, 0x8010e4fe040ffee8, 0x8030e4fe040ffa0c`

Table alignment check: 23F84 has 41 slots, 24B156 has 42. Slots 0-16 line up one-to-one
(READ, WRITE, AIO, VNODE, PROC, SIGNAL, TIMER, MACHPORT, FS, USER, UNUSED_11, VM, SOCK,
MEMORYSTATUS, EXCEPT, NW_CHANNEL, WORKLOOP). 23F84 slot 17 is `bad_filtops`; 24B156 slot 17
is a real filter and every later slot shifts by one (24B156 slot 18 = KQREAD, slot 40 =
`bad_filtops` = DETACHED). Slot [2] is EVFILT_AIO in both.

## `aio_workq_entry` offsets (identical in both builds)

| Field | Offset | Evidence |
|---|---|---|
| `aio_workq_link` | `+0x00/+0x08` | `aio_free_request` checks `[+0x8] != 0` -> panic |
| `aio_proc_link` | `+0x10/+0x18` | `aio_return` walks `[x21,#0x10]`; free checks `[+0x18]` |
| `returnval` | `+0x20` | `filt_aioprocess` `ldr x8,[x19,#0x20]` -> `kn_ext[1]` (`kn+0x68`) |
| `errorval` | `+0x28` | `filt_aioprocess` `ldrsw x8,[x19,#0x28]` -> `kn_ext[0]` (`kn+0x60`) |
| `aio_refcount` | `+0x2c` | every `aio_entry_ref`/`unref` `ldadd[l]` targets `+0x2c` |
| `flags` | `+0x30` | `AIO_COMPLETED` bit 0 read as `ldrb [entry,#0x31]` bit 0 in `filt_aioevent` |
| `procp` | `+0x40` | `ldr x20,[x19,#0x40]` before `aio_proc_lock` |
| `uaiocbp` | `+0x48` | `aio_return` `ldr x8,[x21,#0x48]; cmp` vs `*uap` |
| `sigev_notify` | `+0x78` | `aio_return` `ldr w8,[x21,#0x78]; cmp w8,#4` |
| knote list (24B156 only) | `+0xc0` | attach `str x0,[x8,#0xc0]`; detach walks it; free checks it |
| lock (24B156 only) | `+0xd0` (+`0xd8` armed) | `lck_mtx_lock(0xfffffe000ac24788)` on `entry+0xd0`, `casa` on `+0xd8` |

All of lightsword's assumed offsets (+0x20, +0x28, +0x48, +0x2c, +0x40) hold in both builds.

Knote offsets used: `kn_hook` `+0x28`, `kn_fflags` `+0x50`, `kn_ext[0]` `+0x60`, `kn_ext[1]`
`+0x68`, `kn_flags` `+0x42`, `kn_filter`/`kn_filtid` `+0x40`/`+0x41` (hook PAC discriminator
blend `0x4f71`).

## `filt_aioprocess`: the derefs (present in both builds, not dangling)

23F84 (`0xfffffff00a2baa6c`):

```
0xfffffff00a2baa84  ldr  x16, [x17, #0x28]!        ; kn->kn_hook
0xfffffff00a2baaa8  autda x16, x17                  ; entry = PAC-decoded hook
0xfffffff00a2baab0  ldr  w8, [x0, #0x50]            ; kn_fflags
0xfffffff00a2baab8  ldr  x20, [x19, #0x40]          ; procp = entry->procp     <- raw deref
0xfffffff00a2baabc  ldrsw x8, [x19, #0x28]          ; kn_ext[0] = entry->errorval
0xfffffff00a2baac4  ldr  x8, [x19, #0x20]           ; kn_ext[1] = entry->returnval
...
0xfffffff00a2bab28  casa x8, x9, [x20+0x58]         ; aio_proc_lock
0xfffffff00a2bab3c  bl   0xfffffff00a2babcc         ; aio_proc_remove_done_locked
0xfffffff00a2bab48  casl ...                        ; aio_proc_unlock
0xfffffff00a2bab54  add  x0, x19, #0x2c
0xfffffff00a2bab5c  ldaddl w8, w8, [x0]             ; aio_entry_unref (inlined)
0xfffffff00a2bab60  cbz  w8, 0xfffffff00a2babb8      ; underflow -> panic
0xfffffff00a2bab68  b.eq  0xfffffff00a2babbc        ; old==1 -> free
0xfffffff00a2bab6c  mov  w0, #1                     ; FILTER_ACTIVE
0xfffffff00a2babc4  bl   0xfffffff00a2bacbc         ; aio_free_request
```

24B156 (`0xfffffe000b103a0c`):

```
0xfffffe000b103a28  ldr  x16, [x17, #0x28]!         ; kn_hook
0xfffffe000b103a4c  autda x16, x17
0xfffffe000b103a60  ldr  x21, [x19, #0x40]          ; procp                 <- raw deref
0xfffffe000b103a6c  add  x10, x19, #0xd8
0xfffffe000b103a70  casa x8, x9, [x10]              ; entry lock             <- raw deref (24B156 only)
0xfffffe000b103a7c  ldr  w8, [x0, #0x50]            ; kn_fflags
0xfffffe000b103a84  ldrsw x8, [x19, #0x28]
0xfffffe000b103a8c  ldr  x8, [x19, #0x20]
...
0xfffffe000b103b60  bl   0xfffffe000b103cb8         ; aio_proc_remove_done_locked
0xfffffe000b103bb8  mov  x0, x19
0xfffffe000b103bbc  bl   0xfffffe000b103db0         ; aio_entry_unref
0xfffffe000b103bc0  mov  w0, #1
0xfffffe000b103bc4..0xfffffe000b103bd0  casl [x19+0xd8]  ; entry unlock AFTER unref
```

Observations:

- No instruction between the hook load and the `+0x40/+0x28/+0x20` loads checks anything
  about the entry. The source's `assert(entryp)` is compiled out; the `cbz` after `autda`
  only skips when the hook word is 0.
- `filt_aioprocess` never clears `kn_hook`. It releases the *proc* reference, not the knote's.
- 24B156 only: the `casa` on `entry+0xd8` at `0x…3a70` touches the entry before the
  `kn_fflags` gate, and the matching `casl` at `0x…3bd0` runs *after* `aio_entry_unref`
  returns. If the unref were the last one, that unlock would be a write to freed memory.
  It cannot be the last one, because the knote's own reference is still held (see below).

## The instruction that prevents the dangling deref

23F84 `filt_aioattach` (`0xfffffff00a2baf38`):

```
0xfffffff00a2baf50  tbnz w9, #0xc, ...              ; EV_KERNEL required, else EPERM at +0x58
0xfffffff00a2bafb0  pacda x17, x16
0xfffffff00a2bafbc  str  x17, [x9]                   ; kn->kn_hook = entry (kn+0x28)
0xfffffff00a2bafc0  add  x8, x8, #0x2c
0xfffffff00a2bafc4  mov  w9, #1
0xfffffff00a2bafc8  ldadd w9, w9, [x8]              ; aio_entry_ref: refcount++   <=== ref taken
0xfffffff00a2bafd4  cmp  w9, w10 ; b.ls -> panic    ; os_ref overflow check
0xfffffff00a2baff0  casa ... [0xfffffff00a97b928]  ; aio_klist_lock
...                                                 ; KNOTE_ATTACH(&aio_klist, kn)
```

24B156 `filt_aioattach` (`0xfffffe000b10405c`):

```
0xfffffe000b104064  tbnz w9, #0xc, ...              ; EV_KERNEL required
0xfffffe000b10409c  str  xzr, [x0, #0x70]
0xfffffe000b1040cc  pacda x17, x16
0xfffffe000b1040d8  str  x17, [x9]                   ; kn->kn_hook = entry
0xfffffe000b1040dc  add  x9, x8, #0x2c
0xfffffe000b1040e4  ldadd w10, w10, [x9]            ; aio_entry_ref              <=== ref taken
0xfffffe000b1040f0  cmp  w10, w11 ; b.ls -> panic
0xfffffe000b1040f8  ldr  x9, [x8, #0xc0]            ; link kn into entry->knote list
0xfffffe000b1040fc  str  x9, [x0, #0x18]
0xfffffe000b104100  str  x0, [x8, #0xc0]
```

The matching release in `filt_aiodetach`:

- 23F84 (`0xfffffff00a2badf8`): hook autda `0x…bae34`; `aio_klist_lock` `0x…bae4c`; SLIST
  remove `0x…bae58..0x…bae88`; unlock `0x…bae94`; `cbz x16 -> return` `0x…baea0`
  (`0x…baebc`); `ldaddl -1,[x16+0x2c]` `0x…baeac`.
- 24B156 (`0xfffffe000b103f60`): hook autda `0x…3f8c`; NULL -> `ret` `0x…3fec`; `casa` on
  `entry+0xd8` `0x…3fb8`; SLIST remove `0x…3fc4..0x…3ff4`; unlock `0x…4004`; tail
  `b aio_entry_unref` `0x…4024`.

Reference accounting per entry over its life (12377 source and both binaries agree):

| Event | Refs | Where |
|---|---|---|
| entry allocated | 1 (proc) | `aio_queue_async_request` |
| enqueued to workq | +1 | `aio_try_enqueue_work_locked` |
| `aio_register_kevent` -> `filt_aioattach` | +1 (knote) | `ldadd` above |
| I/O completes (`do_aio_completion_and_unlock`) | -1 (workq), after KNOTE | 23F84 KNOTE `0x…bb7d4`, unref `0x…bb854`, free `0x…bb8ac` |
| `kevent()` -> `filt_aioprocess` | -1 (proc) | `ldaddl` above |
| oneshot -> `knote_drop` -> `filt_aiodetach` | -1 (knote) | `ldaddl` above -> 0 -> free |

The knote's reference is released only in `filt_aiodetach`, which runs from `knote_drop` after
`filt_aioprocess` has already returned (`knote_process_one`, kern_event.c 12377: `f_process`
at ~4385, `knote_drop` at ~4457, under the kq lock). So every `kn_hook` deref happens while
that reference is held.

24B156 has an additional belt: `aio_entry_unref` (`0xfffffe000b103db0`), on reaching 0:

```
0xfffffe000b103dcc  ldaddl w9, w9, [x8]             ; [entry+0x2c]
0xfffffe000b103dd0  cbz  w9, 0xfffffe000b103e8c      ; underflow -> panic
0xfffffe000b103dd4  cmp  w9, #1 ; b.eq 0x…3dec       ; ==1 -> free
0xfffffe000b103df0  ldr  x8, [x0, #0x18] ; cbnz -> panic   ; still on proc list
0xfffffe000b103df8  ldr  x8, [x0, #8]  ; cbnz -> panic    ; still on workq
0xfffffe000b103e00  ldr  x8, [x0, #0xc0]; cbnz -> 0x…3ec8  ; knote list non-empty -> panic  <=== new in 27
0xfffffe000b103e18  bl   lck_mtx_destroy(entry+0xd0)
... zfree
```

23F84's `aio_free_request` (`0xfffffff00a2bacbc`) has the `+0x18`/`+0x8` list checks only; it
has no knote-list check because 23F84 has no per-entry knote list.

## `aio_return` does not release SIGEV_KEVENT entries (both builds)

23F84 `aio_return` `0xfffffff00a2bd6d8`:

```
0xfffffff00a2bd77c  ldr  w8, [x21, #0x78]
0xfffffff00a2bd780  cmp  w8, #4                      ; SIGEV_KEVENT
0xfffffff00a2bd784  b.eq ... skip                   ; keep walking doneq
... -> mov w20, #0x16 (EINVAL)
```

24B156 `aio_return` `0xfffffe000b1060b4`:

```
0xfffffe000b1061a0  ldr  x8, [x21, #0x48]            ; entry->uaiocbp
0xfffffe000b1061a8  cmp  x8, x9                      ; == *uap
0xfffffe000b1061b0  ldr  w8, [x21, #0x78]
0xfffffe000b1061b4  cmp  w8, #4
0xfffffe000b1061b8  b.eq  0xfffffe000b10618c        ; next entry
0xfffffe000b1061c8  bl   0xfffffe000b103cb8         ; aio_proc_remove_done_locked
0xfffffe000b1061cc  ldr  x8, [x21, #0x20]            ; *retval = returnval
0xfffffe000b1061d4  cmn  x8, #1 ; b.eq -> ldr w20,[x21,#0x28]  ; errorval
0xfffffe000b1061e4  mov  w20, #0x24                 ; still active -> EINPROGRESS
0xfffffe000b1062c4  bl   0xfffffe000b103db0         ; aio_entry_unref
0xfffffe000b10617c  mov  w20, #0x16                 ; not found -> EINVAL
```

Live baseline on 23F84 (`/tmp/jbresearch/wq_x13/out.txt`, pre-existing file, not run for this
task): `aio_read(SIGEV_KEVENT) -> 0`, `aio_return=-1 errno=22`, `kevent64 -> n=1 filter=-3
ext1=0x100 ident=<aiocbp>`, and `kevent64(EV_ADD EVFILT_AIO) -> data=1` (EPERM from the
EV_KERNEL check). Consistent with the disassembly.

Consequence for lightsword's PoC: its "FREE" step is `aio_return(&s_cb1)` on a SIGEV_KEVENT
entry, and its hit test requires `aio_return` to return `>= 0`. In both target builds that call
returns EINVAL without touching the refcount, so the entry is never freed by that step and the
knote's `ext[1]` reads the original entry's `returnval`, not a reclaim's.

## Other things checked

- `aio_proc_remove_done_locked` (23F84 `0x…babe0 cbz x10 -> brk #0xbffd`; 24B156
  `0x…3ccc cbz x8 -> brk #0xbffd`): removing an entry whose `aio_proc_link.tqe_prev` is NULL
  panics. Two knotes on the same entry via two kqueues would therefore hit `brk` on the second
  `filt_aioprocess`, not a UAF.
- `_aio_exit` (12377 source lines 931-997) unrefs every doneq entry including kevent ones; the
  knote's ref keeps the entry alive until the kqueue is torn down.
- `filt_aioevent` (23F84 `ldrb [x16,#0x31]` `0x…badd4`; 24B156 `0x…3f3c`) reads the entry
  under `aio_klist_lock` / `entry+0xd8`, and `do_aio_completion_and_unlock` KNOTEs before its
  unref (23F84 order verified above). The knote ref covers this too.
- `filt_aiotouch` returns `EV_ERROR|EV_ERROR(0x4000)`, `data = 0x2d` (ENOTSUP), so a user
  `EV_ADD` on an existing AIO knote cannot change it; `EV_ADD` without `EV_KERNEL` is refused
  with EPERM at attach.
- 24B156 slot [18] (KQREAD after the shift) is a second AIO-style filter (`aio_filtops` at
  `0xfffffe0007ea3978`, attach `0x…44d4`, process `0x…4120`): same `kn+0x28` hook and same
  `+0x2c` refcount, but it also refs the lio leader (`entry+0x38 -> +0x2c`) and its `f_event`
  tests `leader->lio_pending` (`+0x34`). Same ref discipline, so the same conclusion applies.

## Not done

- 26.2 (xnu-12377.62.10) itself is not available locally, so the claim "hook set without ref"
  on 26.2 is neither confirmed nor contradicted here. What is shown is that 26.5.2 and 27.2.1
  both take the ref.
- `do_aio_completion_and_unlock` on 24B156 was not located; the KNOTE-before-unref order was
  only verified on 23F84 and in the 12377 source.
- 23F84 unref sites at `0x…c250`, `0x…e134`, `0x…06a30` and 24B156 sites at `0x…522c0` were
  not identified. None of them is reachable with the knote ref outstanding in a way that
  changes the count above.
