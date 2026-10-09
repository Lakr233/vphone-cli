# Content-addressed block store over NBD: why it was not done

Whether serving machine disks from a deduplicating, compressing block store
through Virtualization's NBD client would save enough over templates to be
worth a storage subsystem. Studied on 2026-10-07 by measuring two stopped
images, probing Virtualization's NBD client with throwaway VMs and a
prototype server outside the repository; no vphone machine was booted on it.
Part of the [disk-space study](disk_space.md).

## Summary

Not now. Templates with new-identity clones already take most of the saving
(five machines of one build: about 102 GB → 20 GB). On top of that, a block
store would save roughly another 30–40%, almost all of it from two sources:

- compression (about 30%), which only a store can do for live disks;
- deduplication across builds (about 17% at 4 KiB), which matters only while
  several builds are kept.

That is 7–8 GB per build with one build, 25–50 GB with three builds of 5–10
machines each. The costs, several of them set by Virtualization and not by
the prototype:

1. The NBD client hands the guest a write-through disk and never sends FLUSH
   or FUA, so a server must make every write durable before replying or
   accept losing acknowledged writes on a host crash.
2. The host cannot attach an NBD disk. `cfw install`, `cfw
   update-environment`, `cfw update-kernel`, the offline trim, `vm rebase`,
   snapshots, clones, export, import and the running-machine check all treat
   `Disk.img` as a file. Every offline operation would have to materialize a
   20 GB raw image and write it back.
3. If the server is gone for more than about 30 s, the client gives up for
   good and every later guest I/O fails.
4. A garbage collector, index and map memory, log replay at start, and one
   more user-space hop per I/O.

## Potential, measured

Two `vm clone` copies of stopped machines (iPhone99,11 iOS 27.0 24A435 and an
iPad on iOS 26.6.2 23G90, both booted before) were attached read-only, their
System (with the `orig-fs` snapshot), Preboot, xART, Hardware and Update
volumes mounted read-only, and every file's blocks (resource forks of
decmpfs files included) mapped with `F_LOG2PHYS_EXT`; 343 sampled files read
back identical through their physical addresses. Unmapped non-zero blocks are
Data, User and container metadata. Fixed-size chunks were hashed (SHA-256,
zero chunks skipped) and 1 in 32 first occurrences compressed with
libcompression.

Both images together, 42 GB of non-zero data:

| Chunk | After dedup | Ratio | LZ4 | LZFSE | ZLIB | Index entries |
| --- | --- | --- | --- | --- | --- | --- |
| 4 KiB | 35.9 GB | ×1.17 | 27.4 GB | 24.9 GB | 24.1 GB | 8.76 M |
| 16 KiB | 39.8 GB | ×1.07 | 29.3 GB | 26.5 GB | 26.1 GB | 2.43 M |
| 64 KiB | 41.8 GB | ×1.03 | 29.8 GB | 26.8 GB | 26.6 GB | 0.64 M |

| Region | iPhone 27.0 | iPad 26.6.2 | iPad found in iPhone (4K / 16K / 64K) | 4 KiB compression (LZ4 / LZFSE / ZLIB) |
| --- | --- | --- | --- | --- |
| System, with snapshot | 15.67 GB | 13.73 GB | 3.00 / 0.64 / 0.13 GB | 0.76 / 0.69 / 0.67 |
| Data, User, metadata | 4.72 GB | 7.95 GB | 0.72 / 0.29 / 0.16 GB | 0.77 / 0.69 / 0.66 |
| Preboot | 0.06 GB | 0.05 GB | 0.04 GB | 0.74 / 0.66 / 0.63 |

- Cross-build dedup is about 22% of System and 9% of Data at 4 KiB, and
  nearly vanishes at 16 KiB and above: identical files sit at random phases
  relative to the chunk grid. Aligning the grid to the container start
  (20,480 bytes) gave the same figures. A store would need 4 KiB chunks (a
  large index) or content-defined chunking.
- Identical data at the same offset between the two builds: 0.00 GB. `vm
  rebase` cannot share anything between templates of different builds; it
  helps only separately restored machines of one IPSW (about 8.7 GB a pair),
  so it does not compete with a store.
- Within one image: the iPhone's Data/User region has 1.88 GB (40% of the
  region) duplicating other chunks in the same region, probably copies
  between the Data and User volumes (unverified); System has 0.17 GB.
