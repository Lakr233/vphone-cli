# IOGPUFamily resource/group lifetime in 23F84 (iOS 26.5.2) vs 24B156 (iOS 27.2.1)

Workflow `jb-hypotheses` S7 (static only, no device). Hypothesis: the two IOGPUFamily issues Apple
lists after 26.5.2 — named in the hypothesis as CVE-2026-65346 (26.6.1, "improved memory handling",
web content → memory corruption) and CVE-2026-86944 (26.7, race, unexpected system termination) —
are present in kernelcache 23F84 and reachable from a sandboxed app through Metal, so one can serve
as the kernel bug.

## Verdict: inconclusive

- **CVE numbers in the hypothesis are mis-attributed** (see §1). The IOGPUFamily entries are
  **CVE-2026-43743** (26.5.2, race / "improved state handling") and **CVE-2026-64788** (26.6.1,
  "improved memory handling", web content → memory corruption). CVE-2026-65346 is ImageIO
  (integer overflow, image → arbitrary code execution); CVE-2026-86944 is **IOAcceleratorFamily**
  (OOB write, 26.7).
- 26.5.2 is the release that *fixes* 43743, so on the iPhone 13 (23F84) **43743 is already closed**.
  The only IOGPUFamily entry open on 26.5.2 is **64788** (fixed in 26.6.1).
- **Reachability (task b): confirmed.** `IOGPUDeviceUserClient` (IOServiceOpen type 1 / 33) has no
  entitlement gate in either build; `deviceUserClientStart` never fails for an unentitled caller
  (it only records the `gpu-restricted` flag). Same in 24B156 (99.6 % identical body).
- **Lifetime diff (task c): one changed site, not in the hash insert/remove/grow.** The hash insert
  (`0x95fe7b8` ↔ `0xa080530`), hash remove (`0x95fe55c` ↔ `0xa0802d0`, 99.7 % identical), grow/rehash
  (`0x95ffc74` ↔ `0xa081b78`, 99.8 %), the rollback-on-failure release loop, group add/remove wrappers,
  ID-table `lookup`, the user-client destructor and `deviceUserClientStart` are semantically unchanged
  between 23F84 and 24B156.
  What changed is how the device's **ID→resource table pointer `[dev+0x90]`** is read on the four
  resource-path sites: 23F84 reads it **unlocked and unretained** (3-insn getter `0x9626ba4` or a
  raw `ldr`); 24B156 routes the same four sites through a new accessor `0xa0ab5dc` that does
  **`IOLockLock([dev+0x48]); retain([dev+0x90]); IOLockUnlock`** and adds a matching `release` at the
  logging site in `IOGPUDevice::new_resource` (`0xa090b18..0xa090b3c`).
