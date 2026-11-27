# S3 — CVE-2026-43655 vs `AppleM2ScalerCSCDriver` (23F84 / 24B156)

**Verdict: refuted.** The CVE is real, but it was fixed in iOS 26.5 (released 2026-05-11), so it is
already closed on iPhone 13 / 26.5.2 (23F84). Apple's component is `IOSurfaceAccelerator`, not
`AppleM2ScalerCSCDriver`; only a third-party write-up ties it to the scaler driver.

Static only. No device. 23F84 = `kernelcache.release.iphone14`, 24B156 = `kernelcache.release.v54`.

## 1. Part (a): does the CVE exist, and what is it?

| Item | Value | Source |
|---|---|---|
| Local advisories (26.5.2 … 27.2.1) | 0 hits for `CVE-2026-43655` | `/tmp/jbresearch/advisories/adv_127594|128066|148282|149034|149041|149715.html`, `entries.json` |
| NVD | `CVE-2026-43655`, published 2026-05-11, lastModified 2026-10-26, Analyzed, CWE-125, source `product-security@apple.com` | `/tmp/jbresearch/s43655/nvd.json` |
| NVD description | "An out-of-bounds read was addressed with improved bounds checking. This issue is fixed in iOS 26.5 and iPadOS 26.5, macOS Tahoe 26.5, tvOS 26.5, watchOS 26.5. An app may be able to cause unexpected system termination or read kernel memory." | `nvd.json` |
| CVE.org | PUBLISHED, assigner `apple`, reserved 2026-05-01, published 2026-05-11 | `/tmp/jbresearch/s43655/cveawg.json` |
| Apple advisory | `support.apple.com/en-us/127110` "About the security content of iOS 26.5 and iPadOS 26.5", Released May 11, 2026 | `/tmp/jbresearch/s43655/adv/adv_127110.html` |
| Apple component | **IOSurfaceAccelerator** (available for: iPhone 11 and later) | same |
| Apple impact / description | "An app may be able to cause unexpected system termination or read kernel memory" / "An out-of-bounds read was addressed with improved bounds checking." | same |
| Apple credit | "CVE-2026-43655: Somair Ansar and an anonymous researcher" | same |
| Entry added to the page | the string `Entry added August 25, 2026` immediately precedes the IOSurfaceAccelerator `<h3>` | raw HTML of `adv_127110.html` |
| macOS advisory | same entry in `127115` (macOS Tahoe 26.5) | `adv/adv_127115.html` |
| First-listing release | **iOS 26.5** (May 11, 2026). It does not appear in any of the six later advisories (26.5.2 … 27.2.1), which is consistent with it being closed before 26.5.2. | local advisories |
| Third-party repo | `Somisomair/CVE-2026-43655-AppleM2ScalerCSCDriver-UAF`, commit `176d32becefe7faaa2aef684fbb6e1eb173a2b80` (2026-06-21), 0 stars; author "Somair Ansar" matches Apple's credit | `/tmp/jbresearch/s43655/gh_repos.json`, `repo/` |

**Conflicting descriptions, flagged:**

- Apple: *out-of-bounds read*, component *IOSurfaceAccelerator*, fix "improved bounds checking".
- Public repo: *use-after-free* in `AppleM2ScalerCSCDriver`'s shared scaler scheduler — async ops are
  left in scheduler-owned state after `IOServiceClose`, then processed through stale pointers. Claims
  affected iOS 26.4, fixed 26.5, PoC needs only `get-task-allow`, markers `0xDEAD0001` / `0xBEEF0002`,
  request size `0x1b0`, scheduler reads `operation+0xc94` as the credit/marker (`repo/README.md` lines 27–63).
- Both agree on the fixed release (26.5). Neither Apple's text nor NVD mentions the scaler driver.
  The driver attribution rests solely on the repo.

**Correction to the earlier local note** (`jb_experiments/10_cve_2026_86916_site.md`, line 53): the CVE is
real and its fix first lists in **iOS 26.5**, not 26.7. It is absent from the six local advisories
because those cover 26.5.2 and later, i.e. after the fix.

## 2. Part (b): binary check in 23F84 and 24B156

Both builds are post-fix (26.5.2 and 27.2.x), so this section can only corroborate "closed", not find
the bug. It is recorded because it answers the three disassembly questions and gives reusable anchors.

### 2.1 Kext and table locations

