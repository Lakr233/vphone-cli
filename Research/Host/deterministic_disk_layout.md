# Deterministic disk layout: why it was not done

Two machines restored separately from one IPSW hold mostly the same bytes,
but only 44% of them at the same offset in `Disk.img`, and `vm rebase` can
share only same-offset blocks ([disk rebase](disk_rebase.md)). This note
records what the shifted bytes are, why they shift, what it would take to
pin them, and why that was not worth it once templates existed. Studied on
2026-10-07 by measurement, reading and offline allocation experiments, with
no restore run. Part of the [disk-space study](disk_space.md).

## Summary

- The shifted region is mainly the OS and App cryptexes that `cfw install`
  copies onto the System volume on the host: 7.35 GB (dyld cache 7.18 GB) of
  the 9.9 GB that differs only in position. The other ~2.5 GB is Data, User
  and some Preboot content the guest writes during the restore's `fixup_var`
  and the first boot.
- Restore writes the same large data in both machines. What differs are
  per-device small writes (the APTicket is 5805 bytes on one and 5806 on the
  other, ECID-derived files, keybags, log timestamps) and the guest's own
  concurrency during restore.
- The host's APFS allocator is deterministic but chaotic: a few blocks of
  difference before a large copy move all of it by hundreds of MB.
- The only way to pin the cryptexes is to merge them into the root file
  system before the restore, so ASR writes them block for block. That would
  raise same-offset sharing to about 81% (15.8 of 19.4 GB), not more.
- Not done: with templates, separately restored machines are the exception,
  and the cost is a rebuilt, resealed root file system per IPSW.

## What shifts

Method: two booted machines, iPhone99,11 iOS 27.0 (24A435) + cloudOS 26.4,
standard preset, each attached read-only with System and Preboot mounted
read-only (Data and User are locked). Each file's physical extents
(`F_LOG2PHYS_EXT`, plus the partition offset of 20,480 bytes) gave its offset
in the image; a sample was checked byte for byte. The 217,000
decmpfs-compressed root file system files cannot be mapped this way; they sit
in the ASR region, at the same offset in both.

Layout of one image:

| Image offset | Content |
| --- | --- |
| 0 – 1.07 GB | APFS metadata, Preboot, guest-written Data |
| 1.07 – 9.93 GB | The root file system ASR wrote and `apfs_invert` turned into the System volume: the same offset in both machines |
| Small holes inside that | Small cryptex files (even-numbered dyld subcaches of 0.2–0.5 MB, the atlas) filling free extents inside the ASR image |
| 9.93 – 10.63 GB | About 600 MB of unmapped plaintext, guest-written Data/User |
| 10.63 – 16.50 GB | dyld subcaches `.21`–`.77`, `.dyldlinkedit` and `.symbols` (1.22 GB): 30 files, 5.85 GB, one extent each |
| 16.50 – 19.9 GB | About 3.4 GB unmapped: first-boot Data/User |
| 62.0 – 64.0 GB | Odd subcaches `.01`–`.19` (about 1.3 GB), the DriverKit cache, a QuartzCore metallib and a few CFW-modified System files. In the guest this is the APFS metazone (`metazone … encrypted: 15136710-15380850` in the restore log); the host's mount does not reserve it, so the first large files copied land there |

The two machines' 81 dyld cache files had identical SHA-1s (CFW from two
different bundle builds patched them identically), yet moved:

| Group | Size | Shift (B − A) |
| --- | --- | --- |
| Subcaches `.21`–`.77`, `.symbols` | 5.85 GB | −6415 blocks (−26.3 MB) |
| Subcaches `.07`–`.19` (metazone tail) | 0.92 GB | −36 blocks |
| `.03`, `.05` | 0.26 GB | −1 block |
| `.01` | 0.13 GB | −219 blocks |
| 224 small cryptex files | 8 MB | −1358 blocks |
| Uncompressed root file system files | 4.55 GB | 4.49 GB at the same offset |

A content-hash comparison at any offset gave: of B's 19.4 GB non-zero data,
8.45 GB at the same offset as A (44%), 9.89 GB present in A elsewhere, 1.04 GB
unique to B. By region of B:

| Region of B | Same offset | Shifted | Unique |
| --- | --- | --- | --- |
| 0 – 1.07 GB | 0.00 | 0.38 | 0.24 |
| 1.07 – 9.93 GB (ASR) | 8.43 | 0.26 | 0.01 |
| 9.93 – 16.37 GB (cryptex bulk) | 0.02 | 6.12 | 0.09 |
| 16.37 – 19 GB (Data/User) | 0.00 | 1.50 | 0.66 |
| 62 – 64 GB (cryptex tail) | 0.00 | 1.63 | 0.04 |

The 1.5 GB of shifted Data/User content in B lies in A at 0.6–1.08 GB,
3.4 GB, 10.3–10.6 GB and elsewhere, displaced by tens of MB to 16 GB: the
guest's allocator put identical content into different holes.

## Why it shifts

The order of writes: restore partitions and creates the container,
preallocates a 10.1 GB `/mnt1/apfs_invert_asr_img`, streams ASR into it and
inverts it into the System volume; then installs the kernelcache, device tree,
root hash and ticket into Preboot, runs `fixup_var` on Data, the recovery OS
restore, `seal_system_volume`, `create_system_snapshot` and
`split_data_volume`. Afterwards `cfw install` on the host copies the cryptexes
(`installCryptexes`: `VPhoneConfinedDirectory.copyTree`, names sorted,
depth-first, `fcopyfile(COPYFILE_DATA)` per file). The dyld cache patches
after that write in place and allocate nothing. So where the cryptexes land
depends only on the container's allocation state when the restore ends and on
the host allocator.