- Whether that accessor change *is* the 64788 fix cannot be established statically: it is a
  race-hardening shape (matches 43743's "improved state handling" wording) but lives in a different
  build (27.2.1) than the 26.6.1 fix, and the fix may equally be in `AGXG14P/G18P` or elsewhere.
  24B156 also adds boot-args `iogpu_no_check_descriptor_size`, `iogpu_panic_on_event_timeout`,
  `iogpu_event_timeout_secs`, `iogpu_gart_*`, `iogpu_single_sysmem_pct`, `iogpu_sysmem_mb`,
  `iogpu_no_abort`; the consumer of the `descriptor_size` flag (bit 28 of the controller flags word
  `[ctl+0x1fc]`) was **not located** in IOGPUFamily or AGX.
- lightsword's 23C55 PoC for 64788 (`iogpu_uaf64788.m`, 1×65535 IOSurface texture) is recorded there
  as **not vulnerable on 23C55** because the dimension validator runs before insert; nothing in this
  diff suggests that validator moved in 23F84 (not re-verified here).

## Inputs

| Item | 23F84 | 24B156 |
|---|---|---|
| File | `/tmp/jbresearch/ipsw/x13/kc.decomp/kernelcache.release.iphone14.decompressed` | `/tmp/jbresearch/ipsw/x17/kc.decomp/kernelcache.release.v54.decompressed` |
| Device / OS | iPhone 13, iOS 26.5.2 | iPhone 17 Pro Max, iOS 27.2.1 |
| xnu | `xnu-12377.122.8~1` (Darwin 25.5.0, 2026-06-09) | `xnu-13432.42.3~28` (Darwin 27.2.0, 2026-10-13) |
| sha256[:16] | `6f42b06019b0e3ae` | `f6f31ac427bed2cd` |
| IOGPUFamily fileset | `com.apple.iokit.IOGPUFamily` @ `0xfffffff0077328c0`, `__text` 0x3fbbc | @ `0xfffffe00079a0270`, `__text` 0x43a5c (+0x3ea0) |
| GPU kexts | `AGXG14P`, `IOGPUFamily`, `IOMobileGraphicsFamily`, `IOMobileGraphicsFamily-DCP`, `IOSurface`, `AGXFirmwareKextG14PRTBuddy/64` | `AGXG18P`, `IOGPUFamily`, `IOMobileGraphicsFamily(-DCP)`, `IOSurface` |

Tools (all in `/tmp/jbresearch/iogpu/`, venv `/tmp/jbresearch/venv/bin/python`): `kx.py`
(fileset loader; `dis|data|xref|strs|callers`), `site2func.py` (`site./__PRETTY__` cstring → function),
`mtable.py` (`IOExternalMethodDispatch` table dumper, 0x18 stride `{func, inScalar, inStruct, outScalar, outStruct}`),
`ptrscan.py`, `fnorm.py` (normalised body: mnemonics, addresses/immediates ≥ 9 hex digits masked),
`fmatch.py <kcA> <kcB> <kext> <fnA>` (cross-build function match by mnemonic sequence + difflib ratio,
prints unified diff of normalised bodies), `cstr.py`, `axref.py`. Chained-fixup pointer: low 30 bits
= file offset (bit 30 = cacheLevel); in these two caches every dispatch entry is `cacheLevel 0`.

## 1. Advisory ground truth (task a)

Parsed from the local copies in `/tmp/jbresearch/advisories/` by heading (`<h3>` component → Impact →
Description → CVE): `/tmp/jbresearch/iogpu/advisory_reparse.txt`, `advisory_cve_index.txt`,
`/tmp/jbresearch/advisories/entries_by_heading.json` (402 rows / 437 CVEs).

| Release | Page | Component | CVE | Impact | Description | Credit / note |
|---|---|---|---|---|---|---|
| iOS 26.5.2 | `adv_127594.html` | **IOGPUFamily** | **CVE-2026-43743** | app may cause unexpected system termination | race condition, improved state handling | Lyutoon, Dun |
| iOS 26.6.1 | `adv_148282.html` | **IOGPUFamily** | **CVE-2026-64788** | maliciously crafted **web content** may lead to memory corruption | improved memory handling | anonymous, f00l @PPPF00L, 3ndy1, Minghao Lin@Y1nkoc, 云散花折, Arjanit Isufi; entry updated Sep 14 2026 |
| iOS 26.6.1 | `adv_148282.html` | ImageIO | CVE-2026-65346 | processing an image → arbitrary code execution | integer overflow, improved input validation | (the component *before* IOGPUFamily on the page) |
| iOS 26.7 | `adv_149041.html` | **IOAcceleratorFamily** | **CVE-2026-86944** | app may cause unexpected system termination | out-of-bounds write, improved bounds checking | entry added Oct 19 2026 |
| iOS 26.7 | `adv_149041.html` | IOGPUFamily | CVE-2026-43743 | (same entry re-listed) | | |

Reading rule (`apple_advisory_entries_26.5.2_to_27.2.1.md`): an entry first listed in 26.6/26.6.1/26.7/27.0
is **open on 26.5.2** and closed on 27.2.1. Hence on 23F84: 43743 **closed**, 64788 **open**,
86944 (IOAccelerator, not IOGPUFamily) **open**.

Public material beyond Apple's text: none recorded in the local lightsword checkout
(`/tmp/jbresearch/ghs/lightsword/STATE.md`, `VULNS.txt`, `PROJECT.md`) for 43743 ("closed as source (no
entry point)" on 26.2) or for 64788 other than the bytev0rtex PoC `Sources/Legacy/iogpu_uaf64788.m`
(Metal 1×65535 IOSurface texture; "not vulnerable on 23C55"). No WebKit bug / write-up URL is in those
files; no web fetch was done in this run (rate-limit rule).

## 2. GPU user clients and sandbox openability (task b)

23F84 filesets (249): `com.apple.AGXG14P` @ `0xfffffff007100db0`, `com.apple.iokit.IOGPUFamily`
@ `0xfffffff0077328c0`, `IOMobileGraphicsFamily` @ `0xfffffff0077618b0`,
`IOMobileGraphicsFamily-DCP` @ `0xfffffff007759d90`, `IOSurface` @ `0xfffffff00779caa0`,
`AGXFirmwareKextG14PRTBuddy`, `AGXFirmwareKextG14PRTBuddy64`. 24B156 (301): `com.apple.AGXG18P`
@ `0xfffffe0007127140`, IOGPUFamily @ `0xfffffe00079a0270`.

User clients found in IOGPUFamily (by `site.` labels and dispatch tables):

| User client | 23F84 dispatch table | Openable unentitled? |
|---|---|---|
| `IOGPUDeviceUserClient` type 1 (sel 0–55) | `0xfffffff007e963a8..0x7e96e28` (112 entries, `mtable_x13_t1.txt`) | **Yes** — `deviceUserClientStart` `0xfffffff0095f21b4` has no failure branch on entitlement; `isGPURestricted()` `0x960c770` only stores a flag at `[this+0x103]`. Same in 24B156 (`0xa07368c`, 99.6 %). |
| same class, type 33 (sel 0–127 → table B, same 56 wrappers + stubs) | `__const 0x7e969a8` | Yes (same wrappers; sel 56+k == type-1 sel k) |
| `IOGPUMemoryInfoUserClient` (`gather_memory_data` `0xfffffff009623d04`) | separate | **No** — gated by `com.apple.private.ioaccelmemoryinfo` (xref `0x9623cb0`); 24B156 `0xa0a83f8` |
| `AGXAccelerator` user client (AGX kext, not IOGPUFamily) | — | `07_iokit_reachability.md`: type 1 opens from sandbox; lightsword: IOGPU type **5 does not open** (wh1te4ever PoC needed type 5) |

Service name vs class: lightsword opens `IOServiceOpen("IOGPU", type=1)`; `07_iokit_reachability.md`
finds 0 IORegistry instances named `IOGPUFamily`/`IOGPUDeviceUserClient` — the provider's IORegistry
name is `IOGPU` (the `IOGPU` class in this kext, `IOGPU::start` string @ `0x77377de`); the user client
class name is never an IORegistry entry name. Not contradictory.

`deviceUserClientStart` (23F84 `0x95f21b4`, 141 ins) does: `IOGPUDevice* dev = provider->newDevice(token)`
(`[+0xf8] vtable+0x588`, stores `[this+0x120]`), `+0xe8 = OSAllocate…(1)`, `+0x103 = dev->flag`,
`copyClientEntitlement`-style call with mask cstring `"1212222221211122"` (`0x77333d8`), registers
`"AppUsage"` property (`0x7733b18`). Returns `true` unless `dev == NULL` or the lock alloc fails.

Entitlement strings in IOGPUFamily (both builds): `com.apple.private.ggdsw.GPUProcessProtectedContent`
(xref 23F84 `0x9603ed8` / 24B156 `0xa085f60`), `com.apple.private.agx.rt-priority-spi`,
`com.apple.private.graphics-restart-no-kill`, `com.apple.private.gpu-restricted` + `com.apple.developer.gpu-restricted`
(`0x960c784/0x960c7a4` / `0xa08f1d0/0xa08f1f0` → `isGPURestricted`), `com.apple.private.iogpu.disable-wired_collector`,
`com.apple.private.ioaccelmemoryinfo`. Only the last one gates a user client.

## 3. lightsword's IOGPU functions re-found (task c)

23C55 anchors from the hypothesis (hash insert `0x9f62b38`, remove `0x9f518ac`, grow `0x9f7699c`;
cmd 3 group create, cmd 130 add resource, cmd 0 read) are build-specific. Equivalents found by
following `s_new_resource` / `s_group_add_resources` / `s_group_remove_resources` call graphs:

| Role | 23F84 | 24B156 | Cross-build |
|---|---|---|---|
| user-client `s_new_resource` (sel 8 / 64) | `0xfffffff0095efee8` | `0xfffffe000a071324` | identical after normalisation (only `bti c`) |
| trampoline → `IOGPUDevice::new_resource` | `0x95f26fc` (31 ins) | `0xa073be0` | identical except device-struct offset `+0x2d0`→`+0x2e0` |
| **`IOGPUDevice::new_resource`** | `0xfffffff00960d7d8` (578 ins) | `0xfffffe000a0902b4` | 98.3 %; diffs: sysmem-limit formula (×3 → `[ctl+0x2ec]`% via `0x28f5c28f5c28f5c3` magic), **`[dev+0x90]` accessor + added release** (§4) |
| device command-queue create (queue type 5, `[ctl+0x160]++`) | `0x960d4b8` (200 ins) | `0xa08ff3c` | 94.8 %; diffs: struct offsets `+0x168→+0x160`, `+0x148→+0x140`, `+0x160→+0x158`, plus the **`[dev+0x90]` accessor** (§4) |
| device resource map (offset+len overflow check `adds/b.lo`) | `0x960e474` (294 ins) | `0xa090fa8` | 94.3 %; only register re-allocation + the **`[dev+0x90]` accessor** |
| `s_group_add_resources` wrapper | `0x95f15dc` | `0xa072a74` | identical shape |
| device `group_add_resources` (lookup ids, retain, add ≤256 / >256) | `0x960eb68` → `0x960e90c` | `0xa0916f8` → `0xa091494` | 99.2 % / 97 % — only addressing-mode re-encodings |
| **hash insert (≤256)** = 23C55 `0x9f62b38` | `0xfffffff0095fe7b8` (420 ins) | `0xfffffe000a080530` (~500 ins) | 88.9 % mnemonic ratio; differences are register allocation + a duplicated rollback loop; **semantics identical**: probe `(obj->0x70 * 0x7f4a7c15) >> (32-[tbl+0x2c])`, insert sets bitmap + `[tbl+0x30]++`, retain(obj); on post-hook failure (`0xa0927c0` returns error) walk the just-inserted list, `[slot+8]--`, **release(obj) at zero**, clear slot+bitmap, `[tbl+0x30]--` |
| hash insert (>256) | `0x95fde90` | `0xa0927c0`'s sibling (not diffed) | not checked |
| `s_group_remove_resources` wrapper | `0x95f1768` | `0xa072c04` | identical |
| device `group_remove_resources` | `0x960ec6c` (34 ins) | `0xa091800` | 98.6 % |
| **hash remove** = 23C55 `0x9f518ac` | `0xfffffff0095fe55c` (151 ins) | `0xfffffe000a0802d0` | **99.7 % — unchanged** |
| ID-table `lookup` (lock `[tbl+0x20]`, lookup, unlock) | `0x95ed6c8` (49 ins) | `0xa06e914` | **exact mnemonic-sequence match** |
| ID-table `get` (index-bound) | `0x95ed890` | `0xa06eae4` | same shape |
| device `get_group(id)` thunk (`[this+0x90]` → lookup) | `0x960cc1c` | — | — |
| **grow / rehash** (23C55 `0x9f7699c`) | `0xfffffff0095ffc74` (319 ins; `[tbl+0x20]<<1` → new table of class `__const+0x698`, rehash) | `0xfffffe000a081b78` | **99.8 % — unchanged** (only `bti c`) |
| `~IOGPUDeviceUserClient` (vtable `__const 0x7e962f8` slot 0) | `0x95f2558` | `0xa073a38` | 99.5 % — unchanged |
| user-client `clientClose`-ish (vtable slot 3/4) | `0x95f2778` (39 ins) | `0xa073c60` | 98.7 % — unchanged |
| `deviceUserClientStart` | `0x95f21b4` | `0xa07368c` | 99.6 % — unchanged |

The 24B156 dispatch table (`__const 0xfffffe000830cd50..0x830d7d0`, 112 entries, `mtable_x17_t1.txt`)
has the same layout as 23F84: sel 0 `{0,0,0,0x40}`, sel 2 `{0,0,0,0x218}`, sel 6 `{0,var,0,0x10}`,
sel 8 `{0,var,0,var}` = `s_new_resource` `0xa071324`, sel 52/53 `{2,var,0,0}` = group add/remove,
sel 56+k mirrors sel k. Removed slots in table B point to a stub `0xa0edf0` (23F84: `0x95f1950`).
Arity check (`mtable.py`): 23F84 `sel 25 {4,var,1,0}`, `sel 26 {1,12,1,0}`, `sel 27 {1,4,0,0}`, `sel 28 {0,0,2,0}`
match lightsword's 23C55 numbers.

`IOGPUDevice::new_resource` head (23F84 `0x960d804..`): needs `structSize ≥ 0x58`, `structSize ≤ [ctl+0x234]+0x58`,
command = `[args]` (`tst w8,#0xf` → `0x82` = IOSurface-resource variant with `0x961b63c` lookup and a
size check `[args+0x3c] ≤ IOSurface size`), then sysmem-limit check `[args+0x48] ≤ 3*[ctl+0x110]>>2 & …`
(23F84) which 24B156 replaces by `[ctl+0x118]*[ctl+0x2ec]/100`. Then `[args+0x15] bit 3` selects the
resource type path (`0x95fc534` / `0x95fb9ac` / …) and the new object's `[+0x90]` provider is called at
vtable `+0x78` (disc `0x34f6`).

## 4. The one lifetime-site difference: `[dev+0x90]` accessor

`[IOGPUDevice+0x90]` is the device's **ID→object table pointer** (the object whose `lookup` is
`0x95ed6c8`, whose lock is at `+0x20`, and on which `group_add/remove` operate through `[dev+0x10]`'s
group table). It is written in `IOGPUDevice::init` (`0x95ff0e4`: `str xzr,[x22+0x90]` @ `0x95ff338`,
`str x24,[x22+0x90]` @ `0x95ff408`; 24B156 `0xa080fc8` @ `0xa08121c/0xa0812ec`, function 99.8 % identical)
and torn down in the same place (`0x95ff0e4` ins 140–149: `release([x22+0x90]); str xzr,[x22+0x90]`).
No store to `[dev+0x90]` was added or moved between builds (15 store sites each, same pattern).

