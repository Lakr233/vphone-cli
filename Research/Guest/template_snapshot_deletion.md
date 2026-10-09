# Deleting the orig-fs snapshot in the guest

Why the CFW-renamed system snapshot has to go before trimming files from the
system volume saves anything, what the iOS kernel requires to delete it, and
what was measured. The RPC is `apfs.snapshot.delete` (`Research/vphoned_http_api.md`,
"Removable system apps and APFS snapshots"). Measured 2026-10-07 on a
`--new-identity` clone of an iPhone17,3 iOS 27.0 (24A435) machine with a
vphone 2.7.0 local bundle, using a standalone prototype of the same calls.

## Why the snapshot pins the space

The restored system volume carries one snapshot, the sealed update snapshot
`com.apple.os.update-<hash>`. CFW install renames it to
`orig-fs.disabled.rn-<hash>` (`VPhoneAPFSSnapshot.rename`) and the patched
kernel (`kernel-boot-apfs_root_snapshot`) boots the live file system instead.
From then on the snapshot is an ordinary dangling snapshot, but it still
references every block of the system volume as it was before CFW.

Deleting files from the live system volume therefore frees nothing: the
snapshot keeps their blocks. In the experiment, 1.09 GiB of standard-tier
files were deleted from a host-mounted system volume (`usr/standalone/update`
353 MB, `SharingDeviceAssets` 232 MB, `NanoTimeKit` face bundles 144 MB, 57
non-English/Chinese `LinguisticData` packages 409 MB). The container's usage
went from 20,483,211,264 B to 20,483,629,056 B and the host `Disk.img` grew by
2,152 blocks. Nothing was reclaimed until the snapshot was deleted.

The snapshot's own extra cost is small. The system volume shrank about
21.5 MB more than the files deleted: the originals of the system files CFW
modified, which only the snapshot still referenced. Deleting the snapshot
without trimming files saves about 20 MB per template; the gain comes from the
trim the deletion makes effective.

## The host cannot do it

On the host, `diskutil apfs deleteSnapshot` on the attached guest container
fails with `-69863 Insufficient privileges`, as the user and as root, whether
the volume was mounted by the user or by root. The host's SIP (Filesystem
Protections) protects snapshots of a System-role volume. CFW install runs as
root under the same SIP, so this cannot move into the host-side install
either. Changing the volume role or editing APFS metadata offline was judged
too risky. The deletion happens in the guest.

## What the iOS kernel requires

From the strings of `kernelcache.research.vphone600` and the experiment:

| Requirement | Evidence | Result |
| --- | --- | --- |
| `com.apple.private.vfs.snapshot` | `"%s (pid %d) is missing vfs snapshot entitlements"`; candidates `com.apple.developer.vfs.snapshot`, `com.apple.private.vfs.snapshot`, `com.apple.private.vfs.snapshot.user`. Measured 2026-10-07 with a root prototype also signed `platform-application`: `developer` alone fails with EPERM, `private` alone deletes | vphoned carries `com.apple.private.vfs.snapshot` only. With `com.apple.developer.vfs.snapshot` alone, vphoned answered `not_permitted` |
| Root | XNU `fs_snapshot` checks `PRIV_VFS_SNAPSHOT` | vphoned runs as root |
| Not the volume's default root snapshot, not set to root or revert to, not mounted | `cannot delete snapshot '%s' because it is the default root snapshot…`, `…set to root from it`, `…set to revert to it…`, `cannot delete mounted snapshot` | `orig-fs.disabled.rn-*` meets none of them after CFW |
| No replication and no merge from an earlier deletion in progress | `Can't delete snapshots while volume is replicating`, `merge in progress due to previous snapshot deletion` | Not hit with a single snapshot; vphoned reports EBUSY as retryable |
| AMFI accepts the ad hoc signature's entitlements | JB patches: `AMFIIsCDHashInTrustCache` always true, `_postValidation` skipped | The binary ran with its entitlements |

That is why `apfs.snapshot.delete` deletes only names starting
`orig-fs.disabled.rn-`. Any other snapshot, `com.apple.os.update-*` above all,
may be the volume's root or revert target, and the guest may not boot without
it.

## Measured reclaim and TRIM timing

The prototype (`fs_snapshot_list` with `ATTR_CMN_RETURNED_ATTRS |
ATTR_CMN_NAME`, then `fs_snapshot_delete(open("/"), name, 0)`) ran as a root
launchd job after the files had been trimmed offline. It listed one snapshot,
deleted it on the first call and then listed none.

