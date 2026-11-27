# Kernel CVEs first listed in iOS 26.6 / 26.6.1 / 26.7 / 27.0 — static candidate ranking for 23F84

Date: 2026-11-26 (UTC). Method: static only — local Apple advisory HTML copies, local XNU clones, two
decompressed kernelcaches (23F84 = iOS 26.5.2 / iPhone 14, 24B156 = iOS 27.2.1 / `v54`). No device used.

Builds compared: **open** = 23F84 (`/tmp/jbresearch/ipsw/x13/kc.decomp/kernelcache.release.iphone14.decompressed`),
**fixed** = 24B156 (`/tmp/jbresearch/ipsw/x17/kc.decomp/kernelcache.release.v54.decompressed`).

XNU source trees (separate clones, original `/tmp/jbresearch/igmp/xnu/full/` untouched):
`/tmp/jbresearch/xd/xnu-11417.101.15` (≈26.5), `xnu-11417.140.69` (≈26.6), `xnu-12377.121.6` (27.0 OSS).

Verdict summary: **S2 confirmed** — one candidate (CVE-2026-86962 ↔ MPTCP `mptcp_subflow_soreceive`/
`mptcp_validate_csum` double-free of an mbuf still linked on `so_rcv`) has a named function, a described
remote trigger, a sandbox-reachable entry point, and is localised in the 23F84 kernelcache without a KDK,
with a binary-visible fix in 24B156. The CVE↔bug mapping is an inference (repo name + "double free" wording);
everything else is observation.

---

## 1. Ranked table

| # | CVE | Subsystem | Function / lifetime bug | Sandbox reachability (unentitled app) | Public PoC | Confidence |
|---|-----|-----------|-------------------------|----------------------------------------|-----------|------------|
| 1 | **CVE-2026-86962** (double free → "unexpected system termination"; fixed 26.7 / 27.0 / 15.8 / macOS 26.7, 27) | `bsd/netinet` MPTCP | `mptcp_subflow_soreceive()` (mptcp_subr.c:2013): DSS with `data_len=1` + `DATA_FIN` → `dlen--` → 0 → `while (dlen > 0)` dequeue loop skipped → `m`/`start` still == `so->so_rcv.sb_mb` → `mptcp_validate_csum(start,…)` (mptcp.c:1199) `m_freem()`s it on bad csum → mbuf freed while linked on `so_rcv` → double free at `soclose`/`sbflush`, or write-after-free when `sbappend` sets `m_nextpkt` on the freed record (`assertion failed: m->m_nextpkt == NULL`, mptcp_subr.c:2141) | **Kernel gate: Yes** — `socket(PF_MULTIPATH=41, SOCK_STREAM, IPPROTO_TCP)` + `connect()` to attacker server. The only entitlement gate, `mptcp_entitlement_check()` (mptcp_usrreq.c:222), denies only `MPTCP_SVCTYPE_AGGREGATE`; default `MPTCP_SVCTYPE_HANDOVER` (0) passes for every app; no priv_check on the data path. **Seatbelt profile: not verified** (no compiled 23F84 profile decoded; see §3). | https://github.com/bobmarleyfaruk9/CVE-2026-86962 (`mptcp_report.md`, `mptcp_client_v2.c`, `mptcp_dfin_reach.py`, 4 panic `.ips`) — local copy `/tmp/jbresearch/pubsrc/` | **High** for the bug (source + binary both builds); **Medium** for the CVE attribution |
| 2 | CVE-2026-43687 (UAF per adv_149041 26.7; iOS 27 page: "malicious NFS server may disclose kernel memory"; R4mbb/KRsecurity + Peter Malone) | `bsd/nfs` NFS client | `_nfs_vnop_access`: unsynchronised read of `nfsnode` access-cache pointer; 26.7 fix adds `lck_rw_t` at `nfsnode+0x158` taken shared | Third-party: **not reachable** (mounting NFS needs `com.apple.private.nfs` / `mount` privilege, not in third-party sandbox). As *victim* of a malicious server it is an LPE for a local admin who mounts, not an app trigger. Not a candidate for "unentitled sandboxed app". | https://github.com/jvidhan/cve-2026-43687 (`poc.sh`, dtrace capture) | Medium (fix shape consistent with advisory; no binary check done) |
| 3 | CVE-2026-84507 (race → "termination or corrupt kernel memory"; Billy Jheng / Pan Zhenpeng, STAR Labs) | unknown | unknown — no public technical detail found; not visible in the 26.5→26.6 diff | unknown | none | Low |
| 4 | CVE-2026-65359 (OOB read → "termination or read kernel memory", local user) | unknown | unknown — no public technical detail found | unknown | none | Low |
| 5 | CVE-2026-84602 (UAF → "unexpected system termination", STAR Labs; adv_149041) | unknown | unknown — no public technical detail found | unknown | none | Low |
| 6 | CVE-2026-64720 (race → "unexpected system termination"; adv_128066, 26.6) | candidate: `bsd/netinet/tcp_timer.c` | Observation: the **only** comment-documented UAF fix in the 26.5→26.6 diff is `tcp_sched_timers()` now incrementing `so->so_usecount` before list insert, `tcp_remove_timer()` decrements (underflow log). Unmatched to a CVE (inference: plausible for a 26.6 "race"). | Unentitled: plain TCP socket (`socket(AF_INET, SOCK_STREAM)`), `(allow network*)`. | none | Low–Medium (bug real; CVE link unproven) |