**23F84 reads (unlocked, unretained):** getter `0xfffffff009626ba4` = `ldr x0,[x0,#0x90]; ret`
(3 ins). Callers on the device object: `0x960d6ac` (fn `0x960d4b8`), `0x960de84`, `0x960dfd4`,
`0x960e064` (fn `0x960d7d8` = `new_resource`), `0x960e50c` (fn `0x960e474` = resource map); raw load
`0x9626e94` (fn `0x9626e54`). The other 7 callers of the getter (`0x95faae0`, `0x95fae58`, `0x95fbd20`,
`0x95fc9cc`, `0x95fd998`, `0x95fde18`, `0x95ff0e4`) are command-queue objects' own `+0x90`, not the device's.
In `new_resource` the logging branch reads `[dev+0x90]` and passes it to `IOLog(0x85180000+0x118, …)` at
`0x960dff8..0x960e018` **with no release** — correct for an unretained getter.

**24B156 reads (locked + retained):** new accessor `0xfffffe000a0ab5dc` (23 ins):
`bl 0xa06c640` (= `IOLockLock([this+0x48])`, thunk → kernel `0xa0adb5c`), `x20=[dev+0x90]`,
`if (x20) retain(x20)` (vtable `+0x20`, disc `0x2e4a`), `bl 0xa06c64c` (= `IOLockUnlock([this+0x48])` → `0xa0adb9c`),
`return x20`. Callers (4): `0xa090130` (fn `0xa08ff3c` = 23F84 `0x960d4b8`), `0xa090acc`
(fn `0xa0902b4` = `new_resource`), `0xa091040` (fn `0xa090fa8` = 23F84 `0x960e474`), `0xa0ab998`
(fn `0xa0ab950` = 23F84 `0x9626e54`). The 3-insn getter no longer exists in 24B156 (no mnemonic match).
In `new_resource` the logging branch now ends with **`cbz x19 → skip; release(x19)`**
(`0xa090b18..0xa090b3c`, vtable `+0x28`, disc `0x3a87`) — the balancing release.

