# Disk rebase: sharing identical blocks between machines

Why two machines restored from one IPSW share nothing on disk, how
`vm rebase` makes them share what is identical, and what was measured. The
implementation is `VPhoneDiskRebase` in
`VPhoneKit/VPhoneCoreKit/Bundle/VPhoneDiskRebase.swift`; user-facing
behaviour is in `Documents/Guides/create-and-run.md` ("Sharing disk space
between VMs").

## The problem

`vm clone` shares every block with its source through `clonefile(2)`, but two
machines restored separately share none, although the restore writes much the
same bytes into both. Measured on 2026-10-06 with two iPhone99,11 machines
restored from iOS 27.0 (24A435) on cloudOS 26.4 (23E5207q): of about 20 GB
of data in each 64 GB sparse `Disk.img`, 8.6 GB is byte-identical at the same
offset, mostly the ASR-restored system volume between roughly 1 GB and 9.7 GB
into the image. Physical sharing between them, by `F_LOG2PHYS_EXT`, was 0.
Most of the rest is identical too, but at other offsets: chiefly the cryptexes
`cfw install` copies on the host, which a few blocks of difference in the
restore's end state move as a whole (see
[deterministic disk layout](deterministic_disk_layout.md)). A rebase cannot
share those.

## Method

macOS has no public call that clones a range of one file into another, so a
block cannot be deduplicated in place. A whole file can be cloned, though:

1. `clonefile` the base's image into `<target>/.rebase-<uuid>/Disk.img`, on the
   target's volume. The staging file shares every block with the base. Off
   APFS, or across volumes, `clonefile` fails and the rebase is refused; there
   is no full-copy fallback.
2. `ftruncate` it to the target's logical size.
3. Walk the union of both files' data ranges (`SEEK_DATA` / `SEEK_HOLE`) in
   8 MiB chunks with `F_NOCACHE`. Where the two read the same, the base's
   block stays. Where they differ, the target's bytes are written, runs of
   differing units in one `pwrite`; where the target reads as zeros (a hole,
   or zero-filled blocks) the unit is punched with `F_PUNCHHOLE` instead, so
   the result stays sparse. A partial unit at the end of the file is always
   written.
4. `F_FULLFSYNC`, then compare the staging file with the target over the
   union of their data ranges (outside it both read as zeros): every byte.
   Any difference refuses the rebase.
5. Give the staging file the target's owner, mode and times, check both
   machines are stopped and the target image's inode, size, mtime and ctime
   are what they were at the start, then `rename(2)` it over `Disk.img`.

The result holds exactly the target's bytes. Only the disk image changes:
`SEPStorage`, `nvram.bin` and `config.plist` are untouched, and since the
guest reads the same bytes, the SEP/keybag pairing and the identity are
unaffected (see [machine identity](machine_identity_and_clone.md)).

Both machines are checked stopped with `VPhoneBundleActivity.requireStopped`
before anything starts and again before the swap, after every descriptor is
closed (the check counts this process too). A write stops while the volume
would have less than 4 GiB free, so a rebase does not fill the disk under
running machines.

### The unit is the 16 KiB page, not the 4 KiB block

APFS on this Mac reports 4 KiB blocks (`f_bsize`), but a write into a cloned
file replaces whole VM pages. Measured on macOS 27 with `F_LOG2PHYS_EXT` after
`F_FULLFSYNC`, on a 1 MiB clone:

| Write into the clone | Blocks that stopped being shared |
| --- | --- |
| 4 KiB at 64 KiB, `F_NOCACHE` | 4 (64–80 KiB) |
| 8 KiB at 68 KiB, inside one page | 4 |
| 16 KiB at 68 KiB, across a page boundary | 8 |

Comparing 4 KiB blocks would count blocks as shared that the write beside
them takes away, so `VPhoneDiskRebase.blockSize` is `getpagesize()` (16 KiB)
and a differing unit is written whole. `F_PUNCHHOLE` itself works at 4 KiB.

### APFS fills small holes

A file written sparse does not stay sparse at every scale: after
`F_FULLFSYNC`, a 4 MiB and a 32 MiB file with 256 KiB of data came back as
all data, and in a 64 MiB file a hole of about 16 MiB between two extents was
filled while a 23 MiB one was kept. Holes punched with `F_PUNCHHOLE` stayed.
This only matters for the unit tests, which use 64 MiB images with large
gaps; a 64 GB `Disk.img` keeps its holes.

### Already shared blocks

