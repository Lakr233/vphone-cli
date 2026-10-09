# Where a VM's disk space goes

The disk-space study of 2026-10-06 to 2026-10-09: what a machine's ~20 GB is
made of, what each way of saving it was measured to save, and why one
template per firmware with new-identity clones became the default. The
mechanisms have notes of their own, linked below; this note keeps the
composition, the comparison and the end-to-end numbers.

Unless stated otherwise the guests are iPhone17,3 (or iPhone99,11) on iOS 27.0
(24A435) with cloudOS 26.4 (23E5207q), standard preset, a 64 GB sparse
`Disk.img`, on an APFS host volume. Block sharing was measured with
`fcntl(F_LOG2PHYS_EXT)` on both files ("physically shared"), not with `du`.

## Summary

- A restored machine that has booted once allocates about 20.5 GB. About
  8.6 GB of it is the IPSW's root file system, 7.2 GB the OS and App
  cryptexes `cfw install` copies onto the System volume, and 2–5 GB the Data
  and User volumes' first-boot state. Building one also needs the ~11 GB
  restore tree and 13.5 GB of IPSWs.
- Space the guest frees comes back to the host by itself, within about 15 s
  (guest TRIM). There is nothing worth compacting offline
  ([guest TRIM](guest_discard.md)).
- The saving that matters is sharing. A template per firmware, and every
  machine a `clonefile` copy of it with a new ECID, costs each machine about
  0.35 GB after its first boots instead of 20.5 GB
  ([templates](machine_templates.md),
  [identity and clone](machine_identity_and_clone.md)).
- Everything else is small next to it and counts once per template, not per
  machine: the offline file trim 1.2 GB, the orig-fs snapshot itself about
  21 MB, deleting the IPSWs 13.5 GB per build. `vm rebase` gets back about
  8.7 GB per pair of machines restored separately ([disk rebase](disk_rebase.md)).
- Two further approaches were studied and not built: making the restore's
  disk layout deterministic ([deterministic layout](deterministic_disk_layout.md))
  and a content-addressed block store behind Virtualization's NBD client
  ([block store over NBD](content_addressed_block_store.md)).

## What a machine holds

### The machine folder

| Item | Size | Note |
| --- | --- | --- |
| `Disk.img` | 64 GB logical | Sparse. About 18.6 GB allocated after `cfw install` and before any boot; about 20.5 GB after the first boot (2026-10-07, two machines) |
| `nvram.bin` | 33.6 MB | Boot firmware and NVRAM; cloned, diverges by a few blocks |
| `SEPStorage` | 512 KB | |
| `.vphoned.signed` | 9.3 MB | The staged vphoned |
| `iPhone*_Restore/` | about 11 GB | Only while a machine is built; removed afterwards unless `--keep-artifacts` with `--no-template` |
| IPSW cache (outside the folder) | 12.3 GB iPhone + 1.2 GB cloudOS | Per build, shared by every machine of it |

### Inside `Disk.img`

Attached read-only (`diskutil image attach --readOnly --noMount`), a booted
machine's container showed:

| Volume | In use | Content |
| --- | --- | --- |
| System | 16.2 GB (Sealed: Broken) | Below |
| Data | 1.2–2.5 GB | FileVault, locked on the host |
| User | 0.5–2.7 GB | FileVault, locked on the host |
| Preboot | 61 MB | kernelcache 43 MB, SEP and other firmware 17 MB; `Preboot/Cryptexes/{OS,App}` empty |
| xART, Hardware | 10.5 MB, 6.3 MB | Gigalocker; activation UUID and ticket |
| Update | | Not mounted |

The container's "In Use" (21.0 GB) matched the image's allocated size: the
blocks `cfw install` freed on the host had been punched out of the file, so a
fresh machine carries no dead space.

The System volume is two layers:

- The sealed root file system restore wrote (ASR, then `apfs_invert`). CFW
  renames its snapshot to `orig-fs.disabled.rn-<hash>`, and the patched kernel
  boots the live volume. The snapshot still references the original 8.59 GB;
  of the CFW-modified files, only 35 MB of old versions are held by nothing
  else (21.5 MB measured when the snapshot was deleted, see
  [snapshot deletion](../Guest/template_snapshot_deletion.md)).