Lock inventory: the `[+0x48]` IOLock pair exists in both builds (23F84 thunks `0x95eb594/0x95eb5a0`
→ kernel `IOLockLock 0x9e3b048` / `IOLockUnlock 0x9e3bb78`, 19/20 callers; 24B156 `0xa06c640/0xa06c64c`
→ `0xa0adb5c/0xa0adb9c`, 22/23 callers). What is new is *using it around the `+0x90` read*.

Reading (inference): a reader that takes `[dev+0x90]` without the device lock and without a retain can race
the init/teardown pair in `IOGPUDevice::init`/destructor (`release([dev+0x90]); [dev+0x90]=0`), i.e. use a
freed table pointer if a resource call overlaps device teardown — a "race condition … improved state
handling" shape. The same four sites in 23F84 are unprotected. This is the only lifetime-handling
difference found on the resource/group path.

## 5. Other build-diff signals (observation only)

- 24B156-only boot-args: `iogpu_panic_on_event_timeout`, `iogpu_no_prepare_avoid_throttling`,
  `iogpu_no_check_descriptor_size`, `iogpu_no_throttled_multi_kick`, `iogpu_no_abort`,
  `iogpu_disable_restart_limit`, `iogpu_event_timeout_secs`, `iogpu_sysmem_mb`,
  `iogpu_single_sysmem_pct`, `iogpu_gart_interval_ms`, `iogpu_gart_timeout_ms`; 23F84-only:
  `iogpu_boost_cpu_priority`. All parsed in `0xa09af2c`; `iogpu_no_check_descriptor_size` sets bit
  `0x10000000` of `[ctl+0x1fc]` (`0xa09b494`); consumer not located (not in IOGPUFamily / AGX by bit-28 test).