Byte-identical is not the same as a saving. Two machines cloned from one
template (`vm create` clones `<library>/.templates/<id>/` with `clonefile`)
read the same bytes over most of their images because they are the same
blocks. Until 2026-10-09 every identical unit counted as shared, so a dry run
of one such clone onto another (live test of PR #633, R1) reported "shared
17.26 GB, written 0.36 GB" although the target held only about 0.35 GB of
blocks of its own (by `F_LOG2PHYS_EXT`): the rebase would have freed nothing.

Before comparing, `plan` and `rebase` now map both images with
`F_LOG2PHYS_EXT`, one call per contiguous extent over the `SEEK_DATA` ranges
(`ImageFile.physicalRuns`), and intersect the two maps
(`VPhoneDiskRebase.sharedRanges`): a file offset where both files point at
the same device offset is already shared. An identical unit then splits
into:

- **newly shared** (`newlySharedBytes`): the target's data there that is not
  already the base's. These are the blocks the rebase gives back, so the
  headline of both outputs is this figure.
- **already shared** (`alreadySharedBytes`, the rest of `sharedBytes`):
  blocks that already are the base's, or a hole in the target. Sharing them
  again frees nothing.

The map is taken from the two original images, before the staging clone
exists, so a dry run and the rebase report the same figures. Nothing else
changes: the staging file is a clone of the base, so an already shared unit
is neither read differently nor written. A volume that does not map files
gives no ranges, and every identical byte of target data counts as newly
shared, as before. Unlike APFS's private size, a Time Machine local snapshot
does not make blocks look shared here: only the two files are compared (see
the disk-use section of [machine templates](machine_templates.md)).

When the newly shared bytes stay under 0.1 GB the command adds "the rebase
would free almost nothing" and says why: the identical blocks are already
shared, or few are identical. Before comparing it also notes when the
records say both sides come from one template build: the target's
`TemplateSource.plist` names the template given as `--onto`
(`VPhoneMachineTemplateSource.isClone(of:)`), or both machines' records name
the same template and `Build` (`VPhoneDiskRebaseBase.commonTemplate`).

### A template as the base

`--onto` takes a machine name or a template identifier (or unique prefix,
as `vm template` takes it), resolved by `VPhoneDiskRebaseBase.resolve`; a
machine whose name matches wins. A frozen template is never booted, so its
image never drifts, which makes it the base the caveats below ask for. The
rebase only reads and clones the template's image. The rebased machine gets
no `TemplateSource.plist`: it keeps its own `SEPStorage`, NVRAM and
identity and only shares disk blocks, so `vm template list/show`, Launchpad
and `vm delete`'s "no longer used" note do not count it as a clone. A
machine that already had a `TemplateSource.plist` keeps it.

## Caveats

- The space comes back only when the old image's blocks have no other owner.
  A snapshot of the target, or a clone made from it, keeps them, and the
  rebase then costs the written bytes instead of saving the shared ones.
- `du` and Finder count each image at its full size; `df` is the measure.
- Both images diverge again as either machine writes. A base that is never
  booted, a template, makes the best one.

## Measurements

Live test on 2026-10-07 (macOS 27, APFS volume holding `~/.vphone/machines`),
with the Debug `vphone-cli` from the build directory. Two machines restored
separately from iOS 27.0 (24A435), iPhone99,11 on cloudOS 26.4:
`rbtest-a`, a clone of one, and `rbtest-b`, a clone of the other, made with
`vm clone`. A plain clone keeps sharing every block with its source, so a
rebase of it would release nothing; `rbtest-a`'s image was first copied
extent by extent into a file of its own (21.0 GB of data, `df` down by the
same), so that the old image's blocks had no other owner.

| | Before | After |
| --- | --- | --- |
| Physical sharing `rbtest-a` / `rbtest-b` (`F_LOG2PHYS_EXT`) | 0.00 GB | 8.69 GB |
| `rbtest-a` data / held only by it | 21.04 GB / 21.04 GB | 20.64 GB / 11.95 GB |
| Free space (`df`, 1K blocks) | 66,360,908 | 75,132,760 (+8.77 GB) |
| SHA-256 of `rbtest-a/Disk.img` (64 GB) | `c14ced17…c27810d` | `c14ced17…c27810d` |

In the output format of the time, before shared bytes were split:

```text
$ vphone-cli vm rebase rbtest-a --onto rbtest-b
rebased rbtest-a onto rbtest-b in 00:17
  disk image  64.00 GB  logical size; 21.09 GB holds data in either image
  shared       8.73 GB  identical to rbtest-b at the same offset, now shared
  written     11.95 GB  differs from rbtest-b, written
  punched      0.29 GB  zeros where rbtest-b has data, now holes
```

- `--dry-run` printed the same figures in 5 s; the rebase, with its full
  verification pass, took 17 s.
- The bytes held only by `rbtest-a` afterwards equal the bytes written. The
  8.73 GB counted as shared and the 8.69 GB `physshare` finds differ by 0.5%,
  probably because the report counts whole 16 KiB units, and a unit where
  the base holds data in only some of its 4 KiB blocks counts in full.
- Other machines were running and restoring on the volume during the test,
  so `df` moves by a few hundred megabytes on its own; the +8.77 GB was read
  immediately before and after the 17 s run.
- The modification time of `Disk.img` was kept. A rebase between two plain
  clones of one machine (identical images) shared all 21.02 GB, wrote
  nothing and took 26 s.
- Boot: `vm clone rbtest-a rbtest-boot --new-identity`, then
  `vphone-launchpad-cli vm start rbtest-boot --headless --wait`. The guest
  booted with a new UDID and vphoned answered `device.info` (iOS 27.0.0,
  uptime 32 s); no panic in the console log. Stopped with `vm stop`.
- Deleting the three test machines afterwards returned 12.3 GB: the 11.95 GB
  written plus what `rbtest-boot` wrote while it ran.

Already-shared accounting, 2026-10-09, Release `vphone-cli` on a scratch
library (no real machine): `rb-a` with 2 GiB of random data at 1 GiB in a
64 GB sparse image, `rb-b` and `rb-c` `clonefile` copies of it, `rb-b` then
given 256 MiB of new bytes and 256 MiB rewritten with the same bytes, and
`rb-d` the same 2 GiB written into a separate file.

```text
$ vphone-cli vm rebase rb-b --onto rb-c --dry-run
note: rb-b and rb-c were both cloned from template 3f2a91c0d4e7 and already share its blocks; expect little to be newly shared
dry run: 0.27 GB would be newly shared with rb-c; compared rb-b in 00:00, nothing was changed
  disk image      64.00 GB  logical size; 2.15 GB holds data in either image
  newly shared     0.27 GB  identical to rb-c at the same offset, would be shared
  already shared   1.61 GB  identical, and already the same blocks on disk (or a hole): frees nothing
  written          0.27 GB  differs from rb-c, would be written
  punched          0.00 GB  zeros where rb-c has data, would become holes

$ vphone-cli vm rebase rb-c --onto rb-a --dry-run
dry run: 0.00 GB would be newly shared with rb-a; …
note: the rebase would free almost nothing: rb-c already shares its identical blocks with rb-a on disk
```

(The template note came from hand-written `TemplateSource.plist` files.)
`vm rebase rb-d --onto rb-a` reported 2.15 GB newly shared and `df` rose by
2,097,212 KiB (2.15 GB); a dry run of it afterwards reported 0.00 GB newly
and 2.15 GB already shared. Mapping both images took well under a second.


A separately restored machine onto a template, 2026-10-09: a `--no-template`
machine (no trim, no setup boot) and a trimmed template, both built from iOS
27.0 (24A435) / cloudOS 26.4 by the same bundle build, the machine stopped.
`vm rebase <machine> --onto <template id> --dry-run` took 4 s and reported
13.70 GB newly shared, 0.03 GB already shared, 4.46 GB written and 0.11 GB
punched; the rebase itself took 10 s and printed the same figures. `df` rose
by 13,445,384 KiB (13.77 GB); the newest Time Machine local snapshot predated
the machine, so none held the old blocks. The template's `Template.plist`,
`Disk.img` size and modification times and its `vm template show` output were
unchanged, and it listed only its own clones as users. The machine got no
`TemplateSource.plist`, kept its `SEPStorage`, `nvram.bin` and `config.plist`
untouched, booted with its own UDID with vphoned answering in 5 s and no
panic. A dry run afterwards reported 0.00 GB newly and 13.72 GB already
shared, with the "free almost nothing" note; so did one onto a clone of the
template.

13.70 GB is well above the 8.7 GB two separately restored machines shared:
in this pair the host's cryptex copy probably landed at the same offsets
too, which the layout study found depends on the two restores ending in the
same allocation state ([deterministic disk layout](deterministic_disk_layout.md)).
Why it did here was not analysed, so expect anything between the two figures.