| Time | Host `Disk.img` blocks (512 B, `stat -f %b`) | Note |
| --- | --- | --- |
| after clone | 39,905,304 | baseline |
| files trimmed offline, image detached | 39,907,456 | snapshot holds the blocks |
| booted, before the deletion | 40,138,464 | first boot wrote about 118 MB |
| 14 s after the deletion | 38,044,176 | |
| 20–100 s after | 37,829,656 → 37,819,728 | settled: −2.32 M blocks, **1.19 GB** |

The system volume went from 16,212,312,064 B to 15,024,877,568 B
(−1,187,434,496 B), matching the host. The guest TRIMs the freed blocks and
the host image is hole-punched within about 15 seconds; a later reboot
reclaimed nothing more. A template's `Disk.img` is a restored, unshared file,
so the 1.19 GB returns to the host volume. On a clone, the blocks it shares
with its source are not freed by its own TRIM.

## The guest still boots

After the deletion the guest was stopped and started again. vphoned answered
within 10 seconds, `setup.status` reported setup done, 258 apps were
registered, 338 processes ran (SpringBoard, backboardd, sharingd and
mobileassetd among them), there was no panic and no new crash report, and the
volume still had no snapshot. The device tree's `root-snapshot-name` is the
original `com.apple.os.update-<hash>`, which CFW's rename already made
unfindable, and the patched kernel boots the live file system either way. The
CFW pipeline does not need the snapshot afterwards: a full `cfw install`
logs and continues when `VPhoneAPFSSnapshot.rename` finds no
`com.apple.os.update-*` snapshot, and `cfw update-environment` and `cfw
update-kernel` do not touch snapshots.

## Where it runs in the template build

As the first step of the template's setup boot, before `setup.skip`, and
after the offline file trim:

```json
{"method":"apfs.snapshot.delete","params":{"force":true}}
```

It depends only on vphoned answering, so a later step failing does not affect
it. It runs once, on the template: clones inherit an image without the
snapshot, and calling it on one is a no-op. The template's final check should
see `apfs.snapshots` return an empty list. No wait for TRIM is needed before
shutdown.

## Verified through vphoned

On 2026-10-08 a fresh template (iPhone17,3 iOS 27.0 24A435, vphone 2.7.0
local bundle with `com.apple.private.vfs.snapshot`) answered
`apfs.snapshot.delete {"force":true}` on its first setup boot with the
`orig-fs.disabled.rn-*` snapshot under `before` and `deleted` and empty
`after`; `apfs.snapshots` was empty afterwards and after a reboot, which came
back to the home screen with setup done. The reclaim could not be read off
the host image this time: there was no offline trim, and the first boot was
still writing about 2 GB while the snapshot went. The day before, the same call
from a vphoned with only `com.apple.developer.vfs.snapshot` answered
`not_permitted`.

## Reclaim in a template build

Measured on 2026-10-08 in a template build (iPhone17,3 iOS 27.0 24A435,
standard trim, then the setup boot with vphoned deleting the snapshot). The
host image cannot isolate it, because the setup boot writes first-boot state
at the same time, so the System volume's Capacity Consumed was read from the
stopped image (`diskutil apfs list` on a read-only attach) at each stage:

| Stage | System volume | Data | User |
| --- | --- | --- | --- |
| After `cfw install` and Launchpad's first boot | 16,209,444,864 B | 1.17 GB | 0.46 GB |
| After `vm template trim --tier standard` (1.166 GB of files) | 16,209,846,272 B | | |
| After the setup boot | 15,022,374,912 B | 1.67 GB | 0.69 GB |

The System volume shrank by 1,187,471,360 B (1.19 GB): the 1.166 GB trimmed
plus about 21.6 MB held only by the snapshot, the same split as the prototype
run. On the host, `Disk.img` (sampled every 2 s) went from 17.948 GB to
16.620 GB within about 10 s of the snapshot step, then grew back with the setup
boot's writes to 17.545 GB at shutdown. The 1.33 GB drop is 0.14 GB more
than the System volume's, probably discards from the other volumes in the
same seconds. The frozen template was 17.58 GB, against 18.92 GB for a
template with neither trim nor setup boot and 19.3 GB for one with a setup
boot and no trim.