- `site.` label sets identical (72 each). kalloc_type view sizes changed 0x138→0x130, 0xb0→0xb8,
  0x230→0x250, 0x68→0x60, 0x48→0x40, 0x168→0x180, 0x2e8→0x2f0, 0x598→0x5d0 (names unresolved).
- 23F84-only strings `removedResource`, `result`; 24B156-only `"Timeout`.

## 6. What would settle it (not done here)

1. Diff the >256 insert (`0x95fde90` ↔ 24B156); grow/rehash is already shown unchanged.
2. Locate the `[ctl+0x1fc]` bit-28 consumer (likely in `AGXG14P`/`AGXG18P` via a flags getter) to see
   what "check descriptor size" validates — a candidate "improved memory handling" check.
3. Check the 26.6.1 kernelcache (iPhone 13 build between 23F84 and 27.2.1) for the same accessor change:
   if the locked getter appears first in 26.6.1, it is the 64788 fix; if only in 27.x, it is unrelated.
4. Re-verify the 23C55 dimension-validator claim (`0x9f4e5c0`) in 23F84 before ruling out the bytev0rtex PoC.

## Files

- This note: `Research/jb_experiments/ios26-kernel-research/iogpu_family_65346_86944.md`
- Dumps: `/tmp/jbresearch/iogpu/mtable_x13_t1.txt`, `mtable_x17_t1.txt`, `dis_x13_s_new_resource.txt`,
  `dis_x17_s_new_resource.txt`, `dis_x13_dev_new_resource.txt`, `dis_x17_grp_insert_le256.txt`,
  `dis_x13_grp_insert_le256.txt`, `dis_x13_hash_insert.txt`, `dis_x13_dev_group_add.txt`,
  `dis_x17_iogpu_init.txt`, diffs `fm_x13_*.txt`, `site2func_x17.txt`, advisory parse
  `/tmp/jbresearch/iogpu/advisory_reparse.txt`, `advisory_cve_index.txt`.