- The OS and App cryptexes (7.2 GB on the live volume), which `cfw install`
  copies from the restore tree into `System/Cryptexes/{OS,App}` and links in
  (`System/Library/Caches/com.apple.dyld` points into
  `System/Cryptexes/OS/…`). vphone boots without the cryptex graft
  (`cryptex1 sniff: ignition failed: 8` on every boot), so the System volume
  copy is the only one dyld finds. The snapshot does not hold these blocks.

The live volume by kind, deduplicated by inode, `st_blocks` (2026-10-07):

| Kind | Size | Layer |
| --- | --- | --- |
| dyld shared cache: 71 subcaches, data, readonly, linkedit, atlas | 5,955 MB | cryptex |
| dyld shared cache `.symbols` | 1,223 MB | cryptex |
| PrivateFrameworks (without localizations and models) | 2,989 MB | root fs |
| ML models (`.mlmodelc`, `.espresso`, …) | 1,021 MB | root fs |
| Other CoreServices, ExtensionKit, PreferenceBundles and the like | 902 MB | root fs |
| `LinguisticData` | 558 MB (418 MB outside en and zh-Hans) | root fs |
| `.loctable` (all languages in one file) | 434 MB | root fs |
| `PreinstalledAssetsV2/RequiredByOs` | 424 MB (SharingDeviceAssets 232 MB) | root fs |
| Frameworks, the rest | 400 MB | root fs |
| `usr/standalone` | 375 MB (SU ramdisk 243 MB, baseband firmware 114 MB) | root fs |
| Fonts | 373 MB (AppleColorEmoji 139 MB) | root fs |
| `usr`, the rest | 361 MB | root fs |
| Health assets and NanoTimeKit | 350 MB (watch faces 144 MB) | root fs |
| `/Applications` | 257 MB, 219 apps | root fs |
| `.lproj` of languages other than en, Base, zh-Hans | 220 MB | root fs |
| TTS and voice, audio tunings, ringtones, app placeholders, wallpapers | 530 MB | root fs |

The dyld cache is 45% of the System volume and can only be kept or replaced
whole. Most localizations live in `.loctable` files, all languages in one
file, so trimming languages from `.lproj` folders would save about 0.3 GB at
most.

### Data and User

The host cannot mount these volumes (their keys are wrapped by the guest's
SEP), so their content was only classified by block. After the first boot
they hold 2–5 GB: the restore's `fixup_var`, the first boot's data migration,
caches, logs and the expanded removable system apps. This is the part each
clone writes for itself; see the per-clone numbers below.

## What each approach saves