| | 23F84 (iPhone 13) | 24B156 |
|---|---|---|
| kext vmaddr / fileoff | `0xfffffff0074a26d0` / 4843216 | `0xfffffe000754e060` / 5546080 |
| collection base (fixup decode) | `0xfffffff007004000` | `0xfffffe0007004000` |
| `__text` | `0xfffffff0089fe7c0` + 0xf432c | `0xfffffe000908c900` + 0x140e30 |
| `IOSurfaceAcceleratorClient` string | `0xfffffff00751874a` | `0xfffffe000761bd7c` |
| user-client OSMetaClass ctor | `0xfffffff008a432b4` (instance size `0x170`) | `0xfffffe00090e2dd4` (instance size `0x180`) |
| meta-class vtable | `0xfffffff007ceeff0` | `0xfffffe0008105ec0` |
| **external method table** | `0xfffffff007cef070`, 12 × 0x30-byte entries | `0xfffffe0008105f40`, 12 × 0x30-byte entries |
| user-client instance vtable | `0xfffffff007ceeeb8` (+0x00 … +0x118) | `0xfffffe0008105dd8` (…) |

Pointer decode for both: kernelcollection rebase-only chained fixups. For auth pointers
(`0x8011…`), target = collection base + (raw & `0x0fffffff`) — **28 bits**, not 36; validate by
membership in the kext `__text`. `adrp` immediates are 21-bit signed (sign-extend when bit 20 is set).

### 2.2 External methods

| sel | 23F84 handler | 24B156 handler | in / out | role |
|---|---|---|---|---|
| 0 | `0x8a42e4c` | `0x90e2900` | `0xffffffff` | |
| **1** | **`0x8a42744`** | **`0x90e217c`** | **`0x1b0` / 0** | transform (432-byte request) |
| 2 | `0x8a42e5c` | `0x90e2910` | 0 | |
| 3 | `0x8a42e6c` | `0x90e2920` | 0 | |
| 4 | `0x8a42bf0` | `0x90e269c` | `0x20` | |
| 5 | `0x8a42b94` | `0x90e263c` | async (flags `0x100`) | |
| 6 | `0x8a42df8` | `0x90e28ac` | `0xfa8` | |
| 7 | `0x8a42c50` | `0x90e2700` | 8 | |
| 8 | `0x8a42ef0` | `0x90e29a4` | 8 | |
| 9 | `0x8a42fcc` | `0x90e2a84` | `0x10` | |
| **10** | **`0x8a43194`** | **`0x90e2c50`** | **`0x18` / 0** | `ClientProperty` (marker) |
| 11 | `0x8a43230` | `0x90e2cf0` | `0xffffffff` | `getTargetAndMethodForIndex` |

The sizes match the `wqprobe` `scaler_probe` on 26.2/23C55 (432 B / 24 B) recorded in the hypothesis.

**Selector 10 (identical in both builds, 24B156 shown):** `cmp x2,#0x18` else `0xe00002c2`; `ldr w8,[x1]`;
`cmp w8,#4`; if `>= 4` → log via gated-log helper and return `0xe00002c2`; else store `input[0]` at
`[this+0x158]` (23F84) / `[this+0x168]` (24B156) and the 16 bytes at `input+8` at `+0x160` / `+0x170`; return 0.
This is the PoC's marker mechanism.

**Selector 1:** if `[this+0x154]` (23F84) / `[this+0x164]` (24B156) ≠ 0 → tail-call the gated path
(`0x8ae1678` / `0x91b4024`); else require size `0x1b0` (else `0xe00002c2`) and tail-call the transform
(**`0x8a4220c`** / **`0x90e1b78`**).

### 2.3 Transform and the lifetime question

`0x8a4220c` (23F84): `ldr x21,[x1+8]` (flags word of the request); `ldaddal` on `[this+0xdc]`;
`cbz x21` → sync path `0x8a4222c`, else async path **`0x8a42348`**.

Async path, 23F84 (`0x8a42348`): if `[this+0x154]==0`, allocate the op (`0xa4ce5ac`, kalloc type
`0x7d0b6f0`), then:

```
0x8a423f4  stp x8, x19, [x20, #0x40]     ; op+0x40 = request, op+0x48 = this (user client, RAW pointer)
0x8a42400  strb w8, [x20, #0x50]          ; bit 10 of request+0x20
0x8a42404  ldr x0, [x19, #0x130]          ; provider
...         bl 0x8a75554                  ; enqueue; copies request -> op+0x58 (0x1b0 bytes)
0x8a42490  cbz w0 -> success: return op   ; no unlock, no completion on the success path
```

`0x8a75554` copies the client's marker into the op: `0x8a7560c ldr w8,[x22,#0x158]; str w8,[x19,#0xc94]`
— the repo's "`operation + 0xc94` read as the credit/marker" is this field. The op is then handed to
the provider's schedule method (`0x8a75b0c`, vtable `+0xe8` with callback `0x8ae9524`).