- Compression: System 4 KiB chunks compress to about 0.69 with LZFSE (many
  root file system files are already decmpfs-compressed; the dyld cache is
  not). Larger chunks compress slightly better (0.66 at 64 KiB) at the cost of
  read amplification.

### Data and User blocks

Data and User report FileVault locked on the host, and were expected to be
incompressible ciphertext. They are not uniformly so. On the iPhone image
about 2.0 GB of the region is compressible like plaintext (LZ4 0.55); chunks
begin with `SQLite format 3` (429), `bplist00` (4,006), a PNG signature (874)
and `caff` (711); 2.6 GB is high-entropy. On the iPad image, 3.5 GB
compressible and 4.2 GB high-entropy; 9% of the iPad's Data chunks also occur
in the iPhone's. This suggests guest file contents on virtio storage reach the
disk image unencrypted while metadata and keys are protected, but it was not
verified which files these are or why. See
[the open question](disk_space.md#observation-to-verify-plaintext-in-data-and-user-blocks).

### Projected host bytes

Template 18.6 GB never booted; 0.35 GB per clone after its first boots (3 GB
for "used for a while"); 20.5 GB per separately restored machine. Store at
4 KiB with LZFSE: first template 18.6 × 0.894 (dedup within the image) × 0.69
≈ 11.5 GB, each further build's template 18.6 × 0.81 × 0.69 ≈ 10.4 GB (likely
less between adjacent builds of one device, unmeasured), each clone's
divergence × 0.7 (compression only). IPSW caches not counted.

| N per build, K builds | Separate restores | Template + clones (+ rebase) | Store | Store saves |
| --- | --- | --- | --- | --- |
| 5, 1 | 102 | 20.4 | 12.7 | 7.7 |
| 10, 1 | 205 | 22.1 | 14.0 | 8.1 |
| 5, 3 | 308 | 61.1 | 36.0 | 25 |
| 10, 3 | 615 | 66.3 | 39.7 | 27 |
| 5, 3, 3 GB per clone | 324 | 101 | 64 | 37 |
| 10, 3, 3 GB per clone | 648 | 146 | 95 | 51 |

