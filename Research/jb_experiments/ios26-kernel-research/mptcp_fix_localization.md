# MPTCP `mptcp_subflow_soreceive`: where Apple fixed the DFIN/dlen==0 mbuf-lifetime bug (23F84 → 23G71 → 23G83 → 24B156)

Date: 2026-11-26. Method: static only, four decompressed kernelcaches for `iPhone14,5` (A15, `kernelcache.release.iPhone14,5` / `.iphone14`), capstone listings, no device, no server.

Question (задача B): in which release does the "unlink mbuf from `so_rcv` before `mptcp_validate_csum`" block first appear, what is its exact condition, and does it close the **no-DATA_FIN** variant (`data_len=1`, bad checksum, `DFIN=0`)? This decides whether 27.2.1 / 24B156 is still exposed.

Short verdict: the block appears first in **24B156 (iOS 27.2.1, xnu-13432.42.3)**; it is absent in 23F84 (26.5.2), 23G71 (26.6) and 23G83 (26.6.1). Its condition is `DFIN ∧ m≠NULL ∧ dlen==0 ∧ mp_rlen==1` — it covers **only** the DATA_FIN case. The no-DATA_FIN case (`mp_rlen=1, dlen=1`) never had the "still linked" problem in any of the four builds: the dequeue loop runs once and unlinks the mbuf before `validate_csum`. A second, no-DATA_FIN variant with `mp_rlen=0` (DSS with `data_len=0`, no FIN, bad csum) is **not** unlinked in any of the four builds including 24B156, but the OSS source does not appear to let such an mbuf reach `soreceive` ("Infinite Mapping" is rejected earlier) — `ГИПОТЕЗА` (low), see §4.3.

### Evidence basis (what was concluded from what)

| Conclusion | Basis |
|---|---|
| Function bounds, points (a)–(d), the 24B156 unlink block and its condition, mbuf fate for cases F / N1 / N0 in each build | **Binaries** of all four builds (23F84, 23G71, 23G83, 24B156), read per word (`tools/kdiff2/ins_iter.py`), cold tails included |
| `mptcp_validate_csum` unchanged across builds (only `tcpcb` offsets moved) | Binaries (normalised opcode diff of the four **full** 115-instruction listings: 4 / 0 / 24 changed lines, all offsets) |
| Names of the constructs the binary implements (`dlen = mp_rlen - dfin`, `sbfree`, `*mp = m`, `sb_lastrecord`, `MPTCP_SVCTYPE_*`, `PRIV_NET_RESTRICTED_MULTIPATH_EXTENDED` = 10010), line numbers | **Source `xnu-12377.121.6`** (the last public tag, 27.0 OSS) — used only as an orientation for the 12377.122.8 / .162.x binaries, which are newer. Not checked for line-by-line equivalence. |
| N0 (`mp_rlen=0 ∧ DFIN=0`) looks unreachable from the network | Source `xnu-12377.121.6` only (`mptcp_update_rcv_state_meat` "Infinite Mapping" branch). The DSS parser of the binaries was not disassembled → `ГИПОТЕЗА` |
| Binary-vs-source divergence (no unlink block in the 12377.121.6 source, block present in 13432.42.3 binary) | Both: binary 24B156 + source 12377.121.6 |
| `xnu-11417.*` trees (iOS 18.x) | **Not used for any conclusion** in this note. No 26.6 / 27.x source tag exists publicly, so nothing here is derived from source for 23G71 / 23G83 / 24B156 |

### Decoding-method check (raised by thread `thr_sxdgwvv7fc`)

`capstone.md.disasm()` on a buffer stops at the first undecodable word, which can silently truncate a listing, and `dump.py` additionally stops at the first `ret`. Both effects were measured with `wordcheck.py` (per-word decode via `tools/kdiff2/ins_iter.py` compared with the listing) and then removed by re-reading every function per word up to the next function's `pacibsp` (`fnfull.py`, `tailfull.py`):

| Function | Undecodable words (4 builds) | Listing vs per-word mismatches | Instructions cut off by `dump.py` | What the cut-off part is | Effect on conclusions |
|---|---|---|---|---|---|
| `mptcp_subflow_soreceive` ×4 | 0 | 0 | 89 / 87 / 87 / 89 (cold tail, `*_tail.dis`) | log calls, `brk #0x5519` panic paths, final log; **no write to `sb_mb` / `sb_mbtail` / `sb_lastrecord`**; branches back into warm code: 23F84 2, 23G71 1, 23G83 1, 24B156 1, all into the `release:` path | none |
| `mptcp_validate_csum` ×4 | 0 | 0 | 35 in every build | **the checksum-failure handler** (`TMPF_SND_MPFAIL`, `soevent(0x10001)`, `m_free` loop, counter, `return -1`) | the first version of the listing missed it and "`m_freem` on failure" was then taken from the source; now confirmed in the binary: 23F84 `0xa1fe394 cbz x0; 0xa1fe398 bl 0xa36468c; 0xa1fe39c cbnz x0`, `x0 = x19` = the `m` argument, callee starts with `ldrh w8,[x0,#0x1c]` (`m_type`) = `m_free`; 24B156 `0xb0422b8–0xb0422c0`, callee `0xb1b2ed4`. `mptcp_validate_csum_*.dis` are now the full 115-instruction versions |
| `mptcp_entitlement_check` 23F84 | 0 | 0 | 25 | delegated-credential branch `0xa20fabc–0xa20fad0`, `MPTE_FIRSTPARTY |= 4` | none; listing replaced by the full 115-instruction version |

Complete inventory of `sb_mb` / `sb_mbtail` / `sb_lastrecord` writes through `x19` in the whole `mptcp_subflow_soreceive` (warm + tail): 23F84 9, 23G71 9, 23G83 9, 24B156 10 — the extra one in 24B156 is `0xb050978 str x13,[x19,#0x88]`, i.e. the fix block itself.

`check_fix.py` was switched to the same per-word full-function decode; its output (whole-function instruction counts 741 / 759 / 759 / 795) reproduces the §3.1 table unchanged (`mptcp_fix_check.out`).