Op completion, 23F84 (`0x8a424f4`): `ldrb w8,[op+0x50]` (async) → `ldr x8,[op+0x48]` →
`ldr x8,[x8+0x118]` (owner task token) → if non-null, post `(op, cb, op+0x40, 1)` via `0xa573bbc`,
else free op (`tail 0xa4ce7a8`, kalloc type `0x7d0b6b0`).

**This matches the repo's described lifetime shape**: op → raw pointer to the user client, freed by
completion, not tracked in the user client's own teardown. Teardown (`clientFree`, slot `+0xb0`:
`0x8a41d44` / `0x90e1698`) drops `[this+0x128]`/`[this+0x120]`, calls the provider's `vtable+0x540`
method with `this`, checks the generic IOUserClient counters `[this+0xe0]`/`[this+0xdc]`, and if
`[this+0x130]`/`[this+0x140]` is set calls `0x8ad2208` / `0x9197aa0` — which walks a list at
`+0x2c20..0x2c48` of the *provider* object (count at `+0x2c40`), not the user client's ops.
No drain/wait on pending ops was found in the user client's teardown in either build.

### 2.4 Differences 23F84 → 24B156 in this kext

| Item | 23F84 | 24B156 |
|---|---|---|
| user-client instance size | `0x170` | `0x180` |
| field shift from `+0x118` upward | — | `+0x10` (`task 0x118→0x120`, `provider 0xf8→0x100`, `queue 0x130→0x140`, `marker 0x158→0x168`) |
| new byte in teardown | — | `strb w8,[x0,#0x138]`, `w8=1` at `0x90e16b8` (zeroed at start, `0x90e1264`); **never read** anywhere in the user-client code (only two writes in the kext) |
| op object size | first sub-object at `+0x21c1` | `+0x22c1` (op grew by 0x100) |
| completion function | tail-calls shared free `0xa4ce7a8` | inlines the `OSObject::free` tail (`0x90e1f58..0x90e1f98`); same semantics |
| async submit / op ownership (`op+0x48` raw) | same | same |
| transform structure (`ldaddal`, async/sync split, `0xe00002bd` on failure) | same | same |

**No fix for a lifetime/UAF or a bounds issue is visible between these two builds inside the kext.**
That is consistent with the fix having shipped in 26.5 (before both) and/or living in a different
kext (`IOSurfaceAccelerator`).

### 2.5 Answers to the three questions (23F84, unless noted)

**(i) Which precondition makes the transform return success without writing the destination?**

In the async path of `0x8a4220c` → `0x8a42348`: when `request+8 != 0` (async flag; the PoC sets
`TSD[0x008]=1`), `[this+0x154]==0` (client not gated), the op allocation succeeds and `0x8a75554`
returns 0 — the function returns the op (`x20`) at `0x8a42490` and **skips both the unlock and the
completion/release**. The kernel copy is performed later by the scheduler, not in the syscall. So a
zero return means "queued", not "pixels written". Reading the destination right after the call is
expected to see it unchanged.

Caveat: I did not trace the scheduler's execution of the op (`0x8a75b0c` → provider → `0x8ae9524`
callback), so "never writes" is not established — only that the write is deferred out of the handler.

**(ii) Are request dimensions used for copies without comparison to the real IOSurface dimensions?**

**Yes, in both builds.** In the enqueue `0x8a75554` / `0x9124680`:

```
23F84 0x8a75694..0x8a75730   request dims -> op+0x4b8/0x4bc, op+0x4e8/0x4d0 (fixed-point);
                             if (w==0 || h==0) set op+0x940 / op+0x680 flags and zero the stored dims
23F84 0x8a759ec..0x8a75a18   real dims read from IOSurface -> op+0x4b0/0x4b4 (src), op+0x770/0x774 (dst)
23F84 0x8a75a1c..0x8a75a40   if op+0x680: op+0x4b8/0x4bc := op+0x4b0/0x4b4   (only when a dim was 0)
24B156 0x9124838.. ; 0x9124b68..0x9124bdc   — instruction-for-instruction the same
```

There is no `cmp` between `op+0x4b8/0x4bc` (requested) and `op+0x4b0/0x4b4` (real) anywhere in the
kext in either build. The only place both are read together (`0x8a7b9a0..0x8a7ba30` / `0x912b670..`)
computes `max(srcW*srcH, dstW*dstH)` — a pixel-count heuristic selected by a feature byte at
`[...+0x23e]`, not a bound. The per-plane table (`request+0x110..0x130`, 4 × 0x28 → `op+0xd50..`)
is likewise copied without comparison (`0x8a75820..0x8a75870`).

Whether this is the 26.5 "bounds checking" fix site cannot be decided from these two post-fix builds;
the logic is identical in both, so if the fix was here it predates 23F84.

