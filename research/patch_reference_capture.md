# Capturing the patcher reference snapshot

> **Historical.** Everything below describes a facility that lived in the Python
> patchers — `--emit-records`, `VPHONE_PATCH_RECORDS`, `cfw_records.py` — and
> left with them when `scripts/patchers/` was removed. It is kept because the
> port was built against the records it describes, and because shipping code
> still cites its findings (`CFWJetsam.swift` quotes the non-idempotency note).
> To run any of it, recover `scripts/patchers/` from git history at `78cbeea`.
> The parity evidence itself is no longer re-derived at test time: it is frozen
> into the `FrozenReference` / `*Golden` enums in `tests/FirmwarePatcherTests/`.

Migration plan **P1.0**, the step marked 不可跳过. These patches rewrite pages
TXM hashes, so a wrong byte in the Swift port is a boot panic, not a failing
test. Capture the reference off a real install first; port against it second.

Capture is a pure observer — a patch run with it on produces a byte-identical
output file to one with it off. Turning it on during a real install is safe.

The one thing it will do to a run is **stop it**. If the input it is asked to
describe cannot yield an honest record, the patcher raises `CaptureError` before
its write rather than storing a false one. That never fires on the capture this
page describes — one clean pass over pristine inputs — and what it catches is
[re-running a capture into a root that already holds one](#re-running-a-capture).

---

## The whole capture, in one environment variable

```zsh
cd <repo>
VPHONE_PATCH_RECORDS="$PWD/ipsws/patch_refactor_input" make cfw_install_exp SPOOF_BUILD=23B85
```

That is it. The variable survives the installer's `sudo -E` re-exec and its
inner `env` call, and every patcher — invoked through `cfw.py`, run as its own
script, or called from Swift — picks it up on its own. No shell edit, no flag
per call site.

**The install runs as root, so the capture lands root-owned.** Afterwards:

```zsh
sudo chown -R "$(id -un)" ipsws/patch_refactor_input
```

For a single patcher outside an install, the flag does the same thing:

```zsh
.venv/bin/python3 scripts/patchers/cfw.py patch-watchdogd <binary> \
    --emit-records ipsws/patch_refactor_input
```

`--emit-records` is accepted by every `cfw.py` subcommand and by
`cfw_patch_build_version.py`, `cfw_patch_post_restore_dt.py` and
`campo_mach_lookup_exceptions.py`. The root defaults to
`ipsws/patch_refactor_input` if you leave it off.

Because the value is optional, a `<root>` written separately from the flag has
to look like a path — a `/` in it, a leading `~`, or a directory that already
exists — and may not be a subcommand name. So
`cfw.py --emit-records patch-seputil <bin>` reads as the bare flag plus a
subcommand, not as a request to capture into `./patch-seputil/`. For a root that
is a bare new name, use `--emit-records=<root>`.

---

## Two runs cover the matrix

`cfw_install.sh` reads `ProductVersion` off the mounted SystemOS and branches on
it, so no single install touches all 19 patchers. **`VARIANT=exp` on an iOS 26
base and on an iOS 27 base is the whole matrix** — exp chains `cfw_install.sh`,
so it is a superset of regular, and `dev` adds nothing exp does not already have.

| capture run | picks up |
| --- | --- |
| `cfw_install_exp` on **any** base | `seputil`, `launchd_cache_loader`, `mobileactivationd`, `inject_daemons`, `dropbear_plist`, `launchd_jetsam`, `inject_dylib`, `watchdogd`, `hv_vmm_dsc`, `camera_dsc`, `post_restore_dt`, `build_version` (needs `SPOOF_BUILD`), `campo_mach_lookup` |
| … on an **iOS 26 / 18** base | + `iomfb_swapend` |
| … on an **iOS 27** base | + `dsc_maxslide`, `lsd_embedded_reg`, `xpc_lwcr`, `lockdown_mode`, `iomfb_force_kern`, `diskimagesiod` |

`dsc_maxslide` self-gates to a no-op on a base whose cache already fits. To
capture it on a non-27 base anyway, add `FORCE_DSC_MAXSLIDE=1`.

Capture the same variant on more iOS builds than these two — the reference is
per build, and a patcher that silently finds nothing on a new build is exactly
what plan risk R7 is about. **Give each build its own root.** A root holds one
copy of each input under `raw_payloads/`, and `PatchComparisonTests.swift`
replays the port against that one copy and asserts the record count matches, so
a root can only describe one build.

---

## Re-running a capture

Records from several runs merge into one `<group>.json`, because one install
legitimately runs a patcher over several files — the SystemOS and AppOS
cryptexes both have a `launchd.plist`. Records for the same *site* collapse; the
site is `(patchID, component, fileOffset, source path)`, not the bytes.

> The site key used to end in the source **basename**, with this same paragraph
> given as the reason — which is self-refuting: if both cryptexes hold a file
> called `launchd.plist`, the basename is exactly what fails to tell them apart.
> It silently dropped the second cryptex's record, so a correct port would then
> fail `comparePatchRecords()` on count (2 vs 1). Use the full path. The keying
> is deliberately on the site rather than the bytes because two of these
> patchers are not idempotent and a re-run lands a genuinely new record at a
> *different* offset — see the re-capture guards below.

What does **not** work is running a capture twice over the same tree, and the
capture now refuses it instead of quietly producing a wrong reference:

```
CaptureError: re-capture refused: <path> ... The file has been patched since —
recording it as an original would describe the wrong bytes. Restore the pristine
input, or capture into a fresh root: one root per (variant x iOS build).
```

The reason it cannot be allowed to proceed is that the capture reads
`originalBytes` off the file on disk. On a second pass the patcher reads its own
output back and calls it the original, and two patchers are not idempotent —
`patch_launchd_cache_loader` and `patch_launchd_jetsam` each find a *second*,
different site on an already-patched binary. Those land as brand-new records at
offsets the pristine image never had patched, and `comparePatchRecords()`
asserts on the record count, so a **correct** Swift port then fails against the
reference. A record where `originalBytes == patchedBytes` is refused outright
for the same reason: it asserts something false about the pristine bytes, and a
port that writes nothing satisfies it.

To redo a capture, delete the root (or capture into a new one) and re-extract
the inputs.

The non-idempotency itself is a separate, pre-existing bug in
`cfw_patch_cache_loader.py` and `cfw_patch_jetsam.py` — it reproduces with
capture off. Neither patcher checks whether the site it found is already
patched, so on a second pass the first candidate no longer matches the shape
they search for and the scan walks on to the next one:

* `patch_launchd_cache_loader` NOPs `0xC7C`, then on a re-run `_find_nearby_branch`
  skips the `nop` it wrote and returns the *next* conditional branch after the
  same `bl` (`0xC84`).
* `patch_launchd_jetsam` rewrites the conditional at `0xFA98` to `b`, which drops
  out of `cond_mnemonics`. `cfw_patch_jetsam.py:117-136` scans *backward* keeping
  the farthest-back match, so losing `0xFA98` makes it fall back to a **later**
  candidate, nearer the xref (`0xFAB0` > `0xFA98`) — not an earlier one.

The fix in both is the same shape and does not need new anchors, but it has to
live **inside the scan**, not after it. Checking the picked site is useless here:
on a re-run neither patcher picks the previously patched site. Decoded from the
real twice-patched binaries, run 2 picks `0xC84` holding a live `cbnz x0, #0xca4`
(the `nop` is back at `0xC7C`), and `0xFAB0` holding a live `b.ne #0xfaec` (the
`b` is back at `0xFA98`). So: `_find_nearby_branch` must treat a `nop` at a
candidate position as already-patched, and `cfw_patch_jetsam.py`'s backward loop
must treat an unconditional `b` into a return block as already-patched — both
`0xFA98` and `0xFAB0` branch to the same `0xfaec`, so the target test still
applies. Both would then report no-op on a re-run, the way `patch_watchdogd` and
the DSC patchers already do.

---

## Where it lands

```
ipsws/patch_refactor_input/
├── reference_patches/
│   ├── <patcher>.json          one JSON array per patcher
│   ├── _capture_log.jsonl      one line per run: group, counts, root, argv, time
│   └── _capture_warnings.jsonl anything the capture could store but you should
│                               not trust; absent on a clean capture
└── raw_payloads/
    ├── <binary>                the pre-patch input, to replay the port against
    ├── <binary>.<sha12>        a *different* input with the same basename — the
    │                           second patcher in a chain sees the first one's
    │                           output, and each record names the one it used
    ├── <binary>[.<sha12>].patched
    │                           only when the patch changed the file's length
    └── dsc_pages/              16 KiB before/after pairs around each DSC patch
```

`_capture_log.jsonl` carries `capture_root` and `env_var_set` because `argv`
alone does not answer how capture was turned on: `cfw.py` strips
`--emit-records` out of `sys.argv[:]` before dispatch, so its subcommands log an
argv with no flag in it, while `cfw_patch_build_version.py`,
`cfw_patch_post_restore_dt.py` and `campo_mach_lookup_exceptions.py` strip a
*local* argv and do log the flag. `VPHONE_PATCH_RECORDS` shows in neither.

The directory names are the convention
`tests/FirmwarePatcherTests/PatchComparisonTests.swift` already reads from.
`ipsws/` is gitignored, so none of this is committed.

The DSC is ~7 GiB and is **not** copied. What `raw_payloads/dsc_pages/` holds is
the 16 KiB code-signature page around each patch, before and after — enough for
P1.1's slot-hash cross-check, not enough to re-run a DSC patcher's *finder*.
That one needs the real cache on the machine.

---

## Is the capture complete?

```zsh
.venv/bin/python3 scripts/patchers/cfw.py records-status
```

It lists all 19 required patchers, prints the record count for each, names the
ones still missing, and exits non-zero until every one is captured — or until
every captured record can actually fail a wrong port. Pass a root as an argument
if it is not `ipsws/patch_refactor_input`.

A patcher showing `MISSING` after an install means one of three things: that
iOS base gated it off (the table above), its input was absent, or it found
nothing — and the third is the one to chase, in `_capture_log.jsonl` and the
install log.

---

## The record format

Each object in `<patcher>.json` decodes, with no translation layer, as **both**:

* `FirmwarePatcher.PatchRecord` — `patchID`, `component`, `fileOffset`,
  `virtualAddress`, `originalBytes`, `patchedBytes`, `beforeDisasm`,
  `afterDisasm`, `patchDescription`; `Data` as base64, exactly as `Codable`
  encodes it. `JSONDecoder().decode([PatchRecord].self, from:)` works as-is.
* the `ReferencePatch` struct in `PatchComparisonTests.swift` — `file_offset`,
  `patch_bytes` (hex), `patch_size`, `description`, `component`. Same values,
  its spelling.

Plus provenance both decoders ignore: `orig_bytes`, `orig_size`, `patched_size`,
`va`, `file`, `orig_sha256`, `patch_sha256`, `inline_bytes`, `comparable`,
`file_sha256_before`, `file_sha256_after`, `payload_before`, `payload_after`.
The two `file_sha256_*` are whole-file hashes: they say which `raw_payloads/`
entry a record belongs to, and they are what the re-capture guard matches a
later run's input against.

One record per sub-patch: each of the camera patcher's short-circuited symbols,
each `hv_vmm_dsc` cstring site, each `iomfb_force_kern` trampoline, and each
code-signature slot the re-attestation rewrites, all named individually.

### Records that change a file's length

A patch that resizes the file has no common offset space to diff, so it needs a
recorder that knows the format. `inject-dylib` has one. `insert_dylib` strips
launchd's code signature and reflows `__LINKEDIT` — the file comes out 27 KiB
*shorter* — but the edit a Swift port has to reproduce is small, bounded, and
sits at offsets that do not move, so that is what gets recorded:

| record | what it pins |
| --- | --- |
| `inject_dylib.lc_load_dylib.mach_header` | the 32 header bytes carrying `ncmds` / `sizeofcmds` |
| `inject_dylib.lc_load_dylib` | the inserted `LC_LOAD_WEAK_DYLIB`, at its offset |
| `inject_dylib.lc_load_dylib.lc.0x<off>` | every other byte the command region moved (`__LINKEDIT` extent, `LC_SYMTAB` sizes) |

Five records with real bytes at real offsets, where there used to be one with
empty bytes at offset 0 that a port writing *nothing at all* still matched. What
is deliberately not graded is the `__LINKEDIT` reflow past the command region:
that is the signature strip, not the load-command write, and the payload pair is
there to replay it.

### Records that cannot fail

`"comparable": false` (and a `patchID` ending `.opaque`) means the change was
too big to inline, over 256 KiB — `patch_bytes` is empty and `patch_size` is 0,
so the Swift comparison cannot fail against it. It is a pointer at the
`payload_before` / `payload_after` pair, not a check. `records-status` marks the
group `[!]` and exits non-zero, because a group like that looks captured while
grading nothing; the fix is a structural recorder for that format, the way
`record_macho_lc_edit` is the one for Mach-O.

### Records the patcher did not declare

A record whose `patchID` ends in `.undeclared.0x<offset>` is a byte the patcher
changed without declaring it. That is not an error in the capture; it is the
capture telling you the patcher's own account of itself has drifted from what it
writes. Read it before porting that patcher.

---

## Known defects in this capture, as of 2026-09-23

An independent verifier reproduced each of these with a harness. The doc errors
above are already corrected; these are the ones still in the code. Read them
before you trust a reference this produces.

1. **`_dedupe_key()` drops a legitimate record** (`cfw_records.py:1146`). It
   keys on the source *basename*, so one install patching both the SystemOS and
   AppOS `launchd.plist` produces two records with the identical site key
   `('inject_daemons.launch_daemons', 'launchd.plist', 0, 'launchd.plist')`;
   `flush()` keeps the first and warns away the second. Expected 2, got 1. A
   *correct* Swift port then fails `comparePatchRecords()` on count. Use the
   full `file` path. This was introduced by the fix for the bytes-keyed version
   of the same bug, from the other side.

2. **`_assert_pristine_input` is caller-dependent, not structural**
   (`cfw_records.py`). Net (i) keys on the source path, and holds today only
   because `TEMP_DIR` is the fixed `$VM_DIR/.cfw_temp` (`cfw_install.sh:55`,
   `cfw_install_exp.sh:171`). Randomise that temp dir and every legitimate
   re-install becomes an "unfamiliar input" warning, while a chained
   already-patched input becomes an accepted one. It is also **not on the DSC
   path at all**: `cfw_dsc_chunks.py:258`, `cfw_dsc_codesign.py:304` and
   `cfw_patch_dsc_maxslide.py:87` reach `record`/`record_span`, which never
   call it.

3. **The degenerate-record guard has a hole** (`cfw_records.py:490`).
   `_assert_not_degenerate` runs only `if inline and original == patched`, so a
   >256 KiB whole-file rewrite to identical content still stores a record whose
   `originalBytes` equal its `patchedBytes`, as a `.opaque` record. Contained
   (`comparable: false`, warning, `records-status` exits 1), but the rule stated
   above — a degenerate record is an error, not a stored fact — is not what the
   code enforces.

4. **`take_cli_flag`'s `reserved` fix covers `cfw.py` only.**
   `cfw_patch_build_version.py:95`, `cfw_patch_post_restore_dt.py:328` and
   `campo_mach_lookup_exceptions.py:64` call it without `reserved`, and their
   positional *is* a path, so `_looks_like_root` always swallows it:
   `cfw_patch_build_version.py --emit-records <plist> 23B85` sets
   `root=<plist>`, prints usage and exits 2. `reserved` cannot fix that — a path
   cannot be excluded by name — so the containment is to make the separated
   value illegal, i.e. accept `--emit-records=<root>` only.

5. **Nothing in the repo exercises `cfw_records.py`.** `find tests -name '*.py'`
   is empty, the Makefile has no pytest target, and `tests/test_dropbear_plist.py`
   was deleted on this branch. Every guard described in this document — the
   dedupe key, both `_assert_pristine_input` nets, `_assert_not_degenerate`,
   `record_macho_lc_edit` — can be deleted and nothing goes red. Whatever
   replaces this file in Swift must land with tests that do go red.
