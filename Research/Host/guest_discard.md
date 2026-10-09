# Guest TRIM and offline compaction

Whether space the guest frees inside `Disk.img` returns to the host, and
whether an offline `vm compact` would be worth having. Measured on 2026-10-06
on two `vm clone` copies of a stopped iOS 27.0 (24A435) / cloudOS 26.4 machine
with a 32 GB image: one written to, deleted from and hole-punched, the other
left alone as a control. Part of the [disk-space study](disk_space.md).

## Summary

It does, and no change is needed. With the attachment vphone uses,
`VZDiskImageStorageDeviceAttachment(url:readOnly: false)` on a
`VZVirtioBlockDeviceConfiguration` (default caching and synchronization
modes, raw sparse file, `VPhoneVirtualMachine.swift`), the guest's discards
reach the host and deallocate the file's blocks:

- 2.1 GB written into the guest and deleted came back to the host within
  15 s, to within 9 MB of the baseline.
- Every APFS mount in the guest also trims all free space.
- After a clean shutdown, APFS-free but host-allocated space was 16.9 MB, the
  1–2 block extents APFS declines to trim. Punching those out offline changed
  nothing observable in the guest.

So there is no guest kernel patch to write and no `vm compact` worth adding.
What occupies the host is what the guest really holds, and blocks a clone has
stopped sharing.

## The guest driver negotiates discard

From the vphone600 research kernelcache:

- `com.apple.driver.AppleVirtIO` matches standard virtio-blk
  (`IOVirtIOPrimaryMatch` `0x00021af4`) as `AppleVirtIOBlockStorageDevice`.
  Its feature mask is `0x3a66`, which includes bit 13,
  `VIRTIO_BLK_F_DISCARD`, and not bit 14, `WRITE_ZEROES`. When discard is
  negotiated it reads `max_discard_sectors` and `max_discard_seg` from the
  device config (offsets 0x24 and 0x28; `discard_sector_alignment` is not
  read), and its `doUnmap` override splits extents by those limits and sends
  DISCARD requests (type 0xb, segments `{u64 sector, u32 sectors, u32 flags}`).
  Without the feature, or with either limit 0, it returns
  `kIOReturnUnsupported` like the `IOBlockStorageDevice` base. With it, the
  device publishes `IOStorageFeatures` `{Unmap = true}`.
- The root disk actually attaches through `com.apple.iokit.AppleVirtIOStorage`
  (`…/AppleVirtIOStorageDevice/AppleVirtIODiskStorageDevice@1/IOBlockStorageDriver`
  in the boot log), which overrides `doUnmap` too. Either path supports unmap.
- APFS has both paths: a full free-space trim at mount
  (`nx_mount_initiate_free_space_trims`, `spaceman_scan_free_blocks`) and
  unmaps at run time (`spaceman_trim_free_extent_callback`).

The host side was not disassembled, so the exact call Virtualization makes is
not confirmed. That the file's `st_blocks` drops after a guest delete shows
the blocks are deallocated (a punched hole) rather than written with zeros,
which would leave `st_blocks` unchanged. Behaviour under non-default caching
or synchronization modes was not tested.

## Measured

Guest side, the APFS mount log of the first boot:

```text
spaceman_scan_free_blocks:4431: disk1 scan took 0.567917 s, trims took 0.567313 s
spaceman_scan_free_blocks:4444: disk1 2950981 blocks trimmed in 6916 extents (82 us/trim, 12190 trims/s)
spaceman_scan_free_blocks:4455: disk1 trims dropped: 3068 blocks 2500 extents, avg 1.22
```

"trimmed" rather than an error is itself evidence that discard was
negotiated; with `doUnmap` unsupported APFS would not count them.
(`device.ioreg` returns class and name only and stops at 300 entries, so it
could not show `IOStorageFeatures`.)

Host side, `stat -f %b Disk.img` in 512-byte blocks:

| Event | Blocks | GB |
| --- | --- | --- |
| Cloned, not booted | 38,834,784 | 19.884 |
| First boot (its mount trim freed 117 MB) | 38,605,416 | 19.766 |
| Baseline before writing | 39,051,656 | 19.994 |
| `files.copy` of 16 dyld subcaches (~131 MB each) into `/var/mobile` | 43,150,728 | 22.093 |
| One minute later | 43,153,744 | 22.095 |
| `files.remove {recursive}` returned | 40,861,912 | 20.921 |
| 15 s later | 39,068,848 | 20.003 |
| 2 minutes later | 39,069,520 | 20.004 |
| After `system.reboot` (mount trim freed ~106 MB more) | 38,864,064 | 19.898 |
| After `vm stop` | 39,285,120 | 20.114 |

2.099 GB written, 2.092 GB returned within 15 s; the difference is the
guest's own writes meanwhile. The reboot's mount trim reported `2922515 blocks
trimmed in 7101 extents` and `trims dropped: 3959 blocks 2646 extents`. APFS's
used space at that point was (7,812,490 − 2,922,515) × 4096 = 20.03 GB, against
19.90 GB the host had allocated: the host held less than APFS counted as used
(some allocated APFS blocks were never written), so almost nothing was left to
reclaim.

## Offline analysis

A standalone prototype (not in the repository) read a stopped image without
keys and with no mount: GPT entry → container superblock → the checkpoint
descriptor area's newest valid NXSB (Fletcher-64) → the checkpoint map entry
for the space manager → its chunk-info and chunk-info-address blocks → the
allocation bitmaps. Free runs were intersected with the file's data ranges
(`SEEK_DATA`/`SEEK_HOLE`).

```text
block size 4096, blocks 7812490, latest xid 26277, spaceman oid 1024
spaceman@14538: blocks 7812490 chunks 239 cibs 2 cabs 0 free 2895575 (11860 MB) freeQueues [19, 9, 0]
host: size 32000000000, st_blocks*512 20113981440, data extents 6485
reclaimable (APFS-free but host-allocated): 16932864 bytes in 963 ranges
```

The bitmap's free count equalled the space manager's `sm_free_count`
exactly. Punching the 963 ranges with `F_PUNCHHOLE` freed exactly
16,932,864 bytes, and a second run found nothing. The punched clone booted,
its mount trim reported the same free count, vphoned answered, and
`diagnostics.self_test` gave the same 7 passes and 3 failures as the untouched
control (accessibility frontmost check, OCR, keychain persistence: properties
of the source machine).

Rules for doing this safely, if it is ever wanted:

- Space manager, checkpoints and bitmaps are unencrypted container metadata;
  no keys are needed to know which blocks are free.
- Only blocks the bitmap marks free may go. Keybags, checkpoint areas, the
  object map, the space manager itself and blocks a snapshot references are
  all marked allocated. Blocks in the free queues are still marked allocated
  and are skipped.
- Only a cleanly stopped image. Punching blocks free in the newest checkpoint
  but used by an older one removes APFS's ability to fall back to the older
  checkpoint, which a crashed image may need.
- macOS `fsck_apfs -n` verifies only the container: it stops at the container
  keybag, which the guest's SEP wraps (the control image fails identically).
  The only check of the volumes is booting the guest.
- On a clone, punching frees only blocks the file does not share.

`vm compact` would save 10–20 MB per machine. The one case where it would
help, an image written and emptied before any trim ran, is handled just as
well by booting it once and letting the mount trim run.
