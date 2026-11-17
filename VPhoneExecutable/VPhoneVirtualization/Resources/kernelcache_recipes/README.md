# Kernelcache recipes

Only the 26.1–26.4 beta cloudOS releases ship vphone600 components. On any
other cloudOS, `fw patch` takes the research board's (vresearch101) and rebuilds
its `kernelcache.release.vresearch101` with the iPhone virtualization kexts of a
donor kernelcache (`kernel-boot-vresearch101_kext_mix`, `KernelCacheMixer`).
These recipes say how, one per supported kernelcache. Details are in
`Research/0_binary_patch_comparison.md` ("The research board's kernelcache").

## Layout

```
bases/<iOS version>_<iPhone build>/
  manifest.json      the recipe (below)
  symbols.json.gz    symbol map: kernelcache address (decimal) to name(s)
  kexts.txt          bundle identifiers of the mix
donors/<id>/
  manifest.json      the donor kernelcache and the cloudOS it is read from
  symbols.json.gz    symbol map, for a stripped donor
```

Base `manifest.json`:

| Key | Meaning |
|---|---|
| `kernel.sha256`, `kernel.decompressedSHA256` | identify the research board kernelcache (IM4P or decompressed) |
| `kernel.kdk` | the KDK its extraction makes; a kernelcache whose kexts carry no `DTPlatformBuild` (26.6, 26.7) takes the build from here |
| `donor` | `donors/<id>`, which supplies the virtualization kexts |
| `builderLayout` | `kernel-last` (iOS 26.4+, kmutil of macOS 26.4+) or `kernel-first` |
| `guest`, `sources` | the guest family of a recipe of its own (`watch`, `homePod`), and its kext sources in order: each kext from the first that has it |
| `kextOverrides` | bundle identifier to the source it is taken from although an earlier one has it (`homepod_26.5_23L471`: AMFI, corecrypto, AppleImage4 and IOTimeSyncFamily from the base, IOgPTPPlugin from `vphone600_26.4_23E5207q`) |

The bundle list is the base's kexts without the research-board-only ones
(CIOMesh, MLX5, Thunderbolt, RDMA, ...), plus the donor kexts that link against
the base kernel.

The donor `vphone600_26.4_23E5207q` is the vphone600 kernelcache of the 26.4
beta cloudOS, the last one with vphone600 components. Only that file is read
from the cloudOS IPSW, once, and kept with its extraction in
`~/.vphone/kernelcache/donors`.

The iOS 18 bases (18.1 to 18.7.2, the research board kernels of their own
release's cloudOS) take their kexts from `vphone600_26.1_23B78`, the vphone600
kernelcache of the public cloudOS 26.1. Mixing across versions cannot go by
name: each donor import was resolved by code identity in every base, and both
maps carry the names those targets have. 18.1 to 18.3.1 leave out the audio
kexts whose imports have no counterpart there (15 donor kexts instead of 18).

## Requirements

- KDK extraction is native to VPhone.bundle; no external `ipsw` is required.
  The recipe's gzip symbol map is decompressed in process.
- The kmutil the base was built with. Every kernelcache records it
  (`_PrelinkKCID`, `KernelManagement_host-<version>`), and only that
  version's kernel collection builder lays the mix out as Apple did: macOS 15
  and 26.0–26.3 link kernel-first, 26.4 and later kernel-last, 27 keeps the
  auth stubs. `KernelCollectionToolchain` takes this Mac's kmutil when it is
  that version, else the kmutil of the macOS release that ships it, read once
  out of that IPSW's recoveryOS image, with
  `libKernelCollectionBuilder.dylib` lifted out of its dyld shared cache
  (`DyldCacheDylibExtractor`). They are kept in `~/.vphone/kernelcache/kmutil/<version>`.
  A base whose version no release in `KernelCollectionToolchain.releases`
  ships is refused before anything is extracted; adding a base of a new
  kmutil version means adding its macOS release there, after checking that
  release's recovery kmutil reports the version.
- No root. kmutil reads only kexts owned by root:wheel and not group- or
  world-writable, and links the host's own kexts in place of any others
  without a word; `libvphone-kmutil-shim.dylib` (inserted into the ad hoc
  signed kmutil) shows it the user's files that way, and gives it its own
  release's KernelManagement configuration.
- The kmutil of macOS 27 keeps every kext's `__auth_stubs`. After the link,
  `KernelCollectionStubCalls` makes the calls through them direct again and
  seals corecrypto's FIPS HMAC again, so the kernel patches find the call
  sites they find on a macOS 26 link
  (`Research/0_binary_patch_comparison.md`, "macOS 27's kmutil keeps auth stubs").

`vphone-cli fw kernelcache <vm>` stages the mix (the extractions and the
volume, in `~/.vphone/kernelcache/staged`) and links it, as the user. The
volume is linked from a clone in `/private/var/tmp` whose path has the length
of Apple's build root (below). `fw patch` takes the mix from the cache, and
builds it first when it runs as the user; root only reads it from the cache.

`fw kernelcache --ipsw <path>` is still accepted as an ignored compatibility
argument. The native extractor revision participates in both donor
and mix cache keys, so older external-tool extractions are rebuilt.

Mixed kernelcaches are cached in `~/.vphone/kernelcache/mix`, keyed by the recipe,
with kmutil's log beside each. Remove `~/.vphone/kernelcache` to rebuild them.

kmutil records the absolute path of every codeless kext, so the volume is linked
at a path as long as the build root Apple linked the base in, read from the
base. The mix then does not depend on where it is built.

## Adding a base

A recipe comes from research, not from this repository:

1. Symbolicate the stripped kernelcache with BinDiff against a symbolicated KDK of
   the same family (`ipsw kernel symbolicate --bindiff <kdk> <kc> --json
   --aliases`, which writes every name of an address, as step 4 needs).
2. Fix wrong binds, checked against link symbols, PAC discriminators,
   same-generation macOS KDKs and C++ vtables, until every donor import binds
   and the extraction links.
3. Check the base: its extraction, linked again with Apple's bundle list, must be
   byte-identical to the shipped kernelcache.
4. For a stripped donor, put the import names of the donor extraction the maps
   were built against first in its map. Several names often share an address
   (folded stubs, inherited `_kc.` placeholders), and an import binds to the
   first one; another order makes kmutil fail with "could not find a kext which
   exports this symbol".
5. Build the mix, boot it, and add the map, bundle list and manifest here.