**(iii) Does the code differ in 24B156?**

Only by layout: instance `0x170→0x180`, fields from `+0x118` shifted by `+0x10`, op grown by `0x100`,
one new write-only byte at `+0x138`, inlined free tail. The submit/ownership/dimension logic is
unchanged (§2.4).

## 3. Evidence index

| Claim | Check |
|---|---|
| CVE real, fixed 26.5, OOB read, IOSurfaceAccelerator, credit | `adv/adv_127110.html` (grep `CVE-2026-43655`, `IOSurfaceAccelerator`, `Entry added August 25, 2026`); `nvd.json` `.vulnerabilities[0].cve.description[0].value`, `.references`; `cveawg.json` `.cveMetadata.state/datePublished` |
| Absent from 26.5.2 … 27.2.1 advisories | `grep -c 43655 /tmp/jbresearch/advisories/*.html` → 0 |
| Third-party driver claim | `repo/README.md` lines 1–63; `repo/ScalerTeardownUAF.m` (`0xDEAD0001`, `0xBEEF0002`, `0x1B0`) |
| Method table, sizes | 23F84 `0x7cef070` stride 0x30 (sel1 slot `0x7cef0a0`: func `0x8a42744`, `0x1b0`; sel10 slot `0x7cef250`: `0x8a43194`, `0x18`); 24B156 `0x8105f70` / `0x8106120` |
| sel 10 stores marker | 23F84 `0x8a43210 str w8,[x0,#0x158]`, `0x8a43218 str q0,[x0,#0x160]` (guard `0x8a431a8 cmp x2,#0x18`, `0x8a431b8 cmp w8,#4`); 24B156 `0x90e2c50` (guards `0x90e2c68`, `0x90e2c78`) |
| sel 1 gate | 23F84 `0x8a42758 ldr w8,[x0,#0x154]`, `0x8a42764 cmp x2,#0x1b0`; 24B156 `0x90e2194 ldr w8,[x0,#0x164]`, `0x90e21a0 cmp x2,#0x1b0` |
| async path skips completion | `0x8a423f4`, `0x8a42490` (23F84); `0x90e1dc0`, `0x90e1e44` (24B156) |
| marker into op | `0x8a7560c ldr w8,[x22,#0x158]; str w8,[x19,#0xc94]` |
| op completion deref owner | `0x8a424f4`: `0x8a42510 ldr x8,[x19,#0x48]; 0x8a42514 ldr x8,[x8,#0x118]` |
| teardown does not drain ops | `0x8a41d44` / `0x90e1698`; `0x8ad2208` / `0x9197aa0` walk provider list `+0x2c20..+0x2c48` |
| dims used without comparison | `0x8a75694..0x8a75a68` / `0x9124838..0x9124bdc`; pixel-count `0x8a7b9a0..0x8a7ba30` / `0x912b670..0x912b6f8` |
| disassembly dumps | `/tmp/jbresearch/s43655/xform_23F84.dis`, `xform_24B156.dis`, `enq_23F84.dis`, `enq_24B156.dis`, `gated_23F84.dis` |

Helper scripts (venv `/tmp/jbresearch/venv/bin/python`, capstone 5): `kdis.py` (linear disasm),
`kextinfo.py` (sections + cstrings), `xref2.py` (adrp+add/ldr xrefs), `kfunclist.py` (function starts),
`findoff.py` (imm-offset LDR/STR scan), `kcallers.py` (kext-wide bl/b scan), `kcfix.py`/`kcfixrange.py`.

## 4. Inferences (not observations)

- The repo's mechanism (stale scheduler entries after close) is *compatible* with the op/owner layout
  seen here (`op+0x48` raw back-pointer, completion dereferences owner), but the scheduler side that
  would actually process a stale entry was not traced, and both builds are post-fix.
- The write-only byte at `+0x138` in 24B156 is a state flag whose reader, if any, is outside the
  user-client cluster; it is not a submit gate.
- "Transform returned 0 and left the destination unchanged" on the live probe is explained by the
  async path returning at enqueue, but no probe stdout was saved (`wq2/out13_scaler.txt`,
  `out17_scaler.txt` hold only devicectl launch logs), so it stays unverified.

## 5. Status for the chain

Not usable on iPhone 13 / 26.5.2: closed in 26.5. Nothing in `AppleM2ScalerCSCDriver`'s user client
differs between 23F84 and 24B156 in a way that indicates a 26.5.x→27.x fix, so there is no
"open in 23F84, closed in 24B156" pair to exploit here.

Next: drop S3 from the candidate list; the remaining open-on-26.5.2 items are in
`10_cve_2026_86916_site.md` (CVE-2026-64788, -65346, -86944).