Unmatched 26.6-era observations (not CVE-mapped): none other in diff A besides tcp_timer.c — the rest are
features/hardening (dlil flowswitch race, vfs_attrlist prefix, NECP tracker, zalloc memtag canonicalize).

---

## 2. Recommended first static-localisation target

**`mptcp_subflow_soreceive` → `mptcp_validate_csum` (candidate #1).** It is the only candidate where all
three legs of S2 are independently established: named function with a lifetime bug in the 23F84-era source,
a remote trigger that needs no privilege on the device, and the code is present and already located in the
23F84 kernelcache.

### 2.1 Localisation in 23F84 (no KDK) — observation

Tooling: `/tmp/jbresearch/igmp/kdiff.py` (string xref + `pacibsp` prologue walk), helper scripts written this
session: `/tmp/jbresearch/mptcp_loc.py`, `mptcp_dis.py`, `blnames.py`, `diswin.py`.

| Symbol | 23F84 (iPhone 14, 26.5.2) | 24B156 (27.2.1) | How identified |
|---|---|---|---|
| `mptcp_subflow_soreceive` | `0xfffffff00a20c3e4`, size `0xb94` (741 ins) | `0xfffffe000b0505c8`, size `0xc6c` (795 ins) | xrefs to `"mptcp_subflow_soreceive 1"`, `"… 2"`, `"m->m_nextpkt == NULL"` all land in this function |
| `mptcp_validate_csum` | `0xfffffff00a1fe204` | `0xfffffe000b042128` | own `pacibsp` function; sums `m_pkthdr.len` over chain, `rev/rev16` pseudo-header fold, `cmp w9,#0xffff`; failure sets `t_mpflags |= 0x200000` (TMPF_SND_MPFAIL) then `bl 0xa36468c` loop = `m_freem`; matches mptcp.c:1148–1212 |
| `mptcp_update_rcv_state_meat` | `0xfffffff00a1fdf3c` | — | string `"mptcp_update_rcv_state_meat"` at `0xfffffff00707b437` |
| `sb_lock`/`sbunlock` | `0xfffffff00a37edcc` / `0xfffffff00a37f448` | `0xfffffe000b1cd924` / `0xfffffe000b1cdf94` | strings `sb_lock`, `sb_lock_nointr` |
| `mptcp_subflow_add` | `0xfffffff00a200aa0` | `0xfffffe000b044aa4` | string `"mptcp_subflow_add"` |
| `soreceive`-side `sbappend`-check | `0xfffffff00a381dd4` | `0xfffffe000b1d08a0` | strings `"%s: sb %p so %p cc %d mbcnt %d mb %p mbtail %p lastrecord %p"`, `uipc_socket2.c` |

Full disassemblies: `/tmp/jbresearch/mptcp_sorecv_23F84.dis`, `/tmp/jbresearch/mptcp_sorecv_24B156.dis`,
`/tmp/jbresearch/validate_csum_23F84.dis`.

23F84 DFIN/`dlen` arithmetic (`0xfffffff00a20c700–0xa20c744`):

```
0xa20c700  and  w10, w26, #0x40000000      ; PKTF_MPTCP_DFIN
0xa20c708  lsl  w10, w10, #1
0xa20c70c  add  w24, w25, w10, asr #31     ; dlen = mp_rlen + (dfin ? -1 : 0)
0xa20c710  cmp  w9, w24                    ; sb_cc < dlen ?
0xa20c714  b.lt → EWOULDBLOCK
0xa20c740  cmp  w24, #1
0xa20c744  b.lt 0xa20c974                  ; dlen == 0 → skip dequeue loop
...
0xa20cadc  cbz  x28, 0xa20caf4             ; x28 = m (still sb_mb)
0xa20caf4  ldr  x10,[x19,#0x88]  … 0xa20cb0c str x28,[x19,#0x98]   ; sb_lastrecord = m
0xa20cb34  ldur x1,[x29,#-0x60]            ; x1 = start
0xa20cb44  bl   0xfffffff00a1fe204         ; mptcp_validate_csum(tp, start, …)
0xa20cb50  cbnz w0, 0xa20cda4              ; bad csum → m was freed inside
0xa20cda4  str  xzr,[x20]; mov w20,#5      ; *mp0 = NULL; return MPTCP_ERROR_DFIN_CSUM
```

### 2.2 Binary-visible fix in 24B156 — observation

24B156 inserts a block at `0xfffffe000b0508fc–0xb050998` that has **no counterpart in 23F84**, gated on
`dfin ∧ m≠NULL ∧ dlen==0 ∧ mp_rlen==1` (corrected 2026-11-26 by `mptcp_fix_localization.md` §3.2; was read here as `dsn==1`):

```
0xb0508dc  and  w12, w23, #0x40000000      ; dfin
0xb0508fc  cbz  w12, → normal              ; no DFIN → old path
0xb050900  cbz  x28, → normal
0xb050904  cmp  w24, #0                    ; dlen == 0
0xb050908  ldur x9,[x29,#-0x88]            ; mp_rlen (16-bit, loaded at 0xb05087c ldrh [m,#0xac]; dsn is in [x29,#-0x90])
0xb05090c  ccmp w9, #1, #0, eq
0xb050910  b.ne → normal
0xb050938  bl   sbfree(&so->so_rcv, m)   ; (was read here as sb_lock)
0xb050960  str  x28,[x10]                  ; *mp = m  (m appended to the MPTCP-level *mp0 chain)
0xb050978  str  x13,[x19,#0x88]            ; so->so_rcv.sb_mb = m->m_next
0xb050980  str  xzr,[x9],#8                ; m->m_next = NULL       ← m unlinked from so_rcv
```

After that, the post-checksum failure handler is identical in both builds (`str xzr,[x20]; mov w20,#5`), i.e. the fix
is the *unlink before validate*, not a change to the checksum path. The OSS 27.0 tree (`xnu-12377.121.6`,
mptcp_subr.c:2347) still has the vulnerable shape, so the fix landed after the 27.0 OSS drop (inference:
closed-source 27.2.x / iOS 26.7.x backport).

### 2.3 Trigger — observation from source

1. Attacker server answers the MPTCP SYN with MP_CAPABLE carrying `MPCAP_CHECKSUM_CBIT`; client sets
   `MPTCPF_CHECKSUM` "even if it was not negotiated on the first SYN" (mptcp_opt.c:1066–1070).
2. Server sends a data segment whose DSS has `data_len = 1` and the DATA_FIN flag, with any checksum that
   does not fold to 0xffff (`mptcp_input_csum`, mptcp.c:1160–1190: with `real_len = dlen - dfin = 0` the
   pseudo-header alone decides, no payload needed).
3. Client: `dlen = 1 - 1 = 0` → dequeue loop skipped → `mptcp_validate_csum` frees `start` while it is still
   `so->so_rcv.sb_mb` / `sb_lastrecord`.
4. Outcome: double free when `so_rcv` is later flushed/closed (`m_free: freeing an already freed mbuf`), or
   write-after-free if another record is appended (`m->m_nextpkt == NULL` assertion / panic).

### 2.4 Inferences

- CVE-2026-86962 = this MPTCP bug: based only on the PoC repository name, the advisory's "double free" wording,
  the 26.7 fix window, and the 24B156 binary containing the guard. No Apple commit or advisory text names MPTCP.
- ~~The fix condition `dsn==1` (low 32 bits of `mp_dsn`) suggests Apple special-cased "DATA_FIN as the first mapping"~~ — **withdrawn 2026-11-26**: the condition is `mp_rlen==1` (`data_len=1` with DATA_FIN, i.e. the PoC's shape), not `dsn==1`. See `mptcp_fix_localization.md` §3.2, 4.2. That note also established that the block is absent in 26.6 (23G71) and 26.6.1 (23G83) and that the no-DATA_FIN `data_len=1` path dequeues the mbuf before `mptcp_validate_csum` in every build (so no freed-while-linked there).

---

## 3. Sandbox reachability — source observations

- `bsd/kern/uipc_socket.c:702` counts `PF_MULTIPATH`; `bsd/sys/socket_private.h:310` `#define PF_MULTIPATH AF_MULTIPATH` (41).
  `socreate()` itself has no privilege check for the domain (comment at uipc_socket.c:830–840: entitlements are
  only checked on explicit user requests).
- `mptcp_usrreq.c:222–262 mptcp_entitlement_check()`: returns 0 (allow) unless `svctype == MPTCP_SVCTYPE_AGGREGATE`
  and the caller lacks `PRIV_NET_RESTRICTED_MULTIPATH_EXTENDED` (priv.h:120) and `net.inet.mptcp.developer_mode`
  (default 0). It is called from `mptcp_connect` (:339) and from `MPTCP_SERVICE_TYPE` setsockopt (:1749).
- Default `mpte_svctype` is 0 = `MPTCP_SVCTYPE_HANDOVER` (`tcp_private.h:123 "Default 0"`), so a third-party
  app creating an MPTCP socket and connecting is allowed by the kernel's own check.
- **Seatbelt (sandbox) profile — not verified.** No compiled iOS container profile (`container.plist` /
  profile strings inside `com.apple.security.sandbox`) was decoded for this pass, so the claim that an
  unentitled third-party app's `(allow network*)` covers `AF_MULTIPATH` sockets is an **inference** from
  (a) the absence of any MPTCP/`AF_MULTIPATH` string in the OSS trees under `security/` (which contain only
  the MAC framework, not the sandbox profile compiler) and (b) the kernel-side check being solely
  `mptcp_entitlement_check`. Observed in the 23F84 `com.apple.security.sandbox` kext strings: the operation
  names `network-outbound` / `network-inbound` / `network-bind` and the entitlement string
  `com.apple.developer.networking.multipath_extended` (the extended-entitlement check referenced in
  `mptcp_entitlement_check`); the kext carries no compiled profiles. Open item: pull the 23F84 rootfs DMG and
  grep `/System/Library/Sandbox/Profiles/` (`container.plist`, `com.apple.WebContent.sb`, …) for `network` rules.

---

## 4. Caveats / open

1. Sandbox profile text for MPTCP sockets was not read from a 23F84 profile — kernel-side reachability is
   observed, Seatbelt-side is inferred (see §3 last bullet).
2. The public report claims the panics reproduce on two devices / two XNU generations with a rogue-AP
  (network-adjacent) model; that implies first-party MPTCP users (Safari/`nsurlsessiond`) can be driven by
   an attacker server without any app — not verified here, static only.
3. Candidates #2–#6 are not localised; #3–#5 have no public technical detail at all.
4. tcp_timer.c `so_usecount` fix is real in 26.6 but has no CVE attribution.

## 5. Reproduction of this analysis

```
cd /tmp/jbresearch/igmp
/tmp/jbresearch/venv/bin/python strs.py <kc> com.apple.kernel | grep mptcp_subflow_soreceive
/tmp/jbresearch/venv/bin/python /tmp/jbresearch/mptcp_loc.py <kc>
/tmp/jbresearch/venv/bin/python /tmp/jbresearch/mptcp_dis.py <23F84 kc> 0xfffffff00a20c3e4
/tmp/jbresearch/venv/bin/python /tmp/jbresearch/blnames.py <kc> 0xfffffff00a20c3e4   # callee names by strings
```