Without compression, dedup alone adds only the cross-build ~17% (about 2 GB
with one build): the store's gain is mostly compression. A store with 4 KiB
chunks also avoids the up to fourfold amplification of a clone diverging in
16 KiB pages ([disk rebase](disk_rebase.md#the-unit-is-the-16-kib-page-not-the-4-kib-block)),
but a clone's first-boot divergence is only 0.35 GB.

## Virtualization's NBD client

From the SDK headers, strings of `com.apple.Virtualization.VirtualMachine.xpc`,
an EFI probe VM with a read-only disk to watch the handshake, and a Linux
guest to watch real I/O. Both probes were ad hoc signed with only the public
`com.apple.security.virtualization` entitlement.

| Question | Finding |
| --- | --- |
| URLs | `nbd://host[:port]/export`, `nbd://[::1]/…` and `nbd+unix:///export?socket=/path` work (validated and connected). `nbds://`, `nbds+unix://`, `nbd+tcp://` and `nbd+vsock://` are "not supported": no TLS, no authentication. Unix socket paths are limited by `sun_path` (104 bytes) |
| Handshake | Fixed newstyle only ("Old style negotiation is not supported", "Non-fixed new style negotiation is not supported"). Client flags `FIXED_NEWSTYLE \| NO_ZEROES`; `NBD_OPT_INFO`, then `NBD_OPT_GO`, both asking for `NBD_INFO_BLOCK_SIZE`. No structured replies, extended headers, meta contexts or STARTTLS, so no `BLOCK_STATUS`. Export size must be a multiple of 512 |
| Block size | The server's advertised minimum block size becomes the guest's logical block size (4096 made EFI read 4K; 16384 was accepted). vphone images have a GPT with 512-byte LBAs, so a server must advertise a minimum of 512 or less |
| Commands | READ, WRITE and TRIM seen; with `SEND_TRIM`/`SEND_WRITE_ZEROES` advertised, the guest saw discard and write-zeroes limits equal to the disk size. **No FLUSH, and FUA never set**, with synchronization mode full or none. The Linux guest saw `write_cache = write through`; on a raw `VZDiskImageStorageDeviceAttachment` the same kernel saw `write back`. The strings mention an "NBD Flush request timer" that never fired |
| Concurrency | One connection with up to 8 requests in flight (Linux, one queue, 8 parallel writers); requests up to 4 MiB, all 4K-aligned |
| Who connects | `LOCAL_PEERPID` is the app process, while the client code (`Storage::NetworkBlockDeviceConnection`) is in the XPC service, so the descriptor is presumably passed over. An unsandboxed process connects over TCP and Unix sockets without `com.apple.security.network.client`; `vphone-vm` is not sandboxed |
| Server down at start | `start` fails: "The storage device attachment is invalid." No retry |
| Server down while running | 6 s: guest I/O stalls, then resumes transparently, while the delegate receives `Code=20001 Failed to negotiate with server` three times (the header calls such errors unrecoverable). 45 s: after about 33 s the client gives up; every later guest I/O is an `I/O error`, and it does not reconnect when the server returns |
| Server returns EIO | Passed straight to the guest as an I/O error, no retry |
| Boot disk of a PV=3 research VM | Not tested. The storage path is the same `VZVirtioBlockDeviceConfiguration` and iBoot reads Preboot through virtio-blk, so it should work with a 512-byte minimum block |

Guest throughput (Linux, 256 MiB disk; the NBD server kept data in the page
cache, so these rows pay no durability cost and are not comparable to raw):

| | 4K O_DIRECT write | 4K O_DIRECT read | 1 MiB write | 1 MiB read |
| --- | --- | --- | --- | --- |
| Raw `VZDiskImage`, sync full | 74 MB/s | 61 MB/s | 1.0 GB/s | 3.2 GB/s |
| NBD over a Unix socket | 117 MB/s | 130 MB/s | 5.0 GB/s | 6.9 GB/s |
| NBD over TCP | 33 MB/s | 72 MB/s | 2.8 GB/s | 3.0 GB/s |

## Prototype and benchmarks

The prototype, in C with system libraries only and outside the repository:
an NBD server (fixed newstyle; GO, INFO, EXPORT_NAME, LIST, ABORT; READ,
WRITE, FLUSH, TRIM, WRITE_ZEROES, DISC, FUA honoured; one reader thread per
connection, requests on a concurrent queue, FLUSH and TRIM as barriers) over
either a raw file (TRIM as `F_PUNCHHOLE`) or a log-structured store: one
append-only log of data records (SHA-256 truncated to 128 bits, LZ4 or LZFSE,
stored raw unless it saves 10%) and map records (one per request, listing
chunk → entry), with the hash index and map rebuilt by replaying the log.
Replay stops at the first record that fails its checksum and truncates there;
a map record may only reference verified data records, so recovery yields a
prefix of acknowledged writes. A read-only base file passes through, so a
clone is a map rather than a full import.

Import of 2 GiB sampled across an iPhone image (32 × 64 MiB): 4K + LZ4
1.55 GB at 540–800 MB/s, 4K + LZFSE 1.44 GB, 4K uncompressed 1.93 GB, 16K or
64K + LZ4 1.56 GB at 1.6–2.2 GB/s. Two writers racing to store the same new
content left about 0.07% duplicate records.

Loopback, data in the page cache, 2 GiB volume:

| | 4K rand read QD1 | 4K rand read QD32 | 16K rand read QD32 | 4K rand write QD1 | 4K rand write QD32 | 1 MiB seq write | Flush after random writes |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Direct `pread`/`pwrite` | 0.8 µs | 0.9 M IOPS | 14.7 GB/s | 6.8 µs | 199 k | 3.2 GB/s | 0.33–0.6 s |
| NBD Unix, raw file | 10.9 µs | 229 k | 3.2 GB/s | 14.6 µs | 147 k | 0.83 GB/s | 0.8–1.3 s |
| NBD TCP, raw file | 25.6 µs | 108 k | 1.4 GB/s | 37.5 µs | 83 k | 0.75 GB/s | 0.6–0.75 s |
| NBD Unix, store 4K | 10.0 µs | 223 k | 2.9 GB/s | 21 µs | 133 k | 0.79 GB/s | 8–14 ms |
| NBD Unix, store 16K | 12.2 µs | 210 k | 3.3 GB/s | 39 µs (read-modify-write) | 104 k | 0.79 GB/s | 6–10 ms |

Durable before each reply:

| | 4K write QD1 | 4K write QD32 | 1 MiB seq write |
| --- | --- | --- | --- |
| Store, `F_BARRIERFSYNC` | 977 IOPS (1.0 ms) | 8.5 k | 169 MB/s |
| Store, `F_FULLFSYNC` | 271 IOPS (3.7 ms) | 484 | 226 MB/s |
| Raw file, `F_BARRIERFSYNC` | 883 | 7.9 k | 725 MB/s |
| Raw file, `F_FULLFSYNC` | 255 | 621 | 207 MB/s |

- The protocol and thread hops add 10–25 µs per operation. Reads from the
  store are as fast as raw (LZ4 decode is cheap); writes pay hashing and
  compression, 10–40% slower, twice that for 4K writes into 16K chunks.
- The log turns random writes into appends, so a flush takes milliseconds
  where a raw file takes about a second. That advantage disappears once every
  write must be durable, which a write-through client demands: a raw image's
  guest pays one `F_FULLFSYNC` per APFS checkpoint, a store about 1000 IOPS at
  QD1. Group commit (one barrier per ~1 ms batch) helps only at QD > 1.
- The log grows: about a million 4K random overwrites on a 2 GiB volume made
  an 8.7 GB log. Garbage collection is required, not optional.
- The first version wrote map records only on FLUSH. A guest wrote 1 MiB and
  synced, the server was killed and restarted, the client reconnected, and the
  guest read back zeros: acknowledged writes silently lost, because the client
  never flushes. Writing a map record before each reply fixed it. Host power
  loss was not tested.

A real vphone boot from NBD was not attempted: it needs a `vphone-vm` build
with a changed attachment and therefore a new cdhash admitted by the AMFI
allowlist. The Linux guest covered reads, writes, TRIM, concurrency,
reconnection, the timeout and EIO on the real client.

## If it were built

- **Server:** not inside `vphone-vm` (a VM crash would take its storage with
  it, and one store per process cannot deduplicate across machines). One
  per-user helper in the bundle, started on demand, one Unix socket per
  machine with a path under 104 bytes. `vm launch` must see the socket
  listening first. The ~30 s client timeout bounds helper restarts, upgrades
  and GC pauses.
- **Consistency:** log-structured with replay, as the prototype; map
  checkpoints to bound replay; group commit; a stated contract ("after a host
  crash the disk returns to a consistent state a few ms old", or per-write
  durability at about 1/100 of the speed). APFS tolerates a consistent prefix,
  as it does a raw image with synchronization off.
- **GC:** mark from all maps and snapshot maps, copy live records into new
  segments, segment by segment. TRIM only clears map entries; space returns
  at GC, unlike a raw file where TRIM punches at once.
- **Snapshots and clones:** a copy of the map (125 MB dense for 64 GB at 4K,
  much less sparse). Attractive, but `clonefile` already does it for free.
- **Host maintenance:** the largest cost. Every offline verb becomes
  materialize, modify, write back, needing about 20 GB of scratch each time on
  hosts that are often short of space.
- **Failure modes:** a helper down for more than ~30 s fails every machine's
  disk; log corruption truncates to the last verified prefix (data goes back
  in time); a full host disk returns ENOSPC to the guest; one storage bug hits
  every machine at once.
- **Upkeep:** a versioned on-disk format with migrations, helper lifecycle and
  permissions, GC scheduling, Launchpad's size accounting, crash-injection
  tests, and a new minor series because Launchpad would depend on it.

## Cheaper alternatives

1. Templates, the offline trim, and deleting IPSWs (13.5 GB per build) once a
   template exists: all in place.
2. Compress cold templates: archive the `Disk.img` of a template no one clones
   any more (LZFSE, about 30–35% smaller by the figures above) and expand it
   back before the next clone. That takes the store's largest gain, compression,
   without touching the I/O path, host mounts or the CFW tools. Only "three or
   more builds all in use" misses out. Not built.
3. Cross-build dedup (~17%) needs a store or host block-range cloning, which
   macOS does not offer publicly. Left alone.

## When to revisit

- Disk space is still the limit with templates, trim and IPSW deletion in
  place, and three or more builds of ten or more machines each are kept in
  use at once; or
- Apple provides a host-mountable user-space block device (a DiskImages2
  plug-in, or NBD the host can attach); or
- Virtualization's NBD client gains write-back with FLUSH.
