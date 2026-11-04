# Firmware compatibility

[Documentation](../README.md) · [Create a VM](create-and-run.md) · [Patch inventory](../../Research/0_binary_patch_comparison.md)

**v2.0.0 VM format:** This release starts only newly created VMs whose
`config.plist` has `schemaVersion=2`. Recreate VMs made by earlier releases
with `vm create`; there is no in-place upgrade. The firmware results below
describe tested pairings, not compatibility with older VM bundles.

## Tested Environments

These are the two iPhone17,3 combinations exercised with the native JB pipeline in [PR #486](https://github.com/Lakr233/vphone-cli/pull/486). Both reached the lock screen and answered a vphoned ping. A fresh 26.6.2 `vm create` also completed all stages and exited successfully after its first-boot ping.

| Validation | iPhone restore IPSW | PCC/cloudOS IPSW | Observed result |
| --- | --- | --- | --- |
| PR #486 | `17,3_26.6.2_23G90` | `26.4-23E5207q` | JB patches, restore, CFW, boot, vphoned ping |
| PR #486 | `17,3_27.0_24A435` | `26.4-23E5207q` | JB patches, restore, CFW, boot, vphoned ping |
| Research board | `17,3_26.6_23G71` | `26.6-23G71` | standard and Minimal presets from the CLI, standard from Launchpad (2026-10-20): converted device tree and SEP, kernelcache mix, restore, CFW, boot, vphoned ping |
| Research board | `17,3_26.5_23F77` | `26.5-23F75` | standard preset from the CLI (2026-10-20): GPU driver from a temporary cloudOS restore, kernelcache mix, restore, CFW, boot, vphoned ping |
| Research board | `17,3_26.4_23E246` | `26.4-23E244` | standard preset from the CLI (2026-10-20): GPU driver from a temporary cloudOS restore, kernelcache mix, restore, CFW, boot, vphoned ping |
| Research board | `Watch7,18_26.4_23T240` | `26.4-23E244` | `watchos` preset from the CLI and from Launchpad (2026-10-20): watch kernelcache mix, restore, boot, vphoned ping |
| Research board | `11,6_18.7.2_22H124` | `18.7.2-22H43` | Minimal preset from the CLI (2026-10-21): GPU driver from a temporary cloudOS restore, iOS 18 kernelcache mix linked over ssh by the kmutil of macOS 15.6.1, restore, boot, vphoned ping; screen, lock screen, unlock and home swipes checked |
| Research board | `11,6_18.1_22B83` | `18.1-22B83` | Minimal preset from the CLI (2026-10-21): GPU driver from a temporary cloudOS restore, kernelcache mix linked over ssh by the kmutil of macOS 15.6.1, restore, boot, vphoned; Hello screen, lock screen, unlock and home swipes checked |
| Research board | `11,6_18.5_22F76` | `18.5-22F76` | Minimal preset from the CLI (2026-10-21): GPU driver from a temporary cloudOS restore, kernelcache mix linked over ssh by the kmutil of macOS 15.6.1, restore, boot, vphoned; lock screen, unlock and home swipes checked |
| Research board | `11,6_18.6_22G86` | `18.6-22G86` | standard preset from Launchpad's CLI (2026-10-24): kernelcache mix (cached), restore, CFW, boot, vphoned, Hello screen; Frida 17.24.3 attach, spawn, Interceptor and Stalker with the two Frida patches allowed |

The cloudOS 26.4 beta image (`26.4-23E5207q`) is the newest one that contains `vphone600ap`, the identity the guest's kernel, SEP and device tree come from, and it stays the recommended cloudOS: it needs nothing beyond vphone-cli. Every cloudOS release after it was checked on 2026-10-03 and lists only the PCC boards and `vresearch101ap`: `iPhone99,11` is gone from `SupportedProductTypes`, and there is no `kernelcache.*.vphone600`, `sep-firmware.vphone600` or `DeviceTree.vphone600ap`.

On such a cloudOS the research board stands in (the Research Board patch set): `fw patch` turns its device tree and SEP into vphone600's and rebuilds its kernelcache with the vphone600 virtualization kexts, from a recipe for that kernelcache. KDK extraction is native; the link still needs root (`vphone-cli fw kernelcache`; see [the recipes](../../VPhoneExecutable/VPhoneVirtualization/Resources/kernelcache_recipes/README.md)). `fw prepare` refuses a cloudOS no recipe covers. `fw catalog` lists each iOS release's own cloudOS beside the recommended one, and Launchpad offers it under Firmware.

iOS 18.1 to 18.7.2 run the same way on their own release's cloudOS, with the userland of the iPhone XS family's IPSWs (`vm create --device iPhone11,6`, the Minimal preset by default, `--preset standard` checked on 18.6; `fw catalog --device iPhone11,6` lists them). Their kernels are kernel-first: from macOS 26.4 on, another Mac or a macOS VM running macOS 15 or 26.0 to 26.3 links the mix over ssh (`VPHONE_KMUTIL_SSH`, see [Create and Run](create-and-run.md)); Launchpad offers them as the iPhone XS Max, with that Mac as the macOS builder. 18.1, 18.5 and 18.7.2 are checked on VMs; the other four recipes have not been booted yet.

| cloudOS | `vresearch101ap` | `vphone600ap` | kernelcache recipe |
| --- | --- | --- | --- |
| `26.4-23E5207q` (beta) | yes | yes | not needed |
| `26.4-23E244` | yes | no | yes |
| `26.4.1-23E254` | yes | no | no |
| `26.5-23F75` | yes | no | yes |
| `26.5.2-23F83` | yes | no | no |
| `26.6-23G71` | yes | no | yes |
| `26.6.1-23G82` | yes | no | no |
| `26.7-23H20` | yes | no | yes |

Use `vphone-cli fw catalog` to inspect the current catalog. Other iPhone and iPad versions may work with `26.4-23E5207q`, but they have not passed this same end-to-end check.

**iPhone17,3 27.0.1 (24A446)** fails first boot on bundle 2.5.0 and earlier
(reproduced 2026-10-04, including with the pristine Apple launchd): TXM's
selector-24 pre-check rejects every binary at init and the boot panics with
`unexpected SIGKILL of init`. The former `txm-boot-precheck_admission` patch
(`Research/Firmware/txm_selector24_cms_gate.md`) fixes it; verified the same
day: `iPhone17,3 27.0.1 + 26.4-23E5207q` with the patch boots to the guest
and answers a vphoned `device.info`. Bundle 2.6.0 is the first release that
carries it.

This revision replaces that forced type-10 admission with
`txm-cfw-executable_remap`, selected by `standard` without an OS-version gate.
Host tests cover the original signature rejection paths. On iOS 27.1
(24A94425), the tester reports normal startup and App loading, and the runtime
probe executes all 28 main/framework original-code remaps with actual RX
mappings. The exact historical iOS 27.0.1 pairing has not been retested. See
`Research/Firmware/txm_executable_remap.md`.

## macOS 26.6.2 hosts

Checked on 2026-10-23 with Core Bundle 2.12.1, and again on 2026-10-24 with Core Bundle 2.12.2, on Mac mini M4 hosts (Mac16,10, 16 GB, macOS 26.6.2 25G83). Every machine was created from nothing, from the CLI: the research-board pairings stage their kernelcache mix as the user and link it with sudo, then `sudo vphone-cli vm create`. A default is the newest pairing `fw catalog` gives that device on this Mac, as Launchpad's New Machine selects. Each machine then booted twice headless: vphoned answered, `device.info` reported the release, and the guest's serial log showed no panic.

| Guest | Firmware | cloudOS | Result |
| --- | --- | --- | --- |
| iPhone17,3 | iOS 27.0.1 (default) | `26.4-23E5207q` | template build, clone, two boots |
| iPhone18,2 | iOS 27.0.1 (default) | `26.4-23E5207q` | template build, clone, two boots |
| iPad16,1 | iPadOS 27.0.1 (default) | `26.4-23E5207q` | template build, clone, two boots |
| iPhone17,3 | iOS 26.6.2 | `26.4-23E5207q` | template build, clone, two boots |
| iPhone17,3 | iOS 26.6.2 | `26.6-23G71` | research board: native KDK extraction, macOS 26 link with no auth stubs left, 28 kernelcache patches, two boots |
| iPhone17,3 | iOS 26.5 | `26.5-23F75` | research board, as above |
| iPhone17,3 | iOS 26.4 | `26.4-23E244` | research board, as above |
| iPhone17,3 | iOS 18.6.2 | `26.1-23B85` | template build, clone, two boots |
| iPhone11,6 | iOS 18.7.2 (default) | `18.7.2-22H43` | Minimal, mix linked over ssh by the kmutil of a macOS 15.7.7 VM, two boots |
| iPhone11,6 | iOS 18.6 | `18.6-22G86` | as above: the first boot of this recipe |
| iPhone11,6 | iOS 18.7 | `18.7-22H20` | as above: the first boot of this recipe |
| Watch7,18 | watchOS 26.4 (default) | `26.4-23E244` | `watchos` preset, watch kernelcache mix, two boots |
| AppleTV5,3 | tvOS 26.6 (default) | `26.4-23E5207q` | `tvos` preset, two boots |
| AppleTV14,1 | tvOS 26.6 (default on macOS 26) | `26.4-23E5207q` | `tvos-4k` preset, 26.6 OTA userland, two boots |
| AudioAccessory5,1 | HomePod Software 27.0 (default on macOS 26) | `26.4-23E5207q` | `homepod-mini` preset, two boots |
| AppleTV14,1 | tvOS 27.0 | — | refused before any download: needs macOS 27 |
| AudioAccessory5,1 | HomePod Software 27.2 | — | refused before any download: needs macOS 27 |

The tvOS 27.0 (24J361) and HomePod Software 27.2 (24K120) OTAs compress their payload with LZRAVEN, which only macOS 27 unpacks. On an older Mac `fw catalog` leaves them out, so Launchpad's default for those devices is tvOS 26.6 and HomePod Software 27.0, and naming one is refused before anything is downloaded.

Apple TV 4K (4th generation), `AppleTV18,1` / `J265AP`, is available for
bring-up with tvOS 27.2 beta (`24K120`) only, using its full OTA over the
Apple TV HD 26.6 restore base and cloudOS 26.4 beta (`23E5207q`). It requires
macOS 27 and the `tvos-4k` preset. On 2026-10-24 one machine was restored,
had its custom firmware installed, and cold booted twice to vphoned and the 4K
Language screen of the legacy TVSetup; setup itself was not completed. It is
not included in the tested table above. See the
[bring-up notes](../../Research/Firmware/tvos_support.md#apple-tv-4k-4th-generation).

cloudOS 26.7 (23H20) has no iPhone release to pair with. Staged with iOS 26.6.2's userland, its mix links and its 28 kernelcache patches apply; the CFW patch `_vm_fault_enter_prepare` finds no site in that kernel. It has not booted.

`vphone-escalator`'s allowlist is kept in amfid's memory, so it is lost when amfid restarts, as it did once on these hosts mid-run. Launchpad allows the bundle again when AMFI refuses it; from the CLI, run the `vphone-escalator allow` command `host preflight` prints again.

## Other iPhone models

See [Other iPhone models](iphone-models.md).

| Host | iPhone restore IPSW | PCC/cloudOS IPSW | Observed result |
| --- | --- | --- | --- |
| Mac17,9 (M5 Pro) 27.0.1 | `18,1_26.6.2_23G90` (iPhone 17 Pro) | `26.4-23E5207q` | Launchpad `vm create` (2.5.1 local bundle): prepare, patch, restore, CFW, boot to the home screen at 402x874 pt @3x, `model` iPhone18,1, vphoned ping |
| Mac17,9 (M5 Pro) 27.0.1 | `18,2_27.0.1_24A446` (iPhone 17 Pro Max) | `26.4-23E5207q` | **boots** with the `kernel-boot-shared_region_size` patch (2026-10-06, bundle 2.6.0-local.0d5e6f90): `dyld cache mapped system-wide`, 0 panics, vphoned answers as 27.0.1, home screen at 440x956 pt @3x |
| Mac17,7 (M5 Max) 26.4 | `19,2_27.0.1_24A446` (iPhone 18 Pro) | `26.4-23E5207q` | **boots** with integrated ARM64E_X1 compatibility (2026-10-17): clean offline restore, validated root seal, vphoned ping, and Settings, Safari and Calculator launch |

**iPhone18,1 and iPhone18,2 on iOS 27 need the shared-region patch**
([issue #596](https://github.com/Lakr233/vphone-cli/issues/596), 27.0 and
27.0.1). Their dyld shared cache records a `sharedRegionSize` of
`0x185804000` on 27.0.1, larger than the `0x180000000` shared region of the
cloudOS 26.4 guest kernel, so it cannot map even with `dyld-boot-maxslide`
taking its slide away: launchd panics on first boot with `Library not loaded:
/usr/lib/libSystem.B.dylib`. iPhone17,3's 27.0.1 cache (`0x17D508000`) still
fits. Since this check, `cfw install` refuses such a cache with that
explanation instead of leaving a guest that panics.

`kernel-boot-shared_region_size` (on in `standard` for an iOS 27 base since
2026-10-06) widens the arm64 region to `0x1C0000000` — the largest size that
stays under the 26.4 kernel's own task-map ceilings — and `cfw install`
measures the cache against that widened region when the VM's kernel carries
the patch (its `PatchReceipt.plist` says so), so these devices now install and
boot; validated on iPhone18,2 27.0.1 as above. Without the patch
(an older bundle, or the patch unticked) the refusal stands: use iPhone17,3
for iOS 27, or iOS 26 on these devices.

## iPadOS

See [iPadOS guests](ipados.md).

| Host | iPad restore IPSW | PCC/cloudOS IPSW | Observed result |
| --- | --- | --- | --- |
| Mac17,9 (M5 Pro) 27.0.1 | `iPad16,1,iPad16,2_26.6.2_23G90` | `26.4-23E5207q` | prepare, patch, restore, CFW (2.2.5 helper), boot to the iPadOS home screen at 744x1133 pt @2x, `model` iPad16,1, vphoned ping |
| Mac17,9 (M5 Pro) 27.0.1 | `iPad16,1,iPad16,2_27.0.1_24A446` | `26.4-23E5207q` | Launchpad `vm create --device iPad16,1` from the catalog (2.4.0 bundle): prepare, patch, restore, CFW, boot to the iPadOS home screen at 744x1133 pt @2x, `model` iPad16,1, `ios_version` 27.0.1, vphoned ping |

## Earlier reported combinations

The previous README recorded the following host and firmware pairings. They predate the current single-mode flow or lack the same vphoned acceptance evidence, so treat them as research history rather than the current support matrix.

| Host            | iPhone                | CloudOS         |
| --------------- | --------------------- | --------------- |
| Mac16,11 27.0b2 | `17,3_18.6.2_22G100`  | `26.1-23B85`    |
| Mac16,8 26.5.1  | `17,3_26.0_23A341`    | `26.1-23B85`    |
| Mac16,8 26.5.1  | `17,3_26.0.1_23A355`  | `26.1-23B85`    |
| Mac16,12 26.3   | `17,3_26.1_23B85`     | `26.1-23B85`    |
| Mac16,12 26.3   | `17,3_26.3_23D127`    | `26.1-23B85`    |
| Mac16,12 26.3   | `17,3_26.3_23D127`    | `26.3-23D128`   |
| Mac16,12 26.3   | `17,3_26.3.1_23D8133` | `26.3-23D128`   |
| Mac16,11 26.2   | `17,3_26.4_23E246`    | `26.4-23E5207q` |
| Mac16,11 26.2   | `17,3_26.5_23F77`     | `26.4-23E5207q` |
| Mac16,11 27.0b2 | `17,3_26.5.2_23F84`   | `26.4-23E5207q` |
| Mac16,6 26.4.1  | `17,3_26.6_23G71`     | `26.4-23E5207q` |
| Mac16,11 27.0b2 | `17,3_26.6.1_23G83`   | `26.4-23E5207q` |
| Mac16,6 26.6.1  | `17,3_26.6.2_23G90`   | `26.4-23E5207q` |
| Mac16,11 27.0b2 | `17,3_27.0_24A5380h`  | `26.4-23E5207q` |
| Mac16,6 26.4.1  | `17,3_27.0_24A5390f`  | `26.4-23E5207q` |
| Mac16,6 26.6.1  | `17,3_27.0_24A5408d`  | `26.4-23E5207q` |
| Mac16,11 27.0b2 | `17,3_27.0_24A5418b`  | `26.4-23E5207q` |
| Mac16,11 27.0b2 | `17,3_27.0_24A5424a`  | `26.4-23E5207q` |
| Mac16,11 27.0b2 | `17,3_27.0_24A5430a`  | `26.4-23E5207q` |
| Mac16,6 26.6.1  | `17,3_27.0_24A435`    | `26.4-23E5207q` |
