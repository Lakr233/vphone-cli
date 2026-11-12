# iPhone SE (3rd generation): iOS 26 and 27

The SE 3 is `iPhone14,6`, board `d49ap`. Its panel is 750×1334 at 326 ppi,
2x: 375×667 points. Both restore IPSWs used below name that product and board
in their BuildManifest; the panel agrees with [Apple's specifications](https://support.apple.com/en-us/111866).

## Device and patches

The guest registry records the SE's own board and panel, and the firmware
catalog includes its released iOS 26.0–26.6.2 and 27.0–27.2.1 IPSWs. Only the
two releases below have recorded runtime checks; catalog presence does not
imply every release was boot-tested.

The SE IPSW supplies userland and board presentation. Virtual hardware, kernel,
boot chain and SEP remain PCC/cloudOS. Existing board-presentation patches copy
D49AP's identity, artwork subtype 569 and scale 2. The existing
`llb-cfw-display_scale` path writes scale 2 because the panel differs from the
virtual board's boot-video scale of 3. No new LLB patch is needed.

The source D49AP tree declares `/buttons/home-button-type` as a concrete
four-byte value 1. Previously `devicetree-cfw-home_button_type` always wrote 2,
which declares a gesture-driven device without a Home button. It now copies
the source value for an **installed SE 3 tree only**, under the same patch
selection gate. Missing, placeholder or non-four-byte source values are
refused. Restore trees retain type 2 and the virtual identity, and other devices
retain their existing bytes. No identifier, preset or version gate was added.

Tests cover installed versus restore presentation, donor validation, deselection,
2x panel persistence and catalog/report inclusion. Disabling the Home-button
patch leaves the original slot untouched and does not require a donor value.

## Initial runtime checks (2026-11-12)

These machines were created with the SE changes on a 2.15.2-based development
build **before** porting the change to 2.16.1. They are evidence for the device
and patch path, not a claim that a fresh 2.16.1 restore was exercised.

Both use cloudOS 26.4 (23E5207q), four vCPUs, 4096 MB, a 64 GB disk, and the
standard preset. They retain system apps and use a trimmed service profile with
Apple Account services off; sign-in, cellular service and biometrics were not
tested.

| Userland | Checks | Explicit cold start |
| --- | --- | --- |
| iOS 26.6.2 (23G90) | Rendered desktop; Settings > General > About reports iPhone SE and 26.6.2; touch navigation; Home; Safari HTTPS content; DNS | New boot-session UUID, vphoned after 6 s, repeated About navigation |
| iOS 27.2.1 (24B156) | Same checks; host and guest screenshots agree | New boot-session UUID, vphoned after 11 s, repeated About navigation |

Both report `model=iPhone14,6`, screen 375×667, scale 2. The first 26 trial
preceded the Home-button correction; it was repatched and restored again before
the successful checks. A daemon ping or an early black screenshot was not
accepted as UI validation.

Opening `prefs:root=General&path=About` directly on 27 produced a black scene;
Home returned to the desktop without restarting the VM or SpringBoard. Actual
touch navigation through Settings succeeded after the same cold start. The
acceptance above uses visible navigation rather than that deep link.

Setup cleared the expected pre-CFW missing-dyld-cache panic. After setup, 26
recorded one `languageassetd` JetsamEvent (`per-process-limit`, 384 × 16 KiB),
unchanged across the explicit cold start. No new panic or application crash was
observed during acceptance; 27 had no reports after its setup cleanup and cold
start.

## 2.16.1 validation

The PR branch starts at upstream `d1c36fa8` (version 2.16.1), keeping its current
dependencies and release settings. Build and test results are recorded in the
PR description separately from the earlier runtime checks above.

On that base with this change:

- The complete Debug `VPhone` scheme built and bundle admission passed. The
  resulting bundle reports version 2.16.1.
- 42 CoreKit tests passed in the guest-device and firmware-catalog suites.
- 102 firmware tests passed in nine suites: device-tree presentation, LLB
  scale, DriverKit, version requirements, patch selection, declarations, plan
  resolution, patch gate, and the bundled catalog.
- `npm ci` and `npm run build` passed for the documentation site.
- Native `fw patch` replays completed on copies of both SE restore trees:
  237 records for 26.6.2 and 256 for 27.2.1, without undeclared-patch warnings.
  Both emit Home type 1 for the installed tree, type 2 for restore, and LLB
  scale 2. Their restore trees and LLB bytes match the earlier boot-tested
  outputs. The installed trees differ only by `product/supports-driverkit=1`,
  the existing 2.16 upstream change (`90e0c6cb`), as confirmed by parsing and
  comparing every property and flag.
- An existing iPhone Duo 27.1 / cloudOS 26.4 restore tree, using identical
  recorded patch selections in both runs, was replayed with the official
  2.16.1 release and this branch. iBSS, iBEC, LLB, TXM, RestoreTrustCache,
  kernelcache, restore DeviceTree and installed DeviceTree were byte-identical.
  The mounted RestoreRamDisk is **not** claimed byte-identical: even two runs
  of the same official release changed its whole-image SHA-256. All three runs
  emitted the same seal-tool cdhash transition
  `3ee3cd0fab009cfcd20f00c6af68c39bbefb0a9f` →
  `4f9541a0d3f8ecf94b7aaf3b80d7120502d72b8c`, and the same trust-cache bytes.

These are targeted tests and native firmware replays. They do not substitute
for a fresh 2.16.1 restore or claim that the full test corpus was run.

For the later iOS 18.6.2 pairing, see [SE 3 on iOS 18](iphone_se3_ios18.md).