The two restores' space-manager statistics, from their logs:

| Point | A | B |
| --- | --- | --- |
| Container created | 15,595,537 free / 10 extents | same |
| After invert | 13,078,288 free / 13 extents | same |
| Around seal | 13,265,750 / 4625 extents → 13,157,004 | 13,265,759 / 4624 → 13,157,013 |
| `split_data_volume` | 13,156,553 / 4538 extents | 13,156,562 / 4530 extents |
| Restore end | 13,251,848 | 13,251,857 |

Nine blocks apart. Step durations differed widely (`fixup_var` 6 s against
22 s, `seal_system_volume` 25 s against 94 s), which changes which small file
lands in which hole; Preboot showed the same firmware file at different
places in the two.

### The host allocator, offline

On a scratch 20 GB raw APFS image (`diskutil image create blank --format RAW
--fs APFS`), each trial cloned an identical copy, mounted it and copied A's
`System/Cryptexes/{OS,App}` (7.35 GB, 3345 extents) with a C reimplementation
of `copyTree`, then mapped the result:

| Trial | Same offset as the first run | Note |
| --- | --- | --- |
| The same copy twice more (7 s and 17 s) | 100% | Same state and order: fully deterministic, timing does not matter |
| `F_PREALLOCATE` every file first | 100% | Preallocation does not change placement |
| An 80 MB file written first | 1.4% | Most moved +1 to +5 MB |
| Three small files (1 + 2 + 3 blocks, 24 KB) first | 0.6% | 7.2 GB moved +268.4 MB (65,536 blocks: the start of the 3-block allocation zone) |
| Eight small files (144 KB) first | 0% | Moved +402.7 MB (98,304 blocks) |
| Container padded to a fixed 1000 MB used first | 99.4% | Works only if the earlier difference was one contiguous file |
| Padding plus three small files | 0% | Moved +309 MB |

Placement follows the free-extent table and the per-size allocation-zone
cursors. A few blocks of difference shift a large file by hundreds of MB.
The real machines differ by one to a few thousand blocks, so their shifts are
small, but for same-offset sharing one block is as bad as a gigabyte.

## Ways to pin it

| Approach | Result |
| --- | --- |
| Fixed copy order on the host | Already fixed (sorted). The start state is the problem |
| `F_PREALLOCATE` | Changes nothing (trial above) |
| Copy before the variable writes | Those happen inside the guest's restore, before `cfw install` can run |
| Pad the container to a fixed usage, or fill below a boundary | Defeated by a few small files, which is exactly the real difference |
| Write blocks to fixed offsets on the host and fix up APFS metadata | Means writing an APFS writer (fs tree, extent references, space manager, checkpoints) |
| Clone ranges between files on the host | macOS has no public range-clone call; `clonefile` is whole-file |
| **Merge the cryptexes into the root file system before the restore** | Works in principle: the ASR region already matches block for block, and both containers had identical free-extent statistics after the invert. The `.less` variant's `CryptexFilesystemPatcher` does this merge (mount OS, SystemOS and AppOS, copy, rebuild trust cache, mtree, digest and root hash, `Ap,SystemVolumeCanonicalMetadata`), but it runs only for `.less` (`FirmwarePipelineComponents.swift`). After the merge `installCryptexes` finds both directories populated and only creates the links, and the in-place dyld cache patches keep identical bytes identical |
| The cryptexes as a second virtual disk per IPSW, cloned per machine | Would share 100% regardless of layout, but dyld needs the cache before launchd, so the guest would have to mount it at early boot: a redesign of how CFW wires in the cryptexes. Untested, highest risk |

The ASR merge was not prototyped. It needs, per IPSW, decrypting and
rebuilding a 16–17 GB root file system and a real restore to check boot, and
these questions answered first:

- whether TSS signs a changed `OS`, `SystemVolume` and
  `Ap,SystemVolumeCanonicalMetadata` on the JB path (the JB kernel already
  bypasses the root snapshot seal check, `authapfs_seal_is_broken` and the
  graft's root hash check, and iBoot's image4 callback is bypassed);
- the preallocated invert image growing from 10.1 GB to about 17.5 GB, and ASR
  transfer from 62–95 s to roughly 2–3 minutes;
- how much of the merged cryptex content ends up compressed (System volume
  size only; it does not affect determinism).

## Decision

- Reachable same-offset sharing: about 81% (8.45 + 7.35 ≈ 15.8 of 19.4 GB),
  not the 96% that is identical at some offset. The ~2.5 GB the guest writes
  is placed by the guest's allocator and spreads further with every boot.
- Cost: a decrypted, merged and resealed root file system per IPSW (minutes
  of work and a 16–17 GB artifact to cache or rebuild), about 80% more restore
  transfer, the `.less` merge path revived and maintained for JB, and
  unverified TSS and boot-chain risk.
- Gain: about 7.35 GB more shared per separately restored machine, and only
  after `vm rebase`. Template clones already share nearly everything; separate
  restores remain for machines that need their own SEP secret
  (`--no-template`).

Not done. If separate restores become the norm, start from the ASR merge and
verify TSS and boot on one test machine first. Until then `vm rebase` between
separate restores recovers what happens to line up: 8.7 GB (about 43%) for
the pair measured here. One later rebase of a separately restored machine
onto a template of the same build shared 13.7 GB of about 18.2 GB
([disk rebase](disk_rebase.md#measurements)), which suggests the cryptex copy
landed at the same offsets there, as it would if the two restores happened to
end in the same allocation state; that case was not analysed.