| Approach | Saving | Counts | Status |
| --- | --- | --- | --- |
| Guest TRIM | Deleted guest data returns within ~15 s; ~17 MB per machine left unreclaimed | Per machine | Works as shipped ([guest TRIM](guest_discard.md)) |
| Template + new-identity clone | 20.5 GB → about 0.35 GB per machine after its first boots | Per machine | Default for `vm create` and Launchpad 2.9 |
| Setup boot in the template | A clone's first 100 s write 1,040 → 372 MiB; private bytes after 7 min 3.2 → 0.6 GB | Per machine | Part of every template build |
| Offline trim, standard tier | 1.17 GB (conservative 0.36 GB) | Per template | Default tier ([templates](machine_templates.md#offline-trim)) |
| orig-fs snapshot deletion | About 21 MB itself; makes the trim free anything | Per template | Setup boot step 0 |
| Deleting the IPSWs | 13.5 GB | Per build | Offered by Launchpad once a template exists |
| `vm rebase` of separate restores | About 8.7 GB per pair (≈ 43%); 13.7 GB measured onto a template | Per machine | `vm rebase` |
| Service trimming | Idle writes −60% (27.0), −94% (26.6.2); first-boot writes about −35% | Per machine, writes | `trimmed` profile ([service trimming](../Guest/service_trimming.md)) |
| Deterministic disk layout | Same-offset sharing of separate restores from 44% to at most ~81% | Per machine | Not done |
| Content-addressed store over NBD | A further 30–40% over templates, mostly from compression | Whole library | Not done |

Projected host bytes for N machines per build and K builds (IPSW caches not
counted; template 18.6 GB, 0.35 GB per clone after first boots, 20.5 GB per
separately restored machine; the CAS column is 4 KiB blocks with LZFSE):

| N × K | Separate restores | Template + clones | CAS |
| --- | --- | --- | --- |
| 5 × 1 | 102 GB | 20.4 GB | 12.7 GB |
| 10 × 1 | 205 GB | 22.1 GB | 14.0 GB |
| 5 × 3 | 308 GB | 61.1 GB | 36.0 GB |
| 10 × 3 | 615 GB | 66.3 GB | 39.7 GB |
| 10 × 3, 3 GB written per clone | 648 GB | 146 GB | 95 GB |

`vm rebase` does not change the template column: templates of different
builds share no block at the same offset (0.00 GB between an iPhone 27.0 and
an iPad 26.6.2 image), and clones already share their template's.

## Why templates won

A template is the only approach whose saving grows with the number of
machines and costs nothing on the I/O path: a clone is a `clonefile`, the disk
stays a raw file the host can attach for `cfw install`, `cfw
update-environment`, the trim, `vm rebase` and snapshots, and Virtualization
keeps its write-back cache. Its costs are known and documented: every clone
shares the template's SEP root secret, gigalocker and volume keys
([shared secrets](machine_templates.md#shared-secrets); `--no-template` makes
a machine with its own), a template must never boot once frozen, and the disk
size is part of the key because no code grows a container after the restore
(a larger size needs another template).

Three places to trim the System volume were considered:

- Before the restore, in the IPSW's root file system image. The repository
  has the machinery (the `.less` variant's `CryptexFilesystemPatcher`), but
  it means decrypting and resealing an 8–9 GB image per IPSW, and whether TSS
  signs a changed `SystemVolume`/`Ap,SystemVolumeCanonicalMetadata` digest on
  the JB path was never tested. CFW then rewrites the result anyway.
- After `cfw install`, on the host, with the System volume mounted: chosen.
  No guest involved, repeatable, and a raw image is hole-punched when the
  volume is unmounted (a 1 GB file written and deleted on a test image left
  5.6 MB allocated after the unmount, 982 MB before it).
- Inside the running guest through vphoned: rejected when templates were
  still meant never to boot. The setup boot came later, for Setup and app
  removal, but the host-side trim stayed the simpler choice: it needs no
  writable System volume in the guest and no destructive RPC.

The catch was the snapshot: deleting root file system files on the host
frees nothing while `orig-fs.disabled.rn-*` exists, and the host cannot
delete that snapshot (SIP, `-69863` even as root). The guest can, so the
setup boot deletes it first ([snapshot deletion](../Guest/template_snapshot_deletion.md)).

Never trimmed: the dyld cache and its `.symbols` (the CFW cache patcher's
`DyldSharedCacheSymbolResolver` reads the local symbols, so a later
`cfw update-environment` on a clone would fail to find its patch sites), ML
models (Photos analysis, Spotlight, Live Text and the camera pipeline load
them; a missing model makes daemons crash or retry), and `/Applications`
(system UI and view services). The `aggressive` tier (other `.lproj`, Health
assets, some fonts; about 1.7 GB with the standard items) stays reserved because it was never
booted.

## Measured end to end

Template builds from scratch, Launchpad 2.9 driving bundle 2.9 builds, IPSWs
cached, seconds per step (2026-10-09). The setup boot is mostly the guest's
first-boot data migration ([Setup Assistant skip](../Guest/setup_assistant_skip.md#the-first-boot-after-a-restore)).

| iOS | prepare | patch | restore | stop DFU | `cfw install` | trim | setup boot | clone + first boot | total |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 27.0 | 6 | 22 | 83 | 8 | 67 | 2 | 79 | 5 | 4 min 39 s |
| 27.0 | 5 | 23 | 86 | 9 | 62 | 2 | 105 | 5 | 5 min 04 s |
| 27.0 | 5 | 23 | 114 | 8 | 58 | 2 | 89 | 7 | 5 min 14 s |
| 26.6.2 | 4 | 19 | 80 | 8 | 199 (about 160 s of it an administrator prompt) | 2 | 95 | 5 | 6 min 59 s |

The third 27.0 build's setup boot: connect 4 s, setup-skip 0 s, settle 63 s,
remove apps 5 s, service profile 0 s, reboot 10 s, verify 1 s, crash reports
1 s, stop 5 s. The first two ran the earlier `setup.skip`, which retried for
45–98 s while settle then took about 10 s
([setup boot](machine_templates.md#setup-boot)); the setup boot took about as
long either way, because the wait is the migration.

Machines from an existing template:

| Path | Time |
| --- | --- |
| `vphone-cli vm create --template <id> --skip-first-boot` | under 1 s (the clone itself 0.06 s) |
| Launchpad New Machine (find, clone, first boot until vphoned answers) | 6–9 s |
| Launchpad, IPSWs deleted (template found by its recorded sources) | 6 s |
| Before templates, a full restore per machine | 3.5–5 min iPhone, about 7.5 min iPad |

Sizes:

| Object | Allocated | Note |
| --- | --- | --- |
| Template, standard trim, setup boot | 17.4–17.7 GB | `Disk.img` 17.55 GB plus 43 MB of other files |
| Template, setup boot, no trim | 19.3 GB | |
| Template adopted after a plain first boot, no trim | 18.9 GB | Clones then reach 3.2 GB private after 7 min |
| Clone, 35 s after its first start | 0.34–0.37 GB private | |
| Clone, after 7 minutes | 0.59–0.61 GB private | The same with and without the trim: the trim saves per template |
| Clone of a stopped machine, two boots | 0.33–0.52 GB private | `vm clone --new-identity` |

The template's own private bytes stay at about 0.1 GB, the blocks every clone
has rewritten. Booting a template after clones exist raised one clone's
private bytes from 0.42 to 0.80 GB, which is why a frozen template never boots
([templates](machine_templates.md#never-booting-once-frozen)).

## Measuring it

- `du`, Finder and a folder's allocated size count every clone at its full
  ~18 GB. `df` before and after an operation is the honest total.
- Per object, compare physical extents (`F_LOG2PHYS_EXT`), as Launchpad's
  Exclusive column does. APFS's private size (`ATTR_CMNEXT_PRIVATESIZE`) reads
  0 for every object after each hourly Time Machine local snapshot, until it
  writes again ([disk use](machine_templates.md#disk-use)).
- `st_blocks` of a running machine's image is not monotonic: guest TRIM pulls
  it back. Writes by the VM are better read from the Virtualization process's
  `ri_diskio_byteswritten` (`proc_pid_rusage`).
- Deleting a template frees only its own blocks while clones exist; deleting a
  source frees nothing a clone still shares.

## Observation to verify: plaintext in Data and User blocks

The block-level survey for the block-store study
([content-addressed store](content_addressed_block_store.md#data-and-user-blocks))
found that the image region not mapped to System, Preboot, xART, Hardware or
Update files (Data, User and container metadata), although both volumes show
as FileVault locked on the host, is not uniformly ciphertext. On the iPhone
27.0 image about 2.0 GB of it compressed like plaintext (LZ4 ratio 0.55), and
blocks began with `SQLite format 3` (429 blocks), `bplist00` (4,006), a PNG
signature (874) and `caff` (711); 2.6 GB looked random. The iPad 26.6.2 image
showed 3.5 GB compressible and 4.2 GB random.

Read as it stands, someone holding a `Disk.img` could carve some guest file
contents out of it without the SEP. It has not been checked which files these
are, which protection classes they carry, or whether the content-protection
layer behaves differently on virtio storage than on Apple NAND. Treat it as an
open question, not a finding about iOS.

## Open items

- **Stop the DFU VM at the iBoot banner.** Every restore's post-restore reboot
  panics because the System volume has no dyld cache before `cfw install`,
  and `vm create` and Launchpad wait for that panic; its report then lands in
  the guest. Stopping at the banner would avoid both for every machine
  ([setup boot](machine_templates.md#setup-boot), last paragraphs on crash
  reports).
- **Cold template archives.** Compressing the `Disk.img` of a template no one
  clones any more (LZFSE, about 30–35% smaller by the block survey) and
  expanding it back before the next clone would take most of the block
  store's remaining gain without touching the I/O path. Not built.
- **ASIF images.** Virtualization's XPC service knows `.asif`, but whether
  discard frees blocks in an ASIF image was not tested. Raw sparse files
  already return freed space, `VPhoneAPFSSnapshot` reads and patches the image
  at raw byte offsets, and `vm rebase` takes file offsets for disk offsets;
  ASIF would only help where the host volume cannot hold a
  sparse file.
- **Growing a disk.** No code resizes a container after the restore, so a
  larger disk means another template or `--no-template`.
- **Revisit the block store** only if disk space is still the limit with
  templates, trim and IPSW deletion in place and three or more builds kept hot
  at once, or if Apple provides a host-mountable user-space block device or an
  NBD client with write-back and FLUSH
  ([content-addressed store](content_addressed_block_store.md#when-to-revisit)).