---

## 1. Inputs (verified by me)

| Build | iOS | Kernel (`Darwin Kernel Version` string in the image) | File | sha256 |
|---|---|---|---|---|
| 23F84 | 26.5.2 | `25.5.0 … xnu-12377.122.8~1/RELEASE_ARM64_T8110` (Jun 9 2026) | `/tmp/jbresearch/ipsw/x13/kc.decomp/kernelcache.release.iphone14.decompressed` | (existing, not re-hashed) |
| **23G71** | **26.6** | `25.6.0 Sat Jul 11 15:47:24 PDT 2026; root:xnu-12377.162.13~2/RELEASE_ARM64_T8110` | `/tmp/jbresearch/ipsw/266/23G71__iPhone14,5/kernelcache.release.iPhone14,5` | `8191f666b831d50c66398cd421674b11d7f0359cc066cb9a6d7e2a121d3711b6` |
| **23G83** | **26.6.1** | `25.6.0 Thu Jul 30 12:45:21 PDT 2026; root:xnu-12377.162.14~4/RELEASE_ARM64_T8110` | `/tmp/jbresearch/ipsw/2661/23G83__iPhone14,5/kernelcache.release.iPhone14,5` | `9ac398429284f24477d41a441928028788cf2f9617dbcb05e55c003a8ea99f30` |
| 24B156 | 27.2.1 | `27.2.0 Tue Oct 13 21:26:58 PDT 2026; root:xnu-13432.42.3~28/RELEASE_ARM64_T8150` | `/tmp/jbresearch/ipsw/x17/kc.decomp/kernelcache.release.v54.decompressed` | (existing, not re-hashed) |

Download: `ipsw download ipsw --device iPhone14,5 --version 26.6 --kernel --confirm -o /tmp/jbresearch/ipsw/266` (same for `26.6.1` → `/tmp/jbresearch/ipsw/2661`). `--urls` first confirmed the picks: `iPhone14,5_26.6_23G71_Restore.ipsw`, `iPhone14,5_26.6.1_23G83_Restore.ipsw`. Both decrypted and LZFSE-decompressed with cached keys; the "AEA-encrypted" problem from the report did not occur for 26.6 / 26.6.1 (first attempt failed once with `unexpected EOF` on the remote zip, second succeeded). Only the kernelcache was fetched (~60 MB each); no full IPSW.

Note: the 23G83 kernel for `iPhone14,5` is the same A15 family as the iPhone 13 (`iPhone14,5` is iPhone 13, `T8110` in the version string), so the addresses below apply to the owner's iPhone 13 on 26.6.1.

XNU source used for correspondence: `/tmp/jbresearch/igmp/xnu/full/xnu-12377.121.6/bsd/netinet/mptcp_subr.c` (lines 2013–2360), `mptcp.c` (1128–1222), `mptcp_usrreq.c` (222–262, 300–345, 1742–1762), `tcp_private.h` (119–126). `xnu-11417.101.15` / `xnu-11417.140.69` are **iOS 18.x** trees (kernel 11417) and were **not used** for any conclusion here; the 12377 tree is the nearest public orientation for 23F84 (`xnu-12377.122.8`) and was used only to name the source constructs the binary implements — it is one minor version older than 23F84 and does not contain the 26.6.x or 27.x changes, which is why the 13432 binary was read on its own and every cross-build statement below is made on binaries.

