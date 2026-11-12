# iPhone SE 3 on iOS 18.6.2

This adds the SE 3 (`iPhone14,6`, D49AP) iOS 18.6.2 / 22G100 restore to the
catalog and pairs it with cloudOS 26.1 / 23B85. It uses the existing standard
preset's `system-systemhook-cfw-ios18_gpu_transport`. The installed GPU driver
comes from cloudOS 18.6 / 22G86, not 26.1.

Only this iOS 18 release/pairing is offered. The GPU transport's existing
18.6 / 26.1 applicability is unchanged. This does not claim compatibility with
every iOS 18 release or with other kernel pairings.

## Fresh driver extraction

The first fresh prepare had no cached 18.6 driver. Its temporary, Apple-ROM PCC
18.6 VM received a restore ticket and its restore kernel, but failed to enter
restore mode within the backend's 300-second deadline on a macOS 27.0 host.
No SE userland restore had occurred at that point.

The official PCC archive carries an `encryption_key` field in its AEA prologue.
The archive's SHA-256 matches its Apple CDN identifier:
`8b2181f68080c42ae57bb8bf516715841060ee3aaf8c0ff06e1cf627169ef574`.
Using that embedded key with the system `aea decrypt` tool produced a mountable
System image containing `AppleParavirtGPUMetalIOGPUFamily.bundle`, version
40.5.10, `DTPlatformVersion=18.6`.

Preparation now tries this local image path before a temporary restore:

1. Find the unique OS image through the existing manifest reader.
2. For AEA input, accept only an ASCII, 64-digit hexadecimal embedded key. A
   missing field returns control to the existing restore fallback; a malformed
   field is an error.
3. Let the system aea tool authenticate/decrypt the image, then attach it
   read-only at a private mount point.
4. Validate the bundle and its platform version with the existing driver
   validator, stage it, and store it in the existing per-build cache.
5. Detach the reported disk before deleting temporary files. If attachment
   state or detach success is uncertain, retain the work directory and report
   it rather than traversing a possibly mounted volume.

The normal bundled compiler-plugin merge still follows staging. No driver or
key is bundled in the repository, and no new patch identifier, preset, version
gate, CLI flag or runtime package dependency is introduced.

## Runtime validation, 2026-11-12

A new standard-preset creation, starting without an 18.6 GPU-driver cache,
completed preparation through direct image extraction, SE restore, CFW install,
setup, template adoption, cloning and first boot. Spotlight briefly held the
completed template's disk; retrying adoption after the reader closed completed
without another restore.

The running machine is `iPhone-SE3-iOS18`, built with a 2.16.1 development bundle
from base `6f57024a` plus these changes. The final source branch was subsequently
rebased on `e9159f33`; that upstream delta did not change this asset-staging code.
The machine has four vCPUs, 4096 MB, a 64 GB disk, all system apps and service
profile `none`. Template setup included a reboot and verification; the clone
answered vphoned after seven seconds.

The guest reports `model=iPhone14,6`, iOS 18.6.2, and 375×667 points at scale 2.
The existing LLB scale patch emitted 2; the installed device tree kept SE Home
button type 1 while restore kept type 2. A temporary user app using public Metal
APIs reported:

```json
{
  "device": "Apple Paravirtual device GPU",
  "blit_bytes": 4096,
  "compute_values": 1024,
  "render_pixels": 256,
  "ok": true
}
```

This exercised a 4096-byte blit fill, runtime shader compilation, 1024 compute
results, and a 16×16 RGBA render-clear readback. Settings row icons rendered and
DNS resolution succeeded. The user also manually tested the guest and reported
normal operation. Automated navigation interleaved with that manual testing,
so its intermittent foreground-verification failures and transition captures
are not treated as acceptance evidence. There was no separate post-acceptance
cold-start test of the clone.

## Remaining limits

The Metal probe does not prove every graphics client is fault-free. Reports from
`com.apple.MapKit.SnapshotService` were observed, matching the open class of
failure documented in [the original GPU transport work](ios18_gpu_transport.md).
With all services retained, `rapportd` also produced `EXC_BREAKPOINT` reports in
`os_channel_create_extended`. Neither background-service issue is claimed fixed
by the catalog or extraction change. Cellular, biometrics and Apple sign-in
were not tested.

## Checks

- Complete 2.16.1 Debug bundle build and bundle admission passed.
- 47 CoreKit tests passed across device, catalog and PCC-driver suites, including
  uppercase/lowercase embedded keys, invalid key characters and lengths, and the
  missing-key fallback without staging side effects.
- The existing GPU transport tests passed with address/undefined sanitizers.
- The no-cache native extraction and completed VM creation are runtime evidence
  in addition to those unit tests.