Artifacts (in this repo):
- Listings: `mptcp_subflow_soreceive_{23F84,23G71,23G83,24B156}.dis` (warm part, up to the first `retab`) and `mptcp_subflow_soreceive_{…}_tail.dis` (cold tail after the first `retab`, up to the next function's `pacibsp`), `mptcp_validate_csum_{…}.dis`, `mptcp_entitlement_check_23F84.dis`, `mptcp_fix_check.out` (this directory). My 23F84 and 24B156 `soreceive` listings are instruction-for-instruction identical to the pre-existing `/tmp/jbresearch/mptcp_chk/x13_soreceive.dis` / `x17_soreceive.dis` (verified by diff after whitespace normalisation), so the earlier addresses are confirmed rather than inherited.
- Tools: `Research/jb_experiments/tools/mptcp_fix/` (self-contained: `kdiff.py` copied next to them; do **not** add `tools/` itself to `sys.path`, its `dis.py` shadows the stdlib module capstone needs) — `loc4.py` (locate the function by anchor strings, all builds), `dump.py` (capstone range dump; same as `/tmp/jbresearch/mptcp_chk/dump.py`; stops at the first `ret`), `findcallee.py` (list `bl` targets + callee prologues), `callers.py` (find all `bl/b` to a target), `check_fix.py` (re-derives the §3.1 table from the four kernelcaches and asserts the failure-handler shape; its output is `mptcp_fix_check.out`), `wordcheck.py` (per-word decode of the function range via `tools/kdiff2/ins_iter.py` and comparison with a `.dis` listing: undecodable words, mismatches, instructions after the last listed), `fnfull.py` (per-word listing of a whole function up to the next function's `pacibsp`, no stop at `ret`), `tail.py` / `tailfull.py` (per-word listing of the cold tail without stopping at `ret`; `tailfull.py` flags writes to `so_rcv.sb_mb/sb_mbtail/sb_lastrecord` and stops at the second `retab`). Run with `/tmp/jbresearch/venv/bin/python`.

---

## 2. Function localisation (my run of `loc4.py`)

`mptcp_subflow_soreceive` is the unique function containing xrefs to `"mptcp_subflow_soreceive 1"`, `"… 2"`, `"m->m_nextpkt == NULL"`, `"mptcp_subflow_soreceive"` (the `"No DSS on secondary subflow"` / `"without DSS-mapping"` strings are referenced from it as well but were not needed as anchors — `"No DSS…"` xref resolves to this function in every build).

| Build | `mptcp_subflow_soreceive` start | warm part (up to first `retab`) | real end (last `bl` before the next `pacibsp`) | instructions (warm + cold tail) | `mptcp_validate_csum` | `mptcp_entitlement_check` |
|---|---|---|---|---|---|---|
| 23F84 | `0xfffffff00a20c3e4` | `0xfffffff00a20ce10` | `0xfffffff00a20cf74` | 652 + 89 | `0xfffffff00a1fe204` | `0xfffffff00a20f954` |
| 23G71 | `0xfffffff00a21a350` | `0xfffffff00a21adcc` | `0xfffffff00a21af28` | 672 + 87 | `0xfffffff00a20c170` | not localised |
| 23G83 | `0xfffffff00a21a63c` | `0xfffffff00a21b0b8` | `0xfffffff00a21b214` | 672 + 87 | `0xfffffff00a20c45c` | not localised |
| 24B156 | `0xfffffe000b0505c8` | `0xfffffe000b0510cc` | `0xfffffe000b051230` | 706 + 89 | `0xfffffe000b042128` | `0xfffffe000b053c74` |

`mptcp_validate_csum` was identified by its own structure (sum of `m_pkthdr.len` over the chain, `rev/rev16` pseudo-header fold, `cmp w9,#0xffff`, on failure `t_mpflags |= 0x200000` (`TMPF_SND_MPFAIL`), `soevent(0x10001)`, `m_free` loop, `tcpstat++`, `return -1`). The failure handler is **after the first `retab`**, in the cold part of the function (23F84 `0xa1fe344–0xa1fe3cc`; 115 instructions in every build, see the decoding-method table above). Normalised opcode diff of the **full** listings across the four builds: 23F84→23G71 **4** changed lines (two log-string offsets), 23G71→23G83 **0**, 23G83→24B156 **24** lines, all of them struct offsets (`tcpcb` `[x0,#0x3c0]→[x0,#0x410]`, `t_mpflags` `#0x3b4→#0x404`, socket `[x8,#0x58]→[x8,#0xa8]`, counter `#0xc10→#0xc8`) and log-string offsets. The checksum function and its `m_freem(m)` on failure are therefore unchanged in all four builds; whatever changed, changed in the caller.

---

## 3. The four points (a)–(d) per build

Register roles (from the 24B156 listing; other builds use different register numbers but the same values):

- `x19` = `so`, `x20` = `mp0` (`struct mbuf **`), `[x19,#0x88]` = `so->so_rcv.sb_mb`, `[x19,#0x90]` = `sb_mbtail`, `[x19,#0x98]` = `sb_lastrecord`, `[x19,#0x70]` = `so->so_rcv.sb_cc`.
- mbuf: `[m]` = `m_next`, `[m,#8]` = `m_nextpkt`, `[m,#0x18]` = `m_len`, `[m,#0x1e]` = `m_flags` (bit 1 = `M_PKTHDR`), `[m,#0x60]` = `m_pkthdr.len`, `[m,#0x74]` = `pkt_flags`, `[m,#0xa0]` = `mp_dsn`, `[m,#0xa8]` = `mp_rseq`, `[m,#0xac]` = `mp_rlen`, `[m,#0xae]` = `mp_csum`.
- `PKTF_MPTCP_DFIN` = `0x40000000` (`and wX, wY, #0x40000000`), `PKTF_MPTCP` = bit 11 (`tbnz w,#0xb`).

### 3.1 Build table

| Build | (a) `dlen` computed | (b) `dlen==0` branch | **unlink block?** | (c) `bl mptcp_validate_csum` | (d) failure handler |
|---|---|---|---|---|---|
| 23F84 (26.5.2) | `0xa20c700` `and w10,w26,#0x40000000`; `0xa20c70c` `add w24,w25,w10,asr #31` → `dlen = mp_rlen − dfin` | `0xa20c710 cmp w9,w24; b.lt` (sb_cc<dlen → EWOULDBLOCK); `0xa20c740 cmp w24,#1; b.lt 0xa20c974` | **no** | `0xa20cb44 bl 0xa1fe204` (x1=`start`=`[x29,#-0x60]`) | `0xa20cb50 cbnz w0 → 0xa20cda4`: `str xzr,[x20]` (`*mp0=NULL`), `mov w20,#5` (EIO) |
| 23G71 (26.6) | `0xa21a660 and w10,w25,#0x40000000`; `0xa21a66c add w23,w24,w10,asr #31` | `0xa21a670 cmp w9,w23; b.lt`; `0xa21a6a8 cmp w23,#1; b.lt 0xa21a8f8` | **no** | `0xa21aaf0 bl 0xa20c170` (x1=`x28`=`start`) | `0xa21aaf4 cbnz w0 → 0xa21ad54`: same |
| 23G83 (26.6.1) | `0xa21a94c and w10,w25,#0x40000000`; `0xa21a958 add w23,w24,w10,asr #31` | `0xa21a95c cmp w9,w23; b.lt`; `0xa21a994 cmp w23,#1; b.lt 0xa21abe4` | **no** | `0xa21addc bl 0xa20c45c` (x1=`x28`=`start`) | `0xa21ade0 cbnz w0 → 0xa21b040`: same |
| 24B156 (27.2.1) | `0xb0508dc and w12,w23,#0x40000000`; `0xb0508e8 add w24,w11,w10,asr #31` | `0xb0508ec cmp w9,w24; b.lt`; `0xb0509d0 cmp w24,#1; b.lt 0xb050c18` | **yes** `0xb0508fc–0xb050998` | `0xb050e0c bl 0xb042128` (x1=`x28`=`start`) | `0xb050e10 cbnz w0 → 0xb051054`: same |

In 23F84 / 23G71 / 23G83 the instruction right after the `sb_cc < dlen` check is the spilling of locals (`str w27,[sp,#0x64]` / `str w26,[sp,#0x74]`) and the `dlen==0 → skip loop` test; there is no test of the DFIN flag between those points. The only consumer of `PKTF_MPTCP_DFIN` before `validate_csum` is the `dlen` arithmetic itself.

### 3.2 The 24B156 block, decoded

```
0xfffffe000b0508dc  and  w12, w23, #0x40000000          ; w12 = dfin = !!(pkt_flags & PKTF_MPTCP_DFIN)
0xfffffe000b0508e0  lsl  w10, w12, #1
0xfffffe000b0508e4  ldur x11, [x29, #-0x88]             ; x11 = orig_dlen = mp_rlen  (stored at 0xb050880 from ldrh [m,#0xac])
0xfffffe000b0508e8  add  w24, w11, w10, asr #31         ; w24 = dlen = mp_rlen - dfin
0xfffffe000b0508ec  cmp  w9, w24                        ; w9 = sb_cc
0xfffffe000b0508f0  b.lt → 0xb050f60                    ; sb_cc < dlen → EWOULDBLOCK
0xfffffe000b0508f4  str  w25, [sp, #0x74]               ; csum
0xfffffe000b0508f8  str  w12, [sp, #0x94]               ; dfin
0xfffffe000b0508fc  cbz  w12, 0xb050998                 ; (1) dfin == 0 → skip block
0xfffffe000b050900  cbz  x28, 0xb050998                 ; (2) m == NULL → skip block
0xfffffe000b050904  cmp  w24, #0                        ; (3) dlen == 0 ?
0xfffffe000b050908  ldur x9,  [x29, #-0x88]             ;     orig_dlen (= mp_rlen)
0xfffffe000b05090c  ccmp w9, #1, #0, eq                 ;     if dlen==0: compare orig_dlen with 1
0xfffffe000b050910  b.ne 0xb050998                      ;     not (dlen==0 && orig_dlen==1) → skip block
   ; ---- taken only for: DFIN ∧ m≠NULL ∧ dlen==0 ∧ mp_rlen==1 ----
0xfffffe000b050914  ldur x8, [x29, #-0x78]              ; SBLASTRECORDCHK-style range check on m
0xfffffe000b050918  cmp  x28, x8 ; 0xb050920 ldur x8,[x29,#-0x80]; cmp x28,x8
0xfffffe000b05091c  b.hs → 0xb0511b4 ; 0xb050928 b.lo → 0xb0511b4   ; (out of range → panic path, same as everywhere)
0xfffffe000b05092c  add  x0, x19, #0x70                 ; &so->so_rcv
0xfffffe000b050930  mov  x1, x28                        ; m
0xfffffe000b050934  mov  x21, x14                       ; x21 = mp (pointer-to-pointer into the mptcp chain)
0xfffffe000b050938  bl   0xb1ce2b8                      ; sbfree(&so->so_rcv, m)   [callee: sb_cc -= m_len / 0x200, sb_mbcnt -= ..., same callee as in the dequeue loop at 0xb050b70]
0xfffffe000b05093c  cbz  x21, 0xb0509a4                 ; mp == NULL → only sbfree, no relink
0xfffffe000b050940  mov  x10, x21
0xfffffe000b050960  str  x28, [x10]                     ; *mp = m
0xfffffe000b050974  ldr  x13, [x28]                     ; x13 = m->m_next
0xfffffe000b050978  str  x13, [x19, #0x88]              ; so->so_rcv.sb_mb = m->m_next        ← m unlinked from the socket buffer
0xfffffe000b05097c  mov  x9, x28
0xfffffe000b050980  str  xzr, [x9], #8                  ; m->m_next = NULL ; mp = &m->m_next
0xfffffe000b050984  stp  x28, x9, [x29, #-0x70]         ; (local "mp0 / mp" pair = m, &m->m_next)
0xfffffe000b050988  add  x21, x13, #0x200 ; 0xb050990 mov x25, x13 ; 0xb050994 b 0xb0509b4
0xfffffe000b050998  ldp  x13, x21, [x29, #-0x80] ; mov x25, x28 ; b 0xb0509b4   ; skip path: m unchanged
```

This is exactly the body of the inner `while (dlen > 0)` loop from the source (`sbfree; *mp = m; mp = &m->m_next; so->so_rcv.sb_mb = m = m->m_next; *mp = NULL`), hoisted in front of the `cmp w24,#1 / b.lt` test so that it also runs when `dlen` is already 0 — but only under `dfin ∧ mp_rlen==1`. After the block, `x25` (= loop `m`) is `m->m_next`, `dlen` stays 0, the loop is skipped, and `validate_csum` is called with `start` = the now-unlinked mbuf (`x28`). On checksum failure `m_freem(start)` frees an mbuf that is no longer on `so_rcv` (it is on the MPTCP-level `*mp0` chain, which the failure handler then discards via `*mp0 = NULL` — `0xb051054 str xzr,[x20]`).

Source correspondence: `mptcp_subr.c` in `xnu-12377.121.6` (27.0 OSS) has **no** such block (lines 2279–2288 go straight from `if ((int)so->so_rcv.sb_cc < dlen)` to `off = 0; while (dlen > 0)`; re-verified by grep on 2026-11-26), confirming the task statement that the fix did not land in the 27.0 OSS drop. The binary and the OSS tree diverge here; I did not try to force them to match.

Correction to the previous note (`kernel_candidates_26.6_to_27.md` lines 82–92, 119): that note reads the condition as `dfin ∧ dlen==0 ∧ dsn==1`, `0xb050908 ldur x9,[x29,#-0x88]` as `dsn`, and `0xb050938 bl` as `sb_lock`. All three readings are wrong: `[x29,#-0x88]` is written only at `0xb050880 stur x10,[x29,#-0x88]` from `0xb05087c ldrh w10,[x9,#0xac]`, i.e. the 16-bit `mp_rlen` (`dsn` is the 64-bit `[m,#0xa0]`, stored to `[x29,#-0x90]`), and the callee at `0xb1ce2b8` has the `sbfree` body (first instructions `ldrh w8,[x1,#0x1e]; tbnz …; ldr w8,[x20,#0x30]; add w8,w8,#0x200; ldr w9,[x20,#0x18]; ldr w10,[x19]; sub w9,w10,w9; str w9,[x19]`), and is the same callee as the loop's `sbfree` at `0xb050b70`. So the condition is `mp_rlen==1`, not `dsn==1`, and the operation is `sbfree`, not a lock.

### 3.3 Where the block would be in the other builds

| Build | `cmp dlen,#1 / b.lt` (loop skip) | bytes between `b.lt sb_cc` and that `cmp` | DFIN re-tested in between? |
|---|---|---|---|
| 23F84 | `0xa20c740 cmp w24,#1; 0xa20c744 b.lt 0xa20c974` | `0xa20c718–0xa20c73c` (10 ins: spills, `dlen` range `[x29,#-0x90]+mp_rlen−1`) | no |
| 23G71 | `0xa21a6a8 cmp w23,#1; 0xa21a6ac b.lt 0xa21a8f8` | `0xa21a678–0xa21a6a4` (11 ins) | no |
| 23G83 | `0xa21a994 cmp w23,#1; 0xa21a998 b.lt 0xa21abe4` | `0xa21a964–0xa21a990` (11 ins) | no |
| 24B156 | `0xb0509d0 cmp w24,#1; 0xb0509d4 b.lt 0xb050c18` | `0xb0508f4–0xb0509cc` (62 ins incl. the 38-ins block) | **yes** (`0xb0508fc cbz w12`) |

The 20-instruction growth 23F84→23G71 (652→672) and the identical size of 23G71 and 23G83 are not an MPTCP fix: `grep 0x40000000` finds exactly one DFIN test per build in the `soreceive` listing (line 200 / 197 / 197 / 198), and in the first three builds it is only the `dlen` arithmetic. What the 20 extra instructions of 23G71 are (stack frame grew from `0x140` to `0x150`, shifted `tcpcb` offsets and changed log strings are visible; the rest was not attributed) is outside this task.

---

## 4. Fate of the mbuf without DATA_FIN — per build

Two distinct "no DATA_FIN" inputs have to be separated, because the task text says "`data_len=1` … без FIN" but also "`dlen==0`":

- **Case N1** — `DFIN=0, mp_rlen=1` (DSS `data_len=1`, one payload byte, bad checksum). `dlen = 1 − 0 = 1`. This is the report's Experiment 4 / 5 (`chain_deref`, "bad-checksum DSS *without* DATA_FIN").
- **Case N0** — `DFIN=0, mp_rlen=0` (DSS with `data_len=0`, no FIN, bad checksum, no payload). `dlen = 0`. This is the only way to reach `dlen==0` without DATA_FIN.

### 4.1 Case N1 (`mp_rlen=1`, `dlen=1`) — all four builds

```
23F84:  0xa20c744 b.lt not taken (dlen=1)  → loop head 0xa20c748  (x28 = m = start = sb_mb)
        0xa20c75c ldr w8,[x28,#0x60]; cbz → 0xa20c8a8        ; m_pkthdr.len != 0 → skip the adj_rmap split
        0xa20c8a8 … range checks …
        0xa20c8d0 add x0,x19,#0x70 ; x1,x28 ; 0xa20c8d8 bl sbfree(&so->so_rcv, m)
        0xa20c8dc cbz x23 → (mp==NULL) ; taken path:
        0xa20c8fc str x28,[x23]                 ; *mp = m
        0xa20c900 ldr x14,[x28]                 ; m_next
        0xa20c904 str x14,[x19,#0x88]           ; so_rcv.sb_mb = m->m_next       ← unlinked
        0xa20c90c str xzr,[x9],#8               ; m->m_next = NULL
        0xa20c930 add w27,w25,w27 ; sub w24,w24,w25 → dlen = 0 ; 0xa20c938 cbz w24 → exit loop
        0xa20cad8 mov w9,#0 ; … 0xa20cb0c str x28,[x19,#0x98]  ; sb_lastrecord = m (= m_next of the dequeued mbuf, or SB_EMPTY_FIXUP)
        0xa20cb34 ldur x1,[x29,#-0x60]          ; start  (≠ current m)
        0xa20cb44 bl mptcp_validate_csum        ; m_freem(start) on bad csum — start is NOT on so_rcv
23G71:  0xa21a6ac b.lt not taken → 0xa21a6b0 ; sbfree 0xa21a850 bl ; 0xa21a874 str x25,[x22] (*mp=m) ; 0xa21a87c str x13,[x19,#0x88] (sb_mb=m->m_next) ; 0xa21a884 str xzr,[x9],#8 ; dlen 0xa21a8b0 ; sb_lastrecord 0xa21a5a4 / 0xa21aaa4 ; validate 0xa21aaf0 (x1=x28=start)
23G83:  0xa21a998 b.lt not taken → 0xa21a99c ; sbfree (same offsets +0x2ec) ; sb_mb ← m->m_next ; validate 0xa21addc (x1=x28=start)
24B156:  0xb0509d4 b.lt not taken → 0xb0509d8 ; block at 0xb0508fc NOT taken (dfin==0) ; sbfree 0xb050b70 bl ; 0xb050b94 str x25,[x22] ; 0xb050b9c str x13,[x19,#0x88] ; 0xb050ba4 str xzr,[x9],#8 ; 0xb050bd4 cbz w24 → 0xb0509d0 → dlen<1 → 0xb050c18 ; sb_lastrecord 0xb050dc0 ; validate 0xb050e0c (x1=x28=start)
```

Reading: in **all four** builds, for `mp_rlen=1 ∧ dlen=1`, the inner dequeue loop runs exactly once **before** `mptcp_validate_csum`. `sbfree` is called, `so->so_rcv.sb_mb` is advanced to `m->m_next`, `m->m_next` is zeroed, and `m` is appended to the `*mp0` chain (`*mp = m; mp = &m->m_next`). `sb_lastrecord` is then set to the **new** `m` (`m->m_next`, or `SB_EMPTY_FIXUP` zeros `[x19,#0x90]`/`[x19,#0x98]` when it is NULL). When `validate_csum(start)` then fails and calls `m_freem(start)`, `start` is the dequeued mbuf — no longer reachable from `so_rcv.sb_mb`, `sb_mbtail` or `sb_lastrecord`. The caller's failure handler sets `*mp0 = NULL` and returns `EIO`, so nothing upstream dereferences the freed chain. **No "freed while linked on so_rcv" in this case, in any build, including 23F84.**

What this means for the report's Experiments 4/5: the `MP_FAIL` + "1400 bytes accepted in fallback" pcap pattern they observe is consistent with the normal bad-checksum → `TMPF_SND_MPFAIL` + `m_freem(start)` + `EIO` path; it does **not** by itself demonstrate a write-after-free, because on that path the freed mbuf is not on `so_rcv` (`sbappend` in fallback mode writes `sb_lastrecord->m_nextpkt`, and `sb_lastrecord` here is the *next* record, not `start`). Their claim of a silent WAF on the non-DATA_FIN path is therefore **not supported by the binary** for `mp_rlen=1`. This is a conclusion from the listings, not a device observation.

### 4.2 Case F (`DFIN=1, mp_rlen=1`) — the patched case

| Build | dequeue loop | `sb_mb` at `validate_csum` | `sb_lastrecord` at `validate_csum` | mbuf freed by `validate_csum` |
|---|---|---|---|---|
| 23F84 | skipped (`dlen=0`, `0xa20c744 b.lt 0xa20c974`) | `== start` (unchanged) | `== start` (`0xa20cb0c str x28,[x19,#0x98]`, `x28` still `sb_mb`) | `start`, **still linked** → Bug 1 |
| 23G71 | skipped (`0xa21a6ac b.lt 0xa21a8f8`) | `== start` | `== start` (`0xa21a5a4` / `0xa21aaa4`) | **still linked** |
| 23G83 | skipped (`0xa21a998 b.lt 0xa21abe4`) | `== start` | `== start` (`0xa21ad90`) | **still linked** |
| 24B156 | block `0xb0508fc` taken: `sbfree`, `sb_mb = start->m_next`, `start->m_next = NULL` (`0xb050978/0xb050980`) | `start->m_next` | `start->m_next` (`0xb050dc0`, or `SB_EMPTY_FIXUP`) | `start`, **unlinked** → safe |

So the first build in which the DATA_FIN trigger no longer frees a linked mbuf is **24B156**. 26.6 and 26.6.1 are as vulnerable as 26.5.2 for this case.

Bug 2 of the report (infinite loop when checksums are off) — side observation from the same listings, not executed: `mptcp_validate_csum` returns 0 without freeing when `MPTCPF_CHECKSUM` is clear (`[x0,#0x3c0]` NULL / bit 0 clear / `t_mpflags` bit 16 set → `0xa1fe32c mov w0,#0`), after which the outer `while (m != NULL)` continues with the current `m`. In 23F84 / 23G71 / 23G83 the DATA_FIN path never advances `m` (loop skipped), so the loop re-runs on the same mbuf — the Bug 2 shape. In 24B156 the unlink block runs *before* `validate_csum` and is gated only on `dfin ∧ mp_rlen==1 ∧ dlen==0`, not on the checksum result, so on that path `m` becomes `start->m_next` (`0xb050e48 mov x28,x27; 0xb050e58 mov x28,x25`, `x25` = `start->m_next` from `0xb050990`) and the loop does not spin on the same mbuf. This says nothing about other `dlen==0` shapes (e.g. `mp_rlen=0 ∧ DFIN=0`, §4.3) where `m` still does not advance in 24B156. Whether 26.6.x changed Bug 2 elsewhere (e.g. in `mptcp_handle_input`) was not checked.

### 4.3 Case N0 (`DFIN=0, mp_rlen=0`, `dlen==0`) — unpatched in all four builds

Path (24B156 addresses; 23F84 `0xa20c974–0xa20cb44`, 23G71 `0xa21a8f8–0xa21aaf0`, 23G83 `0xa21abe4–0xa21addc` are structurally identical):

```
0xb0508fc  cbz w12 → 0xb050998           ; dfin==0 → the unlink block is skipped
0xb0509d0  cmp w24,#1 ; 0xb0509d4 b.lt 0xb050c18   ; dlen==0 → skip dequeue loop
0xb050c18  cbz w24 → 0xb050d8c
0xb050d90  cbz x25 → …                    ; m (= start = sb_mb) is not NULL
0xb050dc0  str x25,[x19,#0x98]            ; sb_lastrecord = m          (m unchanged!)
0xb050dd0  cbz x28 → … (range checks, pass)
0xb050df8  mov x1,x28                     ; start == m == so_rcv.sb_mb
0xb050e0c  bl mptcp_validate_csum
   inside: real_len = dlen - dfin = 0 ; m_length2(m)=0 < 0? no ; sum = pseudo-header only ; ≠0xffff →
           t_mpflags |= TMPF_SND_MPFAIL ; m_freem(start) ; return -1
0xb050e10  cbnz w0 → 0xb051054            ; *mp0=NULL; EIO  — so_rcv.sb_mb and sb_lastrecord still point at the freed mbuf
```

In this case `m` is never dequeued in any build, including 24B156, and `validate_csum` receives the live head of `so_rcv`; after the failure handler returns `EIO`, the outer loop is not re-entered (`0xb051054 → 0xb0510a0 sbunlock; retab`), so this is a Bug 1 shape (freed-while-linked), not a Bug 2 shape. The `mp==NULL` arm of the 24B156 block (`0xb05093c cbz x21 → 0xb0509a4`: `sbfree` only, `x25 = x28`, no unlink) is the compiler's check of the `mp0` argument (`mp = mp0` at source line 2021 is never reassigned to NULL, only to `&m->m_next`), so it is not reachable with `mp0 != NULL` — not a second hole.

Reachability of N0 from the network (source reading of `xnu-12377.121.6`, not the binary, and only the paths below were traced): `mp_rlen` of a queued mbuf is `mpts_rcv_map.mpt_len` (`mptcp_insert_rmap`, `mptcp_subr.c:5644`), and `mptcp_update_rcv_state_meat` (`mptcp.c:1134–1144`) refuses to store a map when `mdss_data_len == 0` ("Infinite Mapping" → `mptcp_notify_mpfail`, `return`). The other `mp_rlen = 0` writes are the zero-length DATA_FIN case (`tcp_input.c:6160–6166`, requires `PKTF_MPTCP_DFIN`), sender-side bookkeeping (`mptcp_subr.c:3336`, `1977`) and trims (`mptcp.c:591`, `mptcp_preproc_sbdrop`), none of which produces `PKTF_MPTCP ∧ DFIN=0 ∧ mp_rlen=0` on a freshly mapped mbuf. So in this source tree N0 does not look reachable; because the binaries are newer than the OSS tree and the DSS parser in 24B156 was not disassembled, this stays a **`ГИПОТЕЗА`** (low likelihood), not a closed item. If it is deliverable, 24B156 remains exposed to the same `m_freem`-on-linked-mbuf primitive via a different DSS shape.

---

## 5. Entitlement for `socket(AF_MULTIPATH)` + `connectx` (item 6)

Source (`xnu-12377.121.6`):

- `mptcp_usrreq.c:222–262 mptcp_entitlement_check(mp_so, svctype)`: returns 0 immediately if `mptcp_no_first_party` (sysctl, default 0); returns 0 if `soopt_cred_check(PRIV_NET_RESTRICTED_MULTIPATH_EXTENDED)` passes (with or without delegation); returns 0 if `svctype == MPTCP_SVCTYPE_AGGREGATE && mptcp_developer_mode`; **returns −1 only when `svctype == MPTCP_SVCTYPE_AGGREGATE`** (value 2, `tcp_private.h:125`) and neither condition holds. For every other svctype it returns 0.
- Called from `mptcp_connect` (`mptcp_usrreq.c:338–345`, only if `!(mpte_flags & MPTE_SVCTYPE_CHECKED)`) and from the `MPTCP_SERVICE_TYPE` (`0x213`) setsockopt (`:1749–1760`). `mpte_svctype` defaults to 0 = `MPTCP_SVCTYPE_HANDOVER` (`tcp_private.h:123 "Default 0"`); nothing in `mptcp_attach` sets it to AGGREGATE.
- So the kernel-side gate does not require an entitlement for a plain `socket(PF_MULTIPATH, SOCK_STREAM, IPPROTO_TCP)` + `connectx()`: a third-party app without `com.apple.private.network.multipath` (or whatever the extended entitlement is called) is allowed unless it asks for `MPTCP_SERVICE_TYPE = 2`. Whether a seatbelt profile on iOS allows `AF_MULTIPATH` for a third-party app is a separate question that was not verified here (see the previous note §3).

Binary confirmation in 23F84: `mptcp_entitlement_check` = `0xfffffff00a20f954` (string `"mptcp_entitlement_check"` at `0xfffffff00707cbd2`, xref `0xa20fa8c`). Structure matches the source exactly:

```
0xa20f96c ldr w8,[x0,#8] ; cmp w8,#0x27 (=39=AF_MULTIPATH) ; b.ne 0xa20fb08 (panic path)
0xa20f978 adrp/ldr [0xa932000+0xa10] → mptcp_no_first_party ; nonzero → return 0
0xa20f99c mov w1,#0x271a (=10010 = PRIV_NET_RESTRICTED_MULTIPATH_EXTENDED) ; mov w2,#1 ; mov w3,#0 ; 0xa20f9a8 bl 0xa378b9c (soopt_cred_check, no delegation)
0xa20f9ac cbz w0 → 0xa20fad8 : success → mpte->mpte_flags |= 4 (MPTE_FIRSTPARTY) ; return 0
0xa20f9b0 ldrb w8,[x19,#0x233] (so_flags bit 4 = SOF_DELEGATED) ; ldr x19,[x19,#0x208] (so_cred) ; 0xa20f9cc bl 0xa602a34 (kauth cred priv check, priv 0x271a) ; cbz w0 → 0xa20fabc (cold tail: cr_label check, 0xa602c5c, then |= MPTE_FIRSTPARTY ; return 0)
0xa20f9d8 cmp w21,#2 (MPTCP_SVCTYPE_AGGREGATE) ; b.ne → return 0
0xa20f9e0 ldr [0xa932000+0xa0c] → mptcp_developer_mode ; nonzero → return 0
0xa20fa84 … os_log_error("mptcp_entitlement_check - %lx: MPTCP prohibited on svc %u")
0xa20fab4 mov w0,#-1
```

Both `soopt_cred_check` success paths end at `0xa20fad4 mov w0,#0 ; 0xa20fad8 ldrh w8,[x20,#0xe8] ; orr w8,w8,#4 ; strh` (flag set, then the epilogue at `0xa20fae4`), which is the `mpte_flags |= MPTE_FIRSTPARTY` of the source; the cold part after `retab` (`0xa20fabc–0xa20fb1c`) holds exactly that delegated-credential branch and a `panic`-style call. The whole function is 115 instructions; the control flow matches `mptcp_usrreq.c:222–262` step for step.

Callers in 23F84 (`callers.py`): `0xfffffff00a20f4ac` in `0xfffffff00a20f1dc` (= `mptcp_connect`: tests `mpte_flags` bit 1 = `MPTE_SVCTYPE_CHECKED` at `0xa20f490 tbnz w8,#1`, loads `ldrb w1,[x19,#0xea]` = `mpte_svctype`, `tbnz w0,#0x1f` → `EPERM`), and `0xfffffff00a21091c` in `0xfffffff00a20fcbc` (= `mptcp_ctloutput`, after `cmp w1,#4 ; b.hi` = `optval > MPTCP_SVCTYPE_PURE_HANDOVER`, `tbnz w0,#0x1f` → `EACCES`). 24B156: `mptcp_entitlement_check` at `0xfffffe000b053c74` (same string xref), body not decoded.

Conclusion for item 6: no entitlement is needed for the default `HANDOVER` service type; the only gated value is `AGGREGATE` (2). The vulnerable receive path is downstream of `connect` and does not consult any entitlement (`mptcp_subflow_soreceive` has no cred check). Seatbelt: `ГИПОТЕЗА` that `(allow network*)` covers `AF_MULTIPATH` — not verified on this pass.

---

## 6. Verdict

| Build | Kernel | unlink block | covered | 27.2.1 status |
|---|---|---|---|---|
| 23F84 (26.5.2) | xnu-12377.122.8 | absent | — | vulnerable (DATA_FIN shape confirmed by binary; `mp_rlen=0 ∧ DFIN=0` shape present in binary, reachability unknown) |
| 23G71 (26.6) | xnu-12377.162.13 | absent | — | vulnerable |
| 23G83 (26.6.1) | xnu-12377.162.14 | absent | — | vulnerable |
| 24B156 (27.2.1) | xnu-13432.42.3 | `0xb0508fc–0xb050998`, cond `DFIN ∧ m≠NULL ∧ dlen==0 ∧ mp_rlen==1` | DATA_FIN with `data_len=1` only | patched for the DATA_FIN shape; `mp_rlen=0 ∧ DFIN=0` shape unpatched in `soreceive`, but not reachable per OSS source (`ГИПОТЕЗА`, low) |

- The fix first appears in **24B156 / iOS 27.2.1**; iOS 26.6 and 26.6.1 do **not** contain it. (26.7 was not examined — no kernelcache fetched; `ГИПОТЕЗА` that the fix is also in 26.7 given the advisory list, not checked here.)
- The fix is **partial**: it unlinks the mbuf only for the DATA_FIN + `data_len=1` case. For the no-DATA_FIN case with `data_len=1`, no fix was ever needed (the mbuf is dequeued before `validate_csum` in all builds) — so the report's claim of a silent write-after-free on that path (`chain_deref`, Experiment 5) is not reproduced by the binary. For the no-DATA_FIN case with `data_len=0`, the mbuf is still linked when `validate_csum` runs, in all four builds including 24B156 (reachability `ГИПОТЕЗА`).
- Side effect: the same block makes the DATA_FIN infinite-loop shape (Bug 2) terminate in 24B156 because `m` now advances.
- The earlier note's reading of the condition as `dsn==1` is corrected to `mp_rlen==1`; the earlier reading of `0xb050938` as `sb_lock` is corrected to `sbfree`.

Open items (not done in this pass): (1) N0 reachability in the **binaries** (DSS parser of 23G83 / 24B156 not disassembled; the OSS source says not reachable, see §4.3); (2) Bug 2 (infinite loop) status in 26.6.x outside `soreceive`; (3) seatbelt profile for `AF_MULTIPATH`; (4) 26.7 kernelcache; (5) live confirmation on the iPhone 13 (26.5.2) vs iPhone 17 Pro Max (27.2.1) was out of scope (static task), and would be needed before relying on the 24B156 "patched" verdict for the DATA_FIN case.

Commands used (all run from `/tmp/jbresearch/mptcp_fix/`, venv `/tmp/jbresearch/venv/bin/python`):

```
ipsw download ipsw --device iPhone14,5 --version 26.6   --urls
ipsw download ipsw --device iPhone14,5 --version 26.6   --kernel --confirm -o /tmp/jbresearch/ipsw/266
ipsw download ipsw --device iPhone14,5 --version 26.6.1 --kernel --confirm -o /tmp/jbresearch/ipsw/2661
strings -a <kc> | grep -m1 'Darwin Kernel Version'
loc4.py <kc>                                                    # function bounds + anchor xrefs
dump.py <kc> 0xfffffff00a20c3e4 2000 > s23F84.dis               # (and the other three starts)
dump.py <kc> 0xfffffff00a1fe204 100                             # mptcp_validate_csum (per build)
dump.py <kc> 0xfffffff00a20f954 90                              # mptcp_entitlement_check 23F84
callers.py <kc> 0xfffffff00a20f954                              # who calls the entitlement check
grep -n "0x40000000" s*.dis                                     # every DFIN test in the function
check_fix.py                                                    # re-derives the §3.1 table for all four builds (→ mptcp_fix_check.out), per-word full-function decode
fnfull.py <kc> 0xfffffff00a1fe204                              # whole function incl. cold tail, per word
wordcheck.py <kc> <start> 760 <listing.dis>                   # per-word decode vs a listing: undecodable words, mismatches, tail
```

`check_fix.py` output (2026-11-26), verbatim:

```
23F84:  start=0xfffffff00a20c3e4 ins=652 dfin_test=0xfffffff00a20c700 dlen=0xfffffff00a20c70c sbcc_cmp=0xfffffff00a20c710 loop_skip=0xfffffff00a20c740->0xfffffff00a20c974 unlink_block=ABSENT validate_call=0xfffffff00a20cb44->0xfffffff00a1fe204 (x1=[x29,#-0x60]) fail_handler=(0xfffffff00a20cda4, 0xfffffff00a20cda8)
23G71:  start=0xfffffff00a21a350 ins=672 dfin_test=0xfffffff00a21a660 dlen=0xfffffff00a21a66c sbcc_cmp=0xfffffff00a21a670 loop_skip=0xfffffff00a21a6a8->0xfffffff00a21a8f8 unlink_block=ABSENT validate_call=0xfffffff00a21aaf0->0xfffffff00a20c170 (x1=x28) fail_handler=(0xfffffff00a21ad54, 0xfffffff00a21ad58)
23G83:  start=0xfffffff00a21a63c ins=672 dfin_test=0xfffffff00a21a94c dlen=0xfffffff00a21a958 sbcc_cmp=0xfffffff00a21a95c loop_skip=0xfffffff00a21a994->0xfffffff00a21abe4 unlink_block=ABSENT validate_call=0xfffffff00a21addc->0xfffffff00a20c45c (x1=x28) fail_handler=(0xfffffff00a21b040, 0xfffffff00a21b044)
24B156: start=0xfffffe000b0505c8 ins=706 dfin_test=0xfffffe000b0508dc dlen=0xfffffe000b0508e8 sbcc_cmp=0xfffffe000b0508ec loop_skip=0xfffffe000b0509d0->0xfffffe000b050c18 unlink_block=present cbz@0xfffffe000b0508fc bl@0xfffffe000b050938 validate_call=0xfffffe000b050e0c->0xfffffe000b042128 (x1=x28) fail_handler=(0xfffffe000b051054, 0xfffffe000b051058)
```
