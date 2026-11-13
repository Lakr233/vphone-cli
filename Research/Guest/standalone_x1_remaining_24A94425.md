# Remaining standalone X1 images — iOS 27.1 (24A94425)

This is the complete measured inventory of **1,019 standalone system libraries
and plug-ins outside the declared X1 patch inventory**, recorded on 2026-11-13.
It is a static coverage report, not a list of reproduced crashes or an automatic
patch selection. The [accessibility coverage study](accessibility_library_x1.md)
describes the fixed startup failure, implementation and live validation.

## Scope and accounting

- iPhone userland: iOS 27.1 `24A94425`; research kernel: cloudOS 26.4 `23E5207q`.
- The read-only System-volume snapshot was taken before the 35 accessibility
  additions were installed. It includes the installed physical OS cryptex.
- The auditor examined 252,612 regular files of at least 32 bytes, skipped 35
  backup entries and selected 1,211 native/universal X1 `MH_DYLIB` / `MH_BUNDLE`
  images. There were no traversal/read failures or failed image analyses.
- Of those images, 157 needed no lowering. Another 35 had complete plans and
  match the newly declared accessibility patches, subsequently validated and
  installed. Excluding both groups leaves the 1,019 entries below.
- Executables, standalone dyld, kernel extensions and shared caches are outside
  this report. Symlinks and backups are skipped. Other mounted cryptex or
  developer images require their own audit. User-installed app payloads on the
  Data volume are outside this snapshot scan.

| Remaining plan state | Images | Planned instructions | Unvisited candidates | Original bytes |
| --- | ---: | ---: | ---: | ---: |
| `needsLowering` | 1,012 | 927,475 | 0 | 325,777,312 |
| `incomplete` | 7 | 8,269 | 1,896 | 31,911,024 |
| Total | 1,019 | 935,744 | 1,896 | 357,688,336 |

`needsLowering` means the production planner can account for all current X1
candidates and re-attest the changed code slots **in memory**. It does not mean
the image has been installed, re-signed as a bundle, reverted or exercised at
runtime. `incomplete` retains candidates the control-flow walk cannot prove;
instruction-shaped data and real unreachable/unrecovered code must be separated
before any additional rewrite is considered. Neither state is a strict pass.

The inherited exception translator can handle some execution paths, while a
debugger or crash reporter may receive their faults first. A path's appearance
here therefore establishes remaining coverage work, not an inevitable crash
in every application. Directory groups below describe location, not usage
frequency or severity.

## Shared-cache relationship markers

The follow-up comparison reads the complete installed X1 cache image and image
text tables: **4,702 images**, cache UUID
`9AA9EFEB-A633-3CEC-B98D-F4598C0DD0BF`. All 1,019 standalone Mach-O headers were
also read from the original read-only snapshot, including `LC_UUID`,
`LC_ID_DYLIB` when present and load dependencies. Their file sizes match the
original audit. The 15 numbered message-send headers and four duplicate-build
headers were additionally checked against the running guest.

Physical OS/App cryptex prefixes are normalized for path comparison; DriverKit
paths retain their separate namespace. Matching uses full paths, install names
and UUIDs, not basenames. The complete inventory now keeps **Cache relation**
separate from the original **Plan state**:

| Cache relation | Images | Meaning |
| --- | ---: | --- |
| `sameBuildInCache` | 4 | Both the install name and UUID match a cache image. The corresponding cache-extracted copies pass the production audit with zero planned instructions and zero unvisited candidates. |
| `differentBuildInCache` | 1 | `libSystem.B_asan.dylib` shares an install name with ordinary cached `libSystem.B.dylib`, but has a different UUID and an ASan runtime dependency. The ASan variant is not covered by the normal cached build. |
| `familyOnly` | 15 | `libobjcMsgSend34`–`48` have no matching cache path, install name or UUID. The unnumbered and `1`–`33` cache images cover the observed message-send calls; they do not convert these 15 files. |
| `notInCache` | 999 | No normalized physical-path, install-name or UUID match in this cache. Loading conditions still need separate review. |

The four matching builds are:

| Standalone copy | Matching cache install name | Shared UUID |
| --- | --- | --- |
| `/Applications/DiagnosticsService.app/PlugIns/Diagnostic-8441.appex/Frameworks/DiagnosticsSupport.framework/DiagnosticsSupport` | `/System/Library/PrivateFrameworks/DiagnosticsSupport.framework/DiagnosticsSupport` | `D2077019-FE23-321A-8E22-EAB9BC0EA606` |
| `/Applications/LimitedModeShieldApp.app/Frameworks/AppManagedFeaturesUI.framework/AppManagedFeaturesUI` | `/System/Library/PrivateFrameworks/AppManagedFeaturesUI.framework/AppManagedFeaturesUI` | `B5308F9A-B43B-34E4-969E-AEC862E3F43E` |
| `/System/Cryptexes/OS/usr/libexec/AppleLatticeSupport.framework/AppleLatticeSupport` | `/System/Library/PrivateFrameworks/AppleLatticeSupport.framework/AppleLatticeSupport` | `293FD6BF-A428-37C4-8EDD-546E3BDEAD67` |
| `/System/Cryptexes/OS/usr/libexec/Moments.framework/Moments` | `/System/Library/PrivateFrameworks/Moments.framework/Moments` | `4D06F757-577D-3266-BB42-C64DF727F5F1` |

These markers do not change the on-disk instruction counts or certify an
explicit load of a standalone copy. `sameBuildInCache` means to verify that the
loader resolves to the cached implementation before adding a duplicate patch.
All four standalone files retain `needsLowering` in this inventory.

The ASan case shows why an install-name match alone is insufficient. Its UUID
is `27AA9A3A-C37D-3AB8-9BCA-476F32FBB2D7`, while the cache's ordinary
`/usr/lib/libSystem.B.dylib` is `F8E3D0E3-095F-350C-8370-0062EB4757A8`.
The standalone variant additionally links
`@rpath/libclang_rt.asan_ios_dynamic.dylib`; its 18 planned instructions remain
relevant if that variant is selected.

## Follow-up order

1. Keep the already validated boot/shared-cache, debugger and in-process
   accessibility coverage. The latter includes the UIKit and SwiftUI Pop glue;
   CIBarcode has a separate existing patch.
2. For an additional workflow, record the process's actual loaded image paths
   and the initial fault before promoting its dependencies into the patch set.
   Settings pages, assistant services, watch companion features and developer
   instrumentation have different loading conditions. A name alone is not a
   reason to mark a library mandatory for all apps.
3. Treat complete plans as candidates for native signing, resource-seal,
   repeat-application, rollback and runtime tests. Declare each accepted patch
   and preserve the opt-out behavior of unvalidated OS presets.
4. Analyze the seven incomplete images separately. Do not publish partial
   conversion as success or replace ambiguous words by raw pattern matching.

The dependency inspection found `usr/bin/swift-inspect` directly linking
`usr/lib/swift/libswiftRemoteMirror.dylib`; this does not establish that ordinary
Swift app startup loads it. DriverKit debug libraries also need actual
loader/feature evidence before assigning an application-wide priority. The
following case study distinguishes the standalone `libobjcMsgSend34`–`48`
entries from the message-send images observed in a running app.

## Higher-priority conversion candidates

The startup image snapshot contains none of the 1,019 remaining physical paths
or the four matching cached builds. There is **no newly reproduced mandatory
startup fix** in this follow-up. This observation covers that startup, not
subsequent features, tool processes or system services.

The **Review** column is a next-validation priority, not a measured probability
of crashing. `P1` identifies complete plans with a concrete tool or in-process
filter entry to exercise before claiming support for that workflow. `P2`
identifies additional feature or service checks. `analyze` preserves the seven
incomplete-plan blockers. `checkResolution` and `observeLoading` refer to the
cache-build and message-send-family cases above. `unranked` means the loading
conditions have not been reviewed; it does not mean low risk.

| Review | Images | Planned instructions | Evidence and conversion decision |
| --- | ---: | ---: | --- |
| `P1`: `libRemoteInjectionPayload.dylib`, `liboainject.dylib` | 2 | 123 | `RemoteInjectionAgent` directly links the former. Its `_local_loader_function` and the latter's attach initializer begin with `pacibsppc`. Prioritize static conversion validation for remote injection and allocation instrumentation, where a debugger can receive the exception first. |
| `P1`: six remaining Core Image plug-ins | 6 | 2,444 | Their `Info.plist` files declare concrete filters through `CIFilterList`. Exercise those filters and rendering under a debugger, then validate conversion of the selected plug-ins. Loading `CoreImage.framework` alone does not load every plug-in. |
| `P1`: `libSystem.B_asan.dylib` | 1 | 18 | The different-build cache marker and explicit ASan dependency require an ASan workflow check. Convert this variant if that workflow selects it; ordinary `libSystem.B` coverage is insufficient. |
| `P1`: `libswiftRemoteMirror.dylib` | 1 | 5,855 | `/usr/bin/swift-inspect` directly links it. Prioritize it for that inspection workflow, without treating it as a library loaded by every Swift app or LLDB launch. |

The six Core Image candidates and their declared entry names are:

| Plug-in | Planned instructions | Examples from `CIFilterList` |
| --- | ---: | --- |
| `CIInpainting.cifilter` | 154 | `CIInpaintFilter`, `CIInpaintDetailFilter` |
| `CIPassThrough.cifilter` | 16 | `CIPassThroughColorFilter`, `CIPassThroughWarpFilter` |
| `CIStyleEngine.cifilter` | 4 | `CIStyleEngineFilter`, `CIStyleEngineWarpFilter` |
| `CIToneMap.cifilter` | 4 | `CIToneMapFilter`, `CIToneMapWarpFilter` |
| `CIVisionFilters.cifilter` | 64 | `CIPersonSegmentation`, `CISaliencyMapFilter` |
| `PortraitFilters.cifilter` | 2,202 | `CIPortraitEffectStudio`, `CIPortraitEffectStage` |

The first recommended conversion-validation batch is the two injection
libraries plus these six filter plug-ins: **8 images, 2,567 planned instructions,
1,225,440 original bytes**. ASan and Swift inspection add two workflow-specific
candidates, for **10 P1 images and 8,440 planned instructions** overall. These
are candidates, not newly enabled patches or completed runtime validations.

Eight further images receive `P2`:

| Workflow | Images | Planned instructions | Evidence and validation boundary |
| --- | ---: | ---: | --- |
| Video encoding / temporal filtering: `AppleVideoEncoder`, `AppleMCTF` | 2 | 4,975 | `CMClassImplementations` declares H.264/HEVC and temporal-filter factories. Entries advertise paravirtualization support but also use IORegistry capability/service requirements. Confirm which factory is selected during encoding; a loaded `VideoToolbox.framework` is insufficient evidence. |
| Document preview / import: `QLWebKitBundle`, `iWorkImport` | 2 | 3,004 | The former declares the `QLWebKitBundle` principal class; system writing-tools and extension executables directly link the latter. Exercise preview/import and record the actual host process. |
| Audio service: `VirtualAudio` | 1 | 20,714 | Its HAL plug-in manifest registers `New_VirtualAudio_PlugIn`. Validate the audio-service load and input/output path; an app's image list does not describe the service's code. |
| Tool/audit support: `IDEDebugGaugeDataProviders`, `DTODRAssetStatus`, `AccessibilityAuditCategories` | 3 | 479 | The first two remain standalone DVT support bundles whose selection must be traced. The audit bundle declares `AXAuditPluginPEP`. Enabling a debug session alone does not prove these optional bundles were exercised. |

`RemoteInjectionAgent` and `swift-inspect` are executables and are outside the
1,019-library inventory. Audit their complete executable/dependency paths with
`--include-executables` before declaring either tool workflow covered. For each
accepted library, preserve complete lowering, native signing and resource
seals, repeat application, rollback and patch deselection. The seven incomplete
plans must be investigated rather than included in a bulk conversion.

## Why `libobjcMsgSend46` can remain in this inventory

The file at `/System/Cryptexes/OS/usr/lib/objc/libobjcMsgSend46.dylib` is a real
X1 image, not a false positive based on its name. Its UUID is
`499B1C67-EA76-3662-A0C9-A5B6BA209758`; the 86,016-byte file has a complete plan
for 27 instructions in one code-signature slot: 21 `addpt`, three `pacibsppc`
and three `autibsppc`. Its install name is `/usr/lib/objc/libobjcMsgSend46.dylib`.

A follow-up LLDB inspection of a development app on the same updated guest
established the relevant distinction:

- The process's image list contained `libobjcMsgSend.dylib` and numbered images
  `1` through `33`. It contained none of `34` through `48`; an explicit lookup
  of `libobjcMsgSend46.dylib` returned no matching module.
- The inspected `libobjc.A.dylib` links to the unnumbered
  `/usr/lib/objc/libobjcMsgSend.dylib`. The startup backtrace also entered that
  image's `_objc_msgSend_uncached` function.
- The unnumbered image's live Mach-O header carries `MH_DYLIB_IN_CACHE`.
  Its instructions at image-relative offsets `0x838`, `0xCA0` and `0xD18`
  were `add`, `pacibsp` and `autibsp`, respectively. The corresponding offsets
  in the standalone `46` file still hold `addpt`, `pacibsppc` and `autibsppc`.

The existing shared-cache bootstrap patch includes the unnumbered image and
`libobjcMsgSend5.dylib`; the remaining-cache patch selects the other cache
images. This is separate from the standalone-file audit. The measured startup
therefore uses an already lowered shared-cache implementation while the
unloaded standalone `46` file correctly remains `needsLowering`. This finding
does not identify the numbering scheme or prove that another firmware or
workflow can never load `46`.

There is also a separate reason an on-disk candidate can coexist with a running
process: `VPhoneX1Exception.c` handles eligible `EXC_BAD_INSTRUCTION` faults by
lowering the instruction in a private copy of the process's memory page. It
does not rewrite the file, so a later disk audit still finds the original
instruction. No such repair of `46` was observed here, and this fallback is not
needed to explain this case. Debuggers and crash reporters can intercept the
fault before that handler, as the accessibility startup failure demonstrated.

Keep the 15 standalone entries in the 1,019-image inventory. Promote one to
required coverage only with its actual loading/execution evidence and the
conversion, signing and runtime checks above. An unused file is not validated
by successful app startup; neither is an executed file validated merely by
the existence of the exception fallback.

## Reproducing and tracking changes

```zsh
vphone-cli cfw audit-arm64e-x1 /path/to/readonly/System-volume --json --strict > x1-audit.json
```

Use a volume root containing `System/`, `usr/` and `Applications/`. For the
remaining set, select report rows with empty `declarations` and a `state` other
than `noLoweringNeeded`. Preserve the firmware version and compare paths, states
and counts on every userland/cryptex update. The full measured report correctly
exits with status 1. No update or runtime interception is enabled by this report.

Recompute the annotations separately: compare the selected cache's
`dyld_cache_image_info` paths and `dyld_cache_image_text_info` UUIDs with each
standalone image's logical path, `LC_ID_DYLIB` and `LC_UUID`. Verify the selected
cache UUID and read completeness. Audit matching cache-extracted images, then
compare actual loaded images and executed sites for the target workflow. Do not
derive cache coverage from a framework name, a sibling library or an install
name without its UUID. The standalone audit itself does not emit the cache or
review annotations and its strict exit status is unchanged.

Only guest system paths and static aggregate/site metadata are reproduced
below. Private application identifiers, workstation paths, device identities,
process logs and binary payloads are omitted.

## Incomplete plans

Example offsets are relative to the image file, including a universal-slice
base where applicable. They identify analysis evidence, not hardcoded patch
anchors; at most 16 examples are retained per image.

| Image | Planned instructions | Unvisited candidates | Example file offsets |
| --- | ---: | ---: | --- |
| `/System/Cryptexes/OS/usr/lib/libramrod.dylib` | 6,110 | 1 | `0x9A364` |
| `/System/DriverKit/usr/lib/system/libsystem_platform_debug.dylib` | 231 | 2 | `0x4FC4`, `0xA380` |
| `/System/Library/SyncBundles/AirFair.syncBundle/AirFair` | 42 | 31 | `0x15580`, `0x22408`, `0x26000`, `0x26C5C`, `0x29D50`, `0x31A3C`, `0x36690`, `0x38BAC`, `0x38BD0`, `0x47F8C`, `0x483E4`, `0x4C62C`, `0x4FD54`, `0x56FA0`, `0x57BB4`, `0x57BD4` |
| `/System/Library/SyncBundles/AirFair2.syncBundle/AirFair2` | 119 | 296 | `0x4C618`, `0x5EC54`, `0x5ECAC`, `0x5ED00`, `0x67A68`, `0x6CDE8`, `0x6CF3C`, `0x6D0C4`, `0x6D1B4`, `0x7C50C`, `0x8199C`, `0x83F20`, `0x9305C`, `0x937BC`, `0x98AD4`, `0x98ADC` |
| `/System/Library/SyncBundles/MusicLibrary.syncBundle/MusicLibrary` | 780 | 296 | `0xA78C`, `0x1CDC8`, `0x1CE20`, `0x1CE74`, `0x25BDC`, `0x2AF5C`, `0x2B0B0`, `0x2B238`, `0x2B328`, `0x3A680`, `0x3FB10`, `0x42094`, `0x511D0`, `0x51930`, `0x56C48`, `0x56C50` |
| `/usr/lib/libCoreFP.dylib` | 4 | 163 | `0x6D88`, `0x7094`, `0x9D44`, `0xD14C`, `0xD1EC`, `0xD27C`, `0xDD84`, `0x11600`, `0x11B64`, `0x11D94`, `0x14510`, `0x161F4`, `0x19590`, `0x1976C`, `0x19B58`, `0x19B88` |
| `/usr/lib/libCoreKE.dylib` | 983 | 1,107 | `0x9744`, `0x9768`, `0xA440`, `0xA8D4`, `0xFEA8`, `0xFEB8`, `0x100D8`, `0x1CDE8`, `0x1CE04`, `0x1CF10`, `0x1DFE4`, `0x3C0D4`, `0x3C310`, `0x3C31C`, `0x3C33C`, `0x3C35C` |

## Directory summary

| Directory group | Images | Complete plans | Incomplete plans | Planned instructions | Original bytes |
| --- | ---: | ---: | ---: | ---: | ---: |
| `/System/Library/PreferenceBundles` | 200 | 200 | 0 | 142,124 | 49,979,696 |
| `/System/Library/NanoPreferenceBundles` | 80 | 80 | 0 | 23,978 | 11,211,056 |
| `/System/Library/Assistant` | 78 | 78 | 0 | 130,156 | 55,573,088 |
| `/System/Library/DataClassMigrators` | 49 | 49 | 0 | 4,392 | 4,563,152 |
| `/System/Library/Accounts` | 44 | 44 | 0 | 4,358 | 4,293,792 |
| `/System/Library/AccessibilityBundles` | 42 | 42 | 0 | 25,646 | 10,036,128 |
| `/System/Library/PrivateFrameworks` | 41 | 41 | 0 | 252,993 | 58,369,664 |
| `/System/Library/Snippets` | 39 | 39 | 0 | 18,803 | 7,926,832 |
| `/System/Library/HIDPlugins` | 38 | 38 | 0 | 16,076 | 6,715,632 |
| `/System/Library/UserEventPlugins` | 33 | 33 | 0 | 4,119 | 3,017,920 |
| `/System/Cryptexes/OS` | 28 | 27 | 1 | 69,625 | 20,097,904 |
| `/System/Library/FlowTools` | 26 | 26 | 0 | 31,169 | 14,327,120 |
| `/System/Library/Messages` | 23 | 23 | 0 | 67,630 | 18,506,208 |
| `/System/Library/ScreenReader` | 22 | 22 | 0 | 3,181 | 3,286,288 |
| `/System/Library/NanoTimeKit` | 20 | 20 | 0 | 4,384 | 2,509,040 |
| `/System/Library/Settings` | 20 | 20 | 0 | 6,313 | 2,598,240 |
| `/System/Library/Audio` | 19 | 19 | 0 | 12,855 | 3,676,096 |
| `/System/Library/Health` | 19 | 19 | 0 | 7,120 | 3,087,168 |
| `/System/Library/ControlCenter` | 16 | 16 | 0 | 4,589 | 2,049,984 |
| `/System/Library/Siri` | 16 | 16 | 0 | 8,337 | 3,769,296 |
| `/System/Library/Extensions` | 12 | 12 | 0 | 2,081 | 1,174,624 |
| `/System/Library/SyncBundles` | 11 | 8 | 3 | 2,312 | 6,495,504 |
| `/System/Library/UsageBundles` | 11 | 11 | 0 | 489 | 905,600 |
| `/System/DriverKit` | 10 | 9 | 1 | 12,500 | 5,081,600 |
| `/System/Library/DigitalSeparation` | 10 | 10 | 0 | 2,349 | 1,127,552 |
| `/System/Library/VideoProcessors` | 10 | 10 | 0 | 9,059 | 3,059,488 |
| `/System/Library/Frameworks` | 9 | 9 | 0 | 2,052 | 1,253,152 |
| `/System/Cryptexes/App` | 7 | 7 | 0 | 3,489 | 3,888,720 |
| `/System/Library/DistributedEvaluation` | 7 | 7 | 0 | 728 | 696,800 |
| `/System/Library/SetupAssistantBundles` | 7 | 7 | 0 | 359 | 577,504 |
| `/System/Library/Trace` | 7 | 7 | 0 | 1,330 | 725,648 |
| `/System/Library/CoreImage` | 6 | 6 | 0 | 2,444 | 1,082,736 |
| `/System/Library/SystemConfiguration` | 6 | 6 | 0 | 3,156 | 1,316,880 |
| `/System/Library/RelevanceEngine` | 5 | 5 | 0 | 499 | 469,568 |
| `/System/Library/AppleMediaServices` | 4 | 4 | 0 | 15,402 | 2,965,440 |
| `/System/Library/BulletinDistributor` | 4 | 4 | 0 | 238 | 320,976 |
| `/System/Library/SpringBoardPlugins` | 4 | 4 | 0 | 880 | 498,800 |
| `/usr/lib` | 4 | 2 | 2 | 6,860 | 25,701,584 |
| `/System/Library/KerberosPlugins` | 3 | 3 | 0 | 92 | 212,496 |
| `/System/Library/PreferencesSyncBundles` | 3 | 3 | 0 | 100 | 172,944 |
| `/System/Library/CloudRecommendations` | 2 | 2 | 0 | 12 | 142,256 |
| `/System/Library/Recents` | 2 | 2 | 0 | 12 | 139,680 |
| `/System/Library/StreamingExtractorPlugins` | 2 | 2 | 0 | 1,710 | 543,936 |
| `/System/Library/UserNotifications` | 2 | 2 | 0 | 190 | 121,696 |
| `/System/Library/Video` | 2 | 2 | 0 | 4,975 | 3,352,032 |
| `/Applications/DiagnosticsService.app/PlugIns` | 1 | 1 | 0 | 412 | 295,296 |
| `/Applications/LimitedModeShieldApp.app/Frameworks` | 1 | 1 | 0 | 1,135 | 408,592 |
| `/Applications/MobileReplayer.app/PlugIns` | 1 | 1 | 0 | 459 | 221,312 |
| `/Applications/MomentsUIService.app/Frameworks` | 1 | 1 | 0 | 1,007 | 426,800 |
| `/Library/Audio/Plug-Ins` | 1 | 1 | 0 | 20,714 | 7,777,120 |
| `/System/Library/CoreServices` | 1 | 1 | 0 | 357 | 134,480 |
| `/System/Library/DuetActivityScheduler` | 1 | 1 | 0 | 14 | 70,160 |
| `/System/Library/FamilyCircle` | 1 | 1 | 0 | 14 | 70,976 |
| `/System/Library/MediaStreamPlugins` | 1 | 1 | 0 | 96 | 106,752 |
| `/System/Library/Photos` | 1 | 1 | 0 | 63 | 77,744 |
| `/System/Library/Posters` | 1 | 1 | 0 | 167 | 95,136 |
| `/System/Library/RemoteUI` | 1 | 1 | 0 | 31 | 71,872 |
| `/System/Library/ScreenTime` | 1 | 1 | 0 | 6 | 70,528 |
| `/System/Library/TextInput` | 1 | 1 | 0 | 10 | 69,824 |
| `/System/Library/VoiceServices` | 1 | 1 | 0 | 11 | 70,672 |
| `/System/Library/iCloudSettings` | 1 | 1 | 0 | 82 | 99,552 |

## Complete inventory

All 1,019 unique paths are listed once below, grouped by directory.
`Slots` counts the code-signature slots re-attested by the in-memory plan.
`Cache relation` and `Review` use the evidence and definitions above; all
original paths, plan states and numeric fields remain unchanged.

### `/Applications/DiagnosticsService.app/PlugIns` (1)

| Image path | Plan state | Original bytes | Planned instructions | Slots | Unvisited | Cache relation | Review |
| --- | --- | ---: | ---: | ---: | ---: | --- | --- |
| `/Applications/DiagnosticsService.app/PlugIns/Diagnostic-8441.appex/Frameworks/DiagnosticsSupport.framework/DiagnosticsSupport` | `needsLowering` | 295,296 | 412 | 14 | 0 | `sameBuildInCache` | `checkResolution` |

### `/Applications/LimitedModeShieldApp.app/Frameworks` (1)

| Image path | Plan state | Original bytes | Planned instructions | Slots | Unvisited | Cache relation | Review |
| --- | --- | ---: | ---: | ---: | ---: | --- | --- |
| `/Applications/LimitedModeShieldApp.app/Frameworks/AppManagedFeaturesUI.framework/AppManagedFeaturesUI` | `needsLowering` | 408,592 | 1,135 | 35 | 0 | `sameBuildInCache` | `checkResolution` |

### `/Applications/MobileReplayer.app/PlugIns` (1)

| Image path | Plan state | Original bytes | Planned instructions | Slots | Unvisited | Cache relation | Review |
| --- | --- | ---: | ---: | ---: | ---: | --- | --- |
| `/Applications/MobileReplayer.app/PlugIns/EAGLReplayControllerSupport.mrplugin/EAGLReplayControllerSupport` | `needsLowering` | 221,312 | 459 | 20 | 0 | `notInCache` | `unranked` |

### `/Applications/MomentsUIService.app/Frameworks` (1)

| Image path | Plan state | Original bytes | Planned instructions | Slots | Unvisited | Cache relation | Review |
| --- | --- | ---: | ---: | ---: | ---: | --- | --- |
| `/Applications/MomentsUIService.app/Frameworks/MomentsUIServiceCore.framework/MomentsUIServiceCore` | `needsLowering` | 426,800 | 1,007 | 24 | 0 | `notInCache` | `unranked` |

### `/Library/Audio/Plug-Ins` (1)

| Image path | Plan state | Original bytes | Planned instructions | Slots | Unvisited | Cache relation | Review |
| --- | --- | ---: | ---: | ---: | ---: | --- | --- |
| `/Library/Audio/Plug-Ins/HAL/VirtualAudio.plugin/VirtualAudio` | `needsLowering` | 7,777,120 | 20,714 | 322 | 0 | `notInCache` | `P2` |

### `/System/Cryptexes/App` (7)

| Image path | Plan state | Original bytes | Planned instructions | Slots | Unvisited | Cache relation | Review |
| --- | --- | ---: | ---: | ---: | ---: | --- | --- |
| `/System/Cryptexes/App/System/Library/Accounts/Notification/CloudBookmarksAccountsNotifier.bundle/CloudBookmarksAccountsNotifier` | `needsLowering` | 168,864 | 8 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Cryptexes/App/System/Library/Assistant/Plugins/Safari.assistantBundle/Safari` | `needsLowering` | 169,136 | 6 | 1 | 0 | `notInCache` | `unranked` |
| `/System/Cryptexes/App/System/Library/Assistant/Plugins/WebSearch.assistantBundle/WebSearch` | `needsLowering` | 169,152 | 6 | 1 | 0 | `notInCache` | `unranked` |
| `/System/Cryptexes/App/System/Library/DataClassMigrators/CloudTabsMigrator.migrator/CloudTabsMigrator` | `needsLowering` | 172,720 | 2 | 1 | 0 | `notInCache` | `unranked` |
| `/System/Cryptexes/App/System/Library/DataClassMigrators/MobileSafari.migrator/MobileSafari` | `needsLowering` | 299,360 | 187 | 7 | 0 | `notInCache` | `unranked` |
| `/System/Cryptexes/App/System/Library/PreferenceBundles/MobileSafariSettings.bundle/MobileSafariSettings` | `needsLowering` | 2,697,872 | 3,178 | 111 | 0 | `notInCache` | `unranked` |
| `/System/Cryptexes/App/System/Library/UsageBundles/SafariUsageBundle.bundle/SafariUsageBundle` | `needsLowering` | 211,616 | 102 | 3 | 0 | `notInCache` | `unranked` |

### `/System/Cryptexes/OS` (28)

| Image path | Plan state | Original bytes | Planned instructions | Slots | Unvisited | Cache relation | Review |
| --- | --- | ---: | ---: | ---: | ---: | --- | --- |
| `/System/Cryptexes/OS/System/Library/Accounts/DataclassOwners/Bookmarks.bundle/Bookmarks` | `needsLowering` | 73,264 | 51 | 3 | 0 | `notInCache` | `unranked` |
| `/System/Cryptexes/OS/System/Library/PrivateFrameworks/DeviceRecoveryBrainSupport.framework/DeviceRecoveryBrainSupport` | `needsLowering` | 392,848 | 714 | 28 | 0 | `notInCache` | `unranked` |
| `/System/Cryptexes/OS/System/Library/PrivateFrameworks/Nodes.framework/Nodes` | `needsLowering` | 5,507,760 | 29,974 | 834 | 0 | `notInCache` | `unranked` |
| `/System/Cryptexes/OS/System/Library/PrivateFrameworks/NodesUI.framework/NodesUI` | `needsLowering` | 3,747,520 | 10,182 | 463 | 0 | `notInCache` | `unranked` |
| `/System/Cryptexes/OS/System/Library/PrivateFrameworks/PeriodicSystemMetricsCore.framework/PeriodicSystemMetricsCore` | `needsLowering` | 280,336 | 776 | 17 | 0 | `notInCache` | `unranked` |
| `/System/Cryptexes/OS/System/Library/PrivateFrameworks/PlugInKitDaemon.framework/PlugInKitDaemon` | `needsLowering` | 306,400 | 568 | 24 | 0 | `notInCache` | `unranked` |
| `/System/Cryptexes/OS/System/Library/PrivateFrameworks/VisualTestKit.framework/VisualTestKit` | `needsLowering` | 219,760 | 232 | 7 | 0 | `notInCache` | `unranked` |
| `/System/Cryptexes/OS/System/Library/PrivateFrameworks/WeaveReplay.framework/WeaveReplay` | `needsLowering` | 293,216 | 1,146 | 41 | 0 | `notInCache` | `unranked` |
| `/System/Cryptexes/OS/System/Library/PrivateFrameworks/iCloudDriveCore.framework/Frameworks/libos-brain.dylib` | `needsLowering` | 2,824,896 | 12,179 | 493 | 0 | `notInCache` | `unranked` |
| `/System/Cryptexes/OS/usr/lib/libramrod.dylib` | `incomplete` | 2,192,896 | 6,110 | 239 | 1 | `notInCache` | `analyze` |
| `/System/Cryptexes/OS/usr/lib/libstdc++.6.0.9.dylib` | `needsLowering` | 824,432 | 3,643 | 74 | 0 | `notInCache` | `unranked` |
| `/System/Cryptexes/OS/usr/lib/objc/libobjcMsgSend34.dylib` | `needsLowering` | 86,016 | 27 | 1 | 0 | `familyOnly` | `observeLoading` |
| `/System/Cryptexes/OS/usr/lib/objc/libobjcMsgSend35.dylib` | `needsLowering` | 86,016 | 27 | 1 | 0 | `familyOnly` | `observeLoading` |
| `/System/Cryptexes/OS/usr/lib/objc/libobjcMsgSend36.dylib` | `needsLowering` | 86,016 | 27 | 1 | 0 | `familyOnly` | `observeLoading` |
| `/System/Cryptexes/OS/usr/lib/objc/libobjcMsgSend37.dylib` | `needsLowering` | 86,016 | 27 | 1 | 0 | `familyOnly` | `observeLoading` |
| `/System/Cryptexes/OS/usr/lib/objc/libobjcMsgSend38.dylib` | `needsLowering` | 86,016 | 27 | 1 | 0 | `familyOnly` | `observeLoading` |
| `/System/Cryptexes/OS/usr/lib/objc/libobjcMsgSend39.dylib` | `needsLowering` | 86,016 | 27 | 1 | 0 | `familyOnly` | `observeLoading` |
| `/System/Cryptexes/OS/usr/lib/objc/libobjcMsgSend40.dylib` | `needsLowering` | 86,016 | 27 | 1 | 0 | `familyOnly` | `observeLoading` |
| `/System/Cryptexes/OS/usr/lib/objc/libobjcMsgSend41.dylib` | `needsLowering` | 86,016 | 27 | 1 | 0 | `familyOnly` | `observeLoading` |
| `/System/Cryptexes/OS/usr/lib/objc/libobjcMsgSend42.dylib` | `needsLowering` | 86,016 | 27 | 1 | 0 | `familyOnly` | `observeLoading` |
| `/System/Cryptexes/OS/usr/lib/objc/libobjcMsgSend43.dylib` | `needsLowering` | 86,016 | 27 | 1 | 0 | `familyOnly` | `observeLoading` |
| `/System/Cryptexes/OS/usr/lib/objc/libobjcMsgSend44.dylib` | `needsLowering` | 86,016 | 27 | 1 | 0 | `familyOnly` | `observeLoading` |
| `/System/Cryptexes/OS/usr/lib/objc/libobjcMsgSend45.dylib` | `needsLowering` | 86,016 | 27 | 1 | 0 | `familyOnly` | `observeLoading` |
| `/System/Cryptexes/OS/usr/lib/objc/libobjcMsgSend46.dylib` | `needsLowering` | 86,016 | 27 | 1 | 0 | `familyOnly` | `observeLoading` |
| `/System/Cryptexes/OS/usr/lib/objc/libobjcMsgSend47.dylib` | `needsLowering` | 86,016 | 27 | 1 | 0 | `familyOnly` | `observeLoading` |
| `/System/Cryptexes/OS/usr/lib/objc/libobjcMsgSend48.dylib` | `needsLowering` | 86,016 | 27 | 1 | 0 | `familyOnly` | `observeLoading` |
| `/System/Cryptexes/OS/usr/libexec/AppleLatticeSupport.framework/AppleLatticeSupport` | `needsLowering` | 114,704 | 40 | 2 | 0 | `sameBuildInCache` | `checkResolution` |
| `/System/Cryptexes/OS/usr/libexec/Moments.framework/Moments` | `needsLowering` | 2,029,632 | 3,605 | 115 | 0 | `sameBuildInCache` | `checkResolution` |

### `/System/DriverKit` (10)

| Image path | Plan state | Original bytes | Planned instructions | Slots | Unvisited | Cache relation | Review |
| --- | --- | ---: | ---: | ---: | ---: | --- | --- |
| `/System/DriverKit/usr/lib/libSystem_debug.dylib` | `needsLowering` | 90,560 | 12 | 2 | 0 | `notInCache` | `unranked` |
| `/System/DriverKit/usr/lib/system/libdispatch_debug.dylib` | `needsLowering` | 1,101,856 | 2,420 | 180 | 0 | `notInCache` | `unranked` |
| `/System/DriverKit/usr/lib/system/libdispatch_profile.dylib` | `needsLowering` | 661,184 | 1,956 | 71 | 0 | `notInCache` | `unranked` |
| `/System/DriverKit/usr/lib/system/libsystem_blocks_debug.dylib` | `needsLowering` | 86,608 | 15 | 1 | 0 | `notInCache` | `unranked` |
| `/System/DriverKit/usr/lib/system/libsystem_blocks_profile.dylib` | `needsLowering` | 86,608 | 15 | 1 | 0 | `notInCache` | `unranked` |
| `/System/DriverKit/usr/lib/system/libsystem_c_debug.dylib` | `needsLowering` | 1,069,600 | 4,181 | 188 | 0 | `notInCache` | `unranked` |
| `/System/DriverKit/usr/lib/system/libsystem_malloc_debug.dylib` | `needsLowering` | 1,428,032 | 3,087 | 236 | 0 | `notInCache` | `unranked` |
| `/System/DriverKit/usr/lib/system/libsystem_platform_debug.dylib` | `incomplete` | 201,792 | 231 | 11 | 2 | `notInCache` | `analyze` |
| `/System/DriverKit/usr/lib/system/libsystem_pthread_debug.dylib` | `needsLowering` | 246,160 | 456 | 29 | 0 | `notInCache` | `unranked` |
| `/System/DriverKit/usr/lib/system/libsystem_trace_debug.dylib` | `needsLowering` | 109,200 | 127 | 11 | 0 | `notInCache` | `unranked` |

### `/System/Library/AccessibilityBundles` (42)

| Image path | Plan state | Original bytes | Planned instructions | Slots | Unvisited | Cache relation | Review |
| --- | --- | ---: | ---: | ---: | ---: | --- | --- |
| `/System/Library/AccessibilityBundles/AXAVSPluginService.axuiservice/AXAVSPluginService` | `needsLowering` | 89,776 | 57 | 3 | 0 | `notInCache` | `unranked` |
| `/System/Library/AccessibilityBundles/AXAggregateStatisticsServer.axuiservice/AXAggregateStatisticsServer` | `needsLowering` | 201,680 | 494 | 17 | 0 | `notInCache` | `unranked` |
| `/System/Library/AccessibilityBundles/AXAssetAndDataServer.axuiservice/AXAssetAndDataServer` | `needsLowering` | 129,312 | 86 | 6 | 0 | `notInCache` | `unranked` |
| `/System/Library/AccessibilityBundles/AXAuditAXUIService.axuiservice/AXAuditAXUIService` | `needsLowering` | 89,184 | 63 | 3 | 0 | `notInCache` | `unranked` |
| `/System/Library/AccessibilityBundles/AXBannerUIServer.axuiservice/AXBannerUIServer` | `needsLowering` | 70,688 | 20 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/AccessibilityBundles/AXBuddyBundle.bundle/AXBuddyBundle` | `needsLowering` | 110,960 | 181 | 5 | 0 | `notInCache` | `unranked` |
| `/System/Library/AccessibilityBundles/AXContainerManagerServer.axuiservice/AXContainerManagerServer` | `needsLowering` | 72,032 | 34 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/AccessibilityBundles/AXElementInteractionUIServer.axuiservice/AXElementInteractionUIServer` | `needsLowering` | 72,384 | 43 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/AccessibilityBundles/AXFeatureOverrideServer.axuiservice/AXFeatureOverrideServer` | `needsLowering` | 96,640 | 133 | 4 | 0 | `notInCache` | `unranked` |
| `/System/Library/AccessibilityBundles/AXFlashScreenUIServer.axuiservice/AXFlashScreenUIServer` | `needsLowering` | 71,088 | 22 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/AccessibilityBundles/AXFloatingUIKeyboardUIServer.axuiservice/AXFloatingUIKeyboardUIServer` | `needsLowering` | 74,336 | 53 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/AccessibilityBundles/AXGuestPassServer.axuiservice/AXGuestPassServer` | `needsLowering` | 325,488 | 1,199 | 39 | 0 | `notInCache` | `unranked` |
| `/System/Library/AccessibilityBundles/AXHapticMusicServer.axuiservice/AXHapticMusicServer` | `needsLowering` | 318,560 | 915 | 44 | 0 | `notInCache` | `unranked` |
| `/System/Library/AccessibilityBundles/AXIDSServer.axuiservice/AXIDSServer` | `needsLowering` | 91,808 | 46 | 4 | 0 | `notInCache` | `unranked` |
| `/System/Library/AccessibilityBundles/AXImageExplorerServer.axuiservice/AXImageExplorerServer` | `needsLowering` | 583,984 | 2,403 | 81 | 0 | `notInCache` | `unranked` |
| `/System/Library/AccessibilityBundles/AXLocalizationCaptionServer.axuiservice/AXLocalizationCaptionServer` | `needsLowering` | 92,448 | 98 | 5 | 0 | `notInCache` | `unranked` |
| `/System/Library/AccessibilityBundles/AXMotionCuesServer.axuiservice/AXMotionCuesServer` | `needsLowering` | 399,696 | 1,440 | 47 | 0 | `notInCache` | `unranked` |
| `/System/Library/AccessibilityBundles/AXNameRecognitionPluginService.axuiservice/AXNameRecognitionPluginService` | `needsLowering` | 118,368 | 144 | 6 | 0 | `notInCache` | `unranked` |
| `/System/Library/AccessibilityBundles/AXUltronPluginService.axuiservice/AXUltronPluginService` | `needsLowering` | 114,272 | 152 | 6 | 0 | `notInCache` | `unranked` |
| `/System/Library/AccessibilityBundles/AXWatchRemoteScreenUIServer.axuiservice/AXWatchRemoteScreenUIServer` | `needsLowering` | 95,056 | 128 | 3 | 0 | `notInCache` | `unranked` |
| `/System/Library/AccessibilityBundles/AccessibilityReaderUIServer.axuiservice/AccessibilityReaderUIServer` | `needsLowering` | 94,304 | 111 | 3 | 0 | `notInCache` | `unranked` |
| `/System/Library/AccessibilityBundles/AssistiveTouch.axuiservice/AssistiveTouch` | `needsLowering` | 89,472 | 41 | 3 | 0 | `notInCache` | `unranked` |
| `/System/Library/AccessibilityBundles/BackTapUIServer.axuiservice/BackTapUIServer` | `needsLowering` | 174,400 | 477 | 11 | 0 | `notInCache` | `unranked` |
| `/System/Library/AccessibilityBundles/BrailleUI.axuiservice/BrailleUI` | `needsLowering` | 95,600 | 165 | 4 | 0 | `notInCache` | `unranked` |
| `/System/Library/AccessibilityBundles/ClarityUIServer.axuiservice/ClarityUIServer` | `needsLowering` | 157,296 | 385 | 14 | 0 | `notInCache` | `unranked` |
| `/System/Library/AccessibilityBundles/DisplayFilterUIServer.axuiservice/DisplayFilterUIServer` | `needsLowering` | 90,656 | 54 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/AccessibilityBundles/GAXBackboardServer.bundle/GAXBackboardServer` | `needsLowering` | 447,520 | 1,313 | 43 | 0 | `notInCache` | `unranked` |
| `/System/Library/AccessibilityBundles/GAXClient.bundle/GAXClient` | `needsLowering` | 175,712 | 322 | 11 | 0 | `notInCache` | `unranked` |
| `/System/Library/AccessibilityBundles/GAXSpringboardServer.bundle/GAXSpringboardServer` | `needsLowering` | 316,672 | 694 | 23 | 0 | `notInCache` | `unranked` |
| `/System/Library/AccessibilityBundles/GuidedAccess.axuiservice/GuidedAccess` | `needsLowering` | 519,984 | 1,497 | 48 | 0 | `notInCache` | `unranked` |
| `/System/Library/AccessibilityBundles/HoverTextUIServer.axuiservice/HoverTextUIServer` | `needsLowering` | 92,752 | 143 | 4 | 0 | `notInCache` | `unranked` |
| `/System/Library/AccessibilityBundles/InvertColorsManager.bundle/InvertColorsManager` | `needsLowering` | 809,664 | 1,491 | 32 | 0 | `notInCache` | `unranked` |
| `/System/Library/AccessibilityBundles/LiveSpeechUIService.axuiservice/LiveSpeechUIService` | `needsLowering` | 1,240,752 | 5,132 | 180 | 0 | `notInCache` | `unranked` |
| `/System/Library/AccessibilityBundles/ScreenSharing.axuiservice/ScreenSharing` | `needsLowering` | 128,752 | 207 | 8 | 0 | `notInCache` | `unranked` |
| `/System/Library/AccessibilityBundles/ScreenSharingAccessibilityServer.axuiservice/ScreenSharingAccessibilityServer` | `needsLowering` | 96,016 | 139 | 5 | 0 | `notInCache` | `unranked` |
| `/System/Library/AccessibilityBundles/SpeakServer.axuiservice/SpeakServer` | `needsLowering` | 93,424 | 70 | 4 | 0 | `notInCache` | `unranked` |
| `/System/Library/AccessibilityBundles/SpeakThis.axuiservice/SpeakThis` | `needsLowering` | 297,632 | 814 | 27 | 0 | `notInCache` | `unranked` |
| `/System/Library/AccessibilityBundles/StickyKeys.axuiservice/StickyKeys` | `needsLowering` | 89,920 | 57 | 3 | 0 | `notInCache` | `unranked` |
| `/System/Library/AccessibilityBundles/TouchAccommodations.axuiservice/TouchAccommodations` | `needsLowering` | 130,400 | 231 | 8 | 0 | `notInCache` | `unranked` |
| `/System/Library/AccessibilityBundles/VisualAlerts.bundle/VisualAlerts` | `needsLowering` | 70,832 | 11 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/AccessibilityBundles/VoiceOver.axuiservice/VoiceOver` | `needsLowering` | 394,512 | 1,166 | 37 | 0 | `notInCache` | `unranked` |
| `/System/Library/AccessibilityBundles/ZoomWindow.axuiservice/ZoomWindow` | `needsLowering` | 1,212,096 | 3,415 | 106 | 0 | `notInCache` | `unranked` |

### `/System/Library/Accounts` (44)

| Image path | Plan state | Original bytes | Planned instructions | Slots | Unvisited | Cache relation | Review |
| --- | --- | ---: | ---: | ---: | ---: | --- | --- |
| `/System/Library/Accounts/AppleIDLoginPlugins/FMFAppleIDLoginPlugin.bundle/FMFAppleIDLoginPlugin` | `needsLowering` | 69,792 | 4 | 1 | 0 | `notInCache` | `unranked` |
| `/System/Library/Accounts/AppleIDLoginPlugins/FaceTimeAppleIDLoginPlugin.bundle/FaceTimeAppleIDLoginPlugin` | `needsLowering` | 69,136 | 2 | 1 | 0 | `notInCache` | `unranked` |
| `/System/Library/Accounts/AppleIDLoginPlugins/GameCenterAppleIDLoginPlugin.bundle/GameCenterAppleIDLoginPlugin` | `needsLowering` | 69,824 | 6 | 1 | 0 | `notInCache` | `unranked` |
| `/System/Library/Accounts/AppleIDLoginPlugins/ISLoginPlugin.bundle/ISLoginPlugin` | `needsLowering` | 92,480 | 42 | 5 | 0 | `notInCache` | `unranked` |
| `/System/Library/Accounts/AppleIDLoginPlugins/MadridAppleIDLoginPlugin.bundle/MadridAppleIDLoginPlugin` | `needsLowering` | 68,976 | 2 | 1 | 0 | `notInCache` | `unranked` |
| `/System/Library/Accounts/AppleIDLoginPlugins/iCloudAppleIDLoginPlugin.bundle/iCloudAppleIDLoginPlugin` | `needsLowering` | 72,272 | 22 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/Accounts/Authentication/AAGKAuthenticationPlugin.bundle/AAGKAuthenticationPlugin` | `needsLowering` | 147,040 | 306 | 10 | 0 | `notInCache` | `unranked` |
| `/System/Library/Accounts/Authentication/AAIDSAuthenticationPlugin.bundle/AAIDSAuthenticationPlugin` | `needsLowering` | 130,096 | 191 | 7 | 0 | `notInCache` | `unranked` |
| `/System/Library/Accounts/Authentication/AppleIDAuthenticationDelegates/AppleAccountAuthenticationDelegate.bundle/AppleAccountAuthenticationDelegate` | `needsLowering` | 71,088 | 6 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/Accounts/Authentication/AppleIDAuthenticationDelegates/GameCenterAppleIDAuthenticationDelegate.bundle/GameCenterAppleIDAuthenticationDelegate` | `needsLowering` | 89,792 | 18 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/Accounts/Authentication/AppleIDAuthenticationDelegates/IDSAuthenticationDelegatePlugin.bundle/IDSAuthenticationDelegatePlugin` | `needsLowering` | 73,232 | 16 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/Accounts/Authentication/GameCenterAccountAuthenticationPlugin.bundle/GameCenterAccountAuthenticationPlugin` | `needsLowering` | 133,600 | 332 | 10 | 0 | `notInCache` | `unranked` |
| `/System/Library/Accounts/DataclassOwners/Calendar.bundle/Calendar` | `needsLowering` | 72,464 | 22 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/Accounts/DataclassOwners/CloudDocsDataclassOwnerPlugin.bundle/CloudDocsDataclassOwnerPlugin` | `needsLowering` | 70,912 | 20 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/Accounts/DataclassOwners/ContactsDataclassOwner.bundle/ContactsDataclassOwner` | `needsLowering` | 128,096 | 327 | 9 | 0 | `notInCache` | `unranked` |
| `/System/Library/Accounts/DataclassOwners/DeviceEnrollmentDataClassPlugIn.bundle/DeviceEnrollmentDataClassPlugIn` | `needsLowering` | 111,712 | 169 | 6 | 0 | `notInCache` | `unranked` |
| `/System/Library/Accounts/DataclassOwners/FreeformDataclassOwner.bundle/FreeformDataclassOwner` | `needsLowering` | 514,816 | 867 | 36 | 0 | `notInCache` | `unranked` |
| `/System/Library/Accounts/DataclassOwners/HealthDataclassOwnerPlugin.bundle/HealthDataclassOwnerPlugin` | `needsLowering` | 90,688 | 53 | 3 | 0 | `notInCache` | `unranked` |
| `/System/Library/Accounts/DataclassOwners/JournalDataclassOwner.bundle/JournalDataclassOwner` | `needsLowering` | 153,936 | 253 | 12 | 0 | `notInCache` | `unranked` |
| `/System/Library/Accounts/DataclassOwners/KeychainDataclassOwner.bundle/KeychainDataclassOwner` | `needsLowering` | 71,392 | 12 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/Accounts/DataclassOwners/MessagesDataclassOwner.bundle/MessagesDataclassOwner` | `needsLowering` | 90,000 | 45 | 3 | 0 | `notInCache` | `unranked` |
| `/System/Library/Accounts/DataclassOwners/News.bundle/News` | `needsLowering` | 94,368 | 114 | 3 | 0 | `notInCache` | `unranked` |
| `/System/Library/Accounts/DataclassOwners/Notes.bundle/Notes` | `needsLowering` | 72,432 | 60 | 3 | 0 | `notInCache` | `unranked` |
| `/System/Library/Accounts/DataclassOwners/PassbookDataclassOwnerPlugin.bundle/PassbookDataclassOwnerPlugin` | `needsLowering` | 74,080 | 60 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/Accounts/DataclassOwners/RemindersDataclassOwnerPlugin.bundle/RemindersDataclassOwnerPlugin` | `needsLowering` | 88,896 | 70 | 4 | 0 | `notInCache` | `unranked` |
| `/System/Library/Accounts/DataclassOwners/SiriDataclassOwner.bundle/SiriDataclassOwner` | `needsLowering` | 114,672 | 226 | 8 | 0 | `notInCache` | `unranked` |
| `/System/Library/Accounts/DataclassOwners/StocksDataclassOwner.bundle/StocksDataclassOwner` | `needsLowering` | 73,344 | 59 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/Accounts/Notification/ASDAccountNotificationPlugin.bundle/ASDAccountNotificationPlugin` | `needsLowering` | 90,320 | 73 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/Accounts/Notification/AccountNotificationPlugin.bundle/AccountNotificationPlugin` | `needsLowering` | 70,832 | 21 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/Accounts/Notification/AccountSuggestionNotificationPlugin.bundle/AccountSuggestionNotificationPlugin` | `needsLowering` | 71,168 | 12 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/Accounts/Notification/CloudDocsAccountNotificationPlugin.bundle/CloudDocsAccountNotificationPlugin` | `needsLowering` | 88,416 | 60 | 4 | 0 | `notInCache` | `unranked` |
| `/System/Library/Accounts/Notification/CoreAccessoriesAccountNotificationPlugin.bundle/CoreAccessoriesAccountNotificationPlugin` | `needsLowering` | 70,928 | 3 | 1 | 0 | `notInCache` | `unranked` |
| `/System/Library/Accounts/Notification/DeviceManagementClientAccountNotificationPlugin.bundle/DeviceManagementClientAccountNotificationPlugin` | `needsLowering` | 71,696 | 16 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/Accounts/Notification/MBPrebuddyAccountNotificationPlugin.bundle/MBPrebuddyAccountNotificationPlugin` | `needsLowering` | 71,312 | 10 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/Accounts/Notification/MCAccountNotificationPlugin.bundle/MCAccountNotificationPlugin` | `needsLowering` | 69,920 | 6 | 1 | 0 | `notInCache` | `unranked` |
| `/System/Library/Accounts/Notification/NanoPassbookAccountNotificationPlugin.bundle/NanoPassbookAccountNotificationPlugin` | `needsLowering` | 70,096 | 2 | 1 | 0 | `notInCache` | `unranked` |
| `/System/Library/Accounts/Notification/RemoteManagementAccountNotificationPlugin.bundle/RemoteManagementAccountNotificationPlugin` | `needsLowering` | 93,168 | 88 | 3 | 0 | `notInCache` | `unranked` |
| `/System/Library/Accounts/Notification/SyncedDefaultsAccountNotificationPlugin.bundle/SyncedDefaultsAccountNotificationPlugin` | `needsLowering` | 70,416 | 10 | 1 | 0 | `notInCache` | `unranked` |
| `/System/Library/Accounts/Notification/TVAppServicesAccountNotificationPlugin.bundle/TVAppServicesAccountNotificationPlugin` | `needsLowering` | 73,376 | 51 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/Accounts/Notification/TransparencyAccountNotification.bundle/TransparencyAccountNotification` | `needsLowering` | 70,224 | 16 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/Accounts/ServiceOwners/AACloudServiceOwner.bundle/AACloudServiceOwner` | `needsLowering` | 71,664 | 58 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/Accounts/ServiceOwners/AMSMediaServiceOwner.bundle/AMSMediaServiceOwner` | `needsLowering` | 168,832 | 538 | 17 | 0 | `notInCache` | `unranked` |
| `/System/Library/Accounts/ServiceOwners/GCCloudServiceOwner.bundle/GCCloudServiceOwner` | `needsLowering` | 72,640 | 38 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/Accounts/ServiceOwners/IDSServiceOwner.bundle/IDSServiceOwner` | `needsLowering` | 89,648 | 52 | 3 | 0 | `notInCache` | `unranked` |

### `/System/Library/AppleMediaServices` (4)

| Image path | Plan state | Original bytes | Planned instructions | Slots | Unvisited | Cache relation | Review |
| --- | --- | ---: | ---: | ---: | ---: | --- | --- |
| `/System/Library/AppleMediaServices/AMSMediaServiceOwner/PlugIns/AMSMediaServiceOwnerUIProvider.bundle/AMSMediaServiceOwnerUIProvider` | `needsLowering` | 72,064 | 21 | 1 | 0 | `notInCache` | `unranked` |
| `/System/Library/AppleMediaServices/DynamicUI/PlugIns/CoreDynamicUIPlugin.bundle/CoreDynamicUIPlugin` | `needsLowering` | 977,840 | 5,291 | 138 | 0 | `notInCache` | `unranked` |
| `/System/Library/AppleMediaServices/DynamicUI/PlugIns/StoreDynamicUIPlugin.bundle/StoreDynamicUIPlugin` | `needsLowering` | 1,843,552 | 10,073 | 285 | 0 | `notInCache` | `unranked` |
| `/System/Library/AppleMediaServices/WebUI/PlugIns/MusicAMSUIWebPlugin.bundle/MusicAMSUIWebPlugin` | `needsLowering` | 71,984 | 17 | 2 | 0 | `notInCache` | `unranked` |

### `/System/Library/Assistant` (78)

| Image path | Plan state | Original bytes | Planned instructions | Slots | Unvisited | Cache relation | Review |
| --- | --- | ---: | ---: | ---: | ---: | --- | --- |
| `/System/Library/Assistant/FlowDelegatePlugins/AlarmFlowPlugin.bundle/AlarmFlowPlugin` | `needsLowering` | 1,525,472 | 4,062 | 245 | 0 | `notInCache` | `unranked` |
| `/System/Library/Assistant/FlowDelegatePlugins/AppLaunchPlugin.bundle/AppLaunchPlugin` | `needsLowering` | 74,720 | 56 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/Assistant/FlowDelegatePlugins/AudioFlowDelegatePlugin.bundle/AudioFlowDelegatePlugin` | `needsLowering` | 3,870,688 | 10,295 | 660 | 0 | `notInCache` | `unranked` |
| `/System/Library/Assistant/FlowDelegatePlugins/CAMRootFlowPlugin.bundle/CAMRootFlowPlugin` | `needsLowering` | 560,480 | 2,111 | 86 | 0 | `notInCache` | `unranked` |
| `/System/Library/Assistant/FlowDelegatePlugins/CalendarFlowDelegatePlugin.bundle/CalendarFlowDelegatePlugin` | `needsLowering` | 71,824 | 28 | 1 | 0 | `notInCache` | `unranked` |
| `/System/Library/Assistant/FlowDelegatePlugins/CarCommandsFlowDelegatePlugin.bundle/CarCommandsFlowDelegatePlugin` | `needsLowering` | 2,098,544 | 11,368 | 316 | 0 | `notInCache` | `unranked` |
| `/System/Library/Assistant/FlowDelegatePlugins/ClockFlowPlugin.bundle/ClockFlowPlugin` | `needsLowering` | 205,568 | 430 | 19 | 0 | `notInCache` | `unranked` |
| `/System/Library/Assistant/FlowDelegatePlugins/ContactsFlowDelegatePlugin.bundle/ContactsFlowDelegatePlugin` | `needsLowering` | 77,376 | 74 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/Assistant/FlowDelegatePlugins/ControlsFlowDelegatePlugin.bundle/ControlsFlowDelegatePlugin` | `needsLowering` | 71,168 | 14 | 1 | 0 | `notInCache` | `unranked` |
| `/System/Library/Assistant/FlowDelegatePlugins/DailyBriefingFlowPlugin.bundle/DailyBriefingFlowPlugin` | `needsLowering` | 997,952 | 5,447 | 147 | 0 | `notInCache` | `unranked` |
| `/System/Library/Assistant/FlowDelegatePlugins/EmergencyFlowPlugin.bundle/EmergencyFlowPlugin` | `needsLowering` | 516,640 | 1,643 | 73 | 0 | `notInCache` | `unranked` |
| `/System/Library/Assistant/FlowDelegatePlugins/FindMyFlowPlugin.bundle/FindMyFlowPlugin` | `needsLowering` | 96,832 | 104 | 3 | 0 | `notInCache` | `unranked` |
| `/System/Library/Assistant/FlowDelegatePlugins/GenerativeAssistantEnablementFlowPlugin.bundle/GenerativeAssistantEnablementFlowPlugin` | `needsLowering` | 73,152 | 36 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/Assistant/FlowDelegatePlugins/GeoFlowDelegatePlugin.bundle/GeoFlowDelegatePlugin` | `needsLowering` | 2,685,856 | 5,624 | 173 | 0 | `notInCache` | `unranked` |
| `/System/Library/Assistant/FlowDelegatePlugins/HealthFlowDelegatePlugin.bundle/HealthFlowDelegatePlugin` | `needsLowering` | 840,896 | 3,583 | 104 | 0 | `notInCache` | `unranked` |
| `/System/Library/Assistant/FlowDelegatePlugins/HomeAutomationFlowDelegatePlugin.bundle/HomeAutomationFlowDelegatePlugin` | `needsLowering` | 75,088 | 28 | 1 | 0 | `notInCache` | `unranked` |
| `/System/Library/Assistant/FlowDelegatePlugins/HomeCommunicationFlowDelegatePlugin.bundle/HomeCommunicationFlowDelegatePlugin` | `needsLowering` | 976,752 | 4,484 | 138 | 0 | `notInCache` | `unranked` |
| `/System/Library/Assistant/FlowDelegatePlugins/IFFlowPlugin.bundle/IFFlowPlugin` | `needsLowering` | 694,192 | 1,622 | 103 | 0 | `notInCache` | `unranked` |
| `/System/Library/Assistant/FlowDelegatePlugins/IdentityFlowPlugin.bundle/IdentityFlowPlugin` | `needsLowering` | 73,968 | 49 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/Assistant/FlowDelegatePlugins/InformationFlowPlugin.bundle/InformationFlowPlugin` | `needsLowering` | 2,407,504 | 4,107 | 175 | 0 | `notInCache` | `unranked` |
| `/System/Library/Assistant/FlowDelegatePlugins/MailFlowDelegatePlugin.bundle/MailFlowDelegatePlugin` | `needsLowering` | 73,664 | 30 | 1 | 0 | `notInCache` | `unranked` |
| `/System/Library/Assistant/FlowDelegatePlugins/MessagesFlowDelegatePlugin.bundle/MessagesFlowDelegatePlugin` | `needsLowering` | 70,176 | 9 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/Assistant/FlowDelegatePlugins/NotebookFlowPlugin.bundle/NotebookFlowPlugin` | `needsLowering` | 71,280 | 19 | 1 | 0 | `notInCache` | `unranked` |
| `/System/Library/Assistant/FlowDelegatePlugins/NotificationsFlowDelegatePlugin.bundle/NotificationsFlowDelegatePlugin` | `needsLowering` | 74,352 | 42 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/Assistant/FlowDelegatePlugins/PCSReadingFlowDelegatePlugin.bundle/PCSReadingFlowDelegatePlugin` | `needsLowering` | 74,000 | 46 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/Assistant/FlowDelegatePlugins/PaymentsFlowDelegatePlugin.bundle/PaymentsFlowDelegatePlugin` | `needsLowering` | 88,944 | 32 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/Assistant/FlowDelegatePlugins/PhoneCallFlowDelegatePlugin.bundle/PhoneCallFlowDelegatePlugin` | `needsLowering` | 17,592,384 | 32,484 | 1,034 | 0 | `notInCache` | `unranked` |
| `/System/Library/Assistant/FlowDelegatePlugins/ReaderFlowPlugin.bundle/ReaderFlowPlugin` | `needsLowering` | 73,328 | 32 | 1 | 0 | `notInCache` | `unranked` |
| `/System/Library/Assistant/FlowDelegatePlugins/SafetySessionFlowPlugin.bundle/SafetySessionFlowPlugin` | `needsLowering` | 95,808 | 167 | 3 | 0 | `notInCache` | `unranked` |
| `/System/Library/Assistant/FlowDelegatePlugins/SettingsFlowDelegatePlugin.bundle/SettingsFlowDelegatePlugin` | `needsLowering` | 104,944 | 100 | 4 | 0 | `notInCache` | `unranked` |
| `/System/Library/Assistant/FlowDelegatePlugins/SiriLinkFlowPlugin.bundle/SiriLinkFlowPlugin` | `needsLowering` | 8,298,784 | 15,239 | 500 | 0 | `notInCache` | `unranked` |
| `/System/Library/Assistant/FlowDelegatePlugins/SiriSuggestionsFlowPlugin.bundle/SiriSuggestionsFlowPlugin` | `needsLowering` | 159,168 | 316 | 13 | 0 | `notInCache` | `unranked` |
| `/System/Library/Assistant/FlowDelegatePlugins/SocialConversationFlowDelegatePlugin.bundle/SocialConversationFlowDelegatePlugin` | `needsLowering` | 1,166,336 | 5,504 | 169 | 0 | `notInCache` | `unranked` |
| `/System/Library/Assistant/FlowDelegatePlugins/SystemCommandsFlowDelegatePlugin.bundle/SystemCommandsFlowDelegatePlugin` | `needsLowering` | 74,416 | 48 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/Assistant/FlowDelegatePlugins/TimerFlowDelegatePlugin.bundle/TimerFlowDelegatePlugin` | `needsLowering` | 1,669,648 | 4,939 | 280 | 0 | `notInCache` | `unranked` |
| `/System/Library/Assistant/FlowDelegatePlugins/TranslationFlowDelegatePlugin.bundle/TranslationFlowDelegatePlugin` | `needsLowering` | 72,944 | 42 | 1 | 0 | `notInCache` | `unranked` |
| `/System/Library/Assistant/FlowDelegatePlugins/VideoFlowDelegatePlugin.bundle/VideoFlowDelegatePlugin` | `needsLowering` | 74,192 | 38 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/Assistant/FlowDelegatePlugins/WellnessFlowPlugin.bundle/WellnessFlowPlugin` | `needsLowering` | 2,049,440 | 8,096 | 329 | 0 | `notInCache` | `unranked` |
| `/System/Library/Assistant/Plugins/Accessibility.assistantBundle/Accessibility` | `needsLowering` | 72,752 | 18 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/Assistant/Plugins/Applications.assistantBundle/Applications` | `needsLowering` | 209,872 | 568 | 16 | 0 | `notInCache` | `unranked` |
| `/System/Library/Assistant/Plugins/ChatKitAssistant.assistantBundle/ChatKitAssistant` | `needsLowering` | 133,232 | 95 | 8 | 0 | `notInCache` | `unranked` |
| `/System/Library/Assistant/Plugins/DeviceControl.assistantBundle/DeviceControl` | `needsLowering` | 71,312 | 30 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/Assistant/Plugins/DoNotDisturbAssistant.assistantBundle/DoNotDisturbAssistant` | `needsLowering` | 72,224 | 10 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/Assistant/Plugins/Mail.assistantBundle/Mail` | `needsLowering` | 94,544 | 68 | 5 | 0 | `notInCache` | `unranked` |
| `/System/Library/Assistant/Plugins/Maps.assistantBundle/Maps` | `needsLowering` | 511,376 | 602 | 21 | 0 | `notInCache` | `unranked` |
| `/System/Library/Assistant/Plugins/MobileTimer.assistantBundle/MobileTimer` | `needsLowering` | 149,040 | 334 | 14 | 0 | `notInCache` | `unranked` |
| `/System/Library/Assistant/Plugins/NanoAppSync.assistantBundle/NanoAppSync` | `needsLowering` | 92,064 | 22 | 3 | 0 | `notInCache` | `unranked` |
| `/System/Library/Assistant/Plugins/NotificationsSettingsAssistant.assistantBundle/NotificationsSettingsAssistant` | `needsLowering` | 71,280 | 8 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/Assistant/Plugins/ParsecContextSync.assistantBundle/ParsecContextSync` | `needsLowering` | 70,944 | 8 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/Assistant/Plugins/ParsecSubscriptionServiceSync.assistantBundle/ParsecSubscriptionServiceSync` | `needsLowering` | 71,744 | 14 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/Assistant/Plugins/PreferencesAssistant.assistantBundle/PreferencesAssistant` | `needsLowering` | 229,952 | 217 | 9 | 0 | `notInCache` | `unranked` |
| `/System/Library/Assistant/Plugins/SiriFindMyBundle.assistantBundle/SiriFindMyBundle` | `needsLowering` | 115,136 | 161 | 6 | 0 | `notInCache` | `unranked` |
| `/System/Library/Assistant/Plugins/SiriPrivateLearningAnalytics.assistantBundle/SiriPrivateLearningAnalytics` | `needsLowering` | 75,152 | 30 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/Assistant/Plugins/Social.assistantBundle/Social` | `needsLowering` | 89,136 | 108 | 3 | 0 | `notInCache` | `unranked` |
| `/System/Library/Assistant/Plugins/Stocks.assistantBundle/Stocks` | `needsLowering` | 71,584 | 10 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/Assistant/Plugins/UILite.assistantBundle/UILite` | `needsLowering` | 71,504 | 2 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/Assistant/Plugins/WatchListAssistant.assistantBundle/WatchListAssistant` | `needsLowering` | 104,416 | 41 | 4 | 0 | `notInCache` | `unranked` |
| `/System/Library/Assistant/Plugins/activity.assistantBundle/activity` | `needsLowering` | 114,128 | 155 | 8 | 0 | `notInCache` | `unranked` |
| `/System/Library/Assistant/PrivateLearningPlugins/SiriPrivateLearningInferencePlugin.bundle/SiriPrivateLearningInferencePlugin` | `needsLowering` | 326,368 | 1,062 | 43 | 0 | `notInCache` | `unranked` |
| `/System/Library/Assistant/PrivateLearningPlugins/SiriReferenceResolutionMetricsPlugin.bundle/SiriReferenceResolutionMetricsPlugin` | `needsLowering` | 159,792 | 392 | 12 | 0 | `notInCache` | `unranked` |
| `/System/Library/Assistant/Suggestions/InferenceBridge/SiriSuggestionsInferenceBridge.bundle/SiriSuggestionsInferenceBridge` | `needsLowering` | 105,040 | 173 | 5 | 0 | `notInCache` | `unranked` |
| `/System/Library/Assistant/Suggestions/SKEBridge/SiriSuggestionsSKEBridge.bundle/SiriSuggestionsSKEBridge` | `needsLowering` | 94,336 | 87 | 3 | 0 | `notInCache` | `unranked` |
| `/System/Library/Assistant/UIPlugins/AcousticId.siriUIBundle/AcousticId` | `needsLowering` | 93,008 | 94 | 4 | 0 | `notInCache` | `unranked` |
| `/System/Library/Assistant/UIPlugins/AddressBook.siriUIBundle/AddressBook` | `needsLowering` | 110,400 | 100 | 4 | 0 | `notInCache` | `unranked` |
| `/System/Library/Assistant/UIPlugins/Calendar.siriUIBundle/Calendar` | `needsLowering` | 109,696 | 82 | 5 | 0 | `notInCache` | `unranked` |
| `/System/Library/Assistant/UIPlugins/GeneralKnowledge.siriUIBundle/GeneralKnowledge` | `needsLowering` | 187,136 | 282 | 11 | 0 | `notInCache` | `unranked` |
| `/System/Library/Assistant/UIPlugins/Intents.siriUIBundle/Intents` | `needsLowering` | 111,280 | 125 | 5 | 0 | `notInCache` | `unranked` |
| `/System/Library/Assistant/UIPlugins/Mail.siriUIBundle/Mail` | `needsLowering` | 173,904 | 235 | 11 | 0 | `notInCache` | `unranked` |
| `/System/Library/Assistant/UIPlugins/Maps.siriUIBundle/Maps` | `needsLowering` | 517,536 | 505 | 17 | 0 | `notInCache` | `unranked` |
| `/System/Library/Assistant/UIPlugins/MobileTimer.siriUIBundle/MobileTimer` | `needsLowering` | 133,344 | 204 | 6 | 0 | `notInCache` | `unranked` |
| `/System/Library/Assistant/UIPlugins/Notes.siriUIBundle/Notes` | `needsLowering` | 196,560 | 258 | 11 | 0 | `notInCache` | `unranked` |
| `/System/Library/Assistant/UIPlugins/Notifications.siriUIBundle/Notifications` | `needsLowering` | 70,064 | 10 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/Assistant/UIPlugins/RemindersSiriUIPlugin.siriUIBundle/RemindersSiriUIPlugin` | `needsLowering` | 250,832 | 941 | 28 | 0 | `notInCache` | `unranked` |
| `/System/Library/Assistant/UIPlugins/Settings.siriUIBundle/Settings` | `needsLowering` | 98,800 | 154 | 4 | 0 | `notInCache` | `unranked` |
| `/System/Library/Assistant/UIPlugins/Stocks.siriUIBundle/Stocks` | `needsLowering` | 112,032 | 89 | 6 | 0 | `notInCache` | `unranked` |
| `/System/Library/Assistant/UIPlugins/System.siriUIBundle/System` | `needsLowering` | 167,664 | 381 | 12 | 0 | `notInCache` | `unranked` |
| `/System/Library/Assistant/UIPlugins/UniversalSearch.siriUIBundle/UniversalSearch` | `needsLowering` | 92,864 | 63 | 4 | 0 | `notInCache` | `unranked` |
| `/System/Library/Assistant/UIPlugins/WAAnswer.siriUIBundle/WAAnswer` | `needsLowering` | 92,560 | 70 | 3 | 0 | `notInCache` | `unranked` |

### `/System/Library/Audio` (19)

| Image path | Plan state | Original bytes | Planned instructions | Slots | Unvisited | Cache relation | Review |
| --- | --- | ---: | ---: | ---: | ---: | --- | --- |
| `/System/Library/Audio/MIDI Drivers/AppleIDAMDriver.plugin/AppleIDAMDriver` | `needsLowering` | 213,600 | 922 | 29 | 0 | `notInCache` | `unranked` |
| `/System/Library/Audio/MIDI Drivers/AppleMIDIBluetoothDriver.plugin/AppleMIDIBluetoothDriver` | `needsLowering` | 163,760 | 468 | 15 | 0 | `notInCache` | `unranked` |
| `/System/Library/Audio/MIDI Drivers/AppleMIDINetworkDriver.plugin/AppleMIDINetworkDriver` | `needsLowering` | 360,832 | 1,499 | 58 | 0 | `notInCache` | `unranked` |
| `/System/Library/Audio/MIDI Drivers/AppleMIDIUSBDriver.plugin/AppleMIDIUSBDriver` | `needsLowering` | 230,144 | 992 | 32 | 0 | `notInCache` | `unranked` |
| `/System/Library/Audio/MIDI Drivers/YamahaUSBMIDIDriver.plugin/YamahaUSBMIDIDriver` | `needsLowering` | 229,952 | 964 | 31 | 0 | `notInCache` | `unranked` |
| `/System/Library/Audio/Plug-Ins/AVC/AVCHalogen.driver/AVCHalogen` | `needsLowering` | 136,944 | 364 | 11 | 0 | `notInCache` | `unranked` |
| `/System/Library/Audio/Plug-Ins/HAL/AirPlayHalogen.driver/AirPlayHalogen` | `needsLowering` | 154,096 | 508 | 15 | 0 | `notInCache` | `unranked` |
| `/System/Library/Audio/Plug-Ins/HAL/AppleAOPAudioPlugin.driver/AppleAOPAudioPlugin` | `needsLowering` | 265,632 | 1,108 | 25 | 0 | `notInCache` | `unranked` |
| `/System/Library/Audio/Plug-Ins/HAL/AppleTimeSyncAudioClock.driver/AppleTimeSyncAudioClock` | `needsLowering` | 110,416 | 154 | 7 | 0 | `notInCache` | `unranked` |
| `/System/Library/Audio/Plug-Ins/HAL/BTAudioHALPlugin.driver/BTAudioHALPlugin` | `needsLowering` | 817,936 | 4,197 | 123 | 0 | `notInCache` | `unranked` |
| `/System/Library/Audio/Plug-Ins/HAL/BasebandVoice.driver/BasebandVoice` | `needsLowering` | 130,208 | 208 | 11 | 0 | `notInCache` | `unranked` |
| `/System/Library/Audio/Plug-Ins/HAL/BuiltinAudioPlugin.driver/BuiltinAudioPlugin` | `needsLowering` | 75,184 | 14 | 3 | 0 | `notInCache` | `unranked` |
| `/System/Library/Audio/Plug-Ins/HAL/CarPlayHalogen.driver/CarPlayHalogen` | `needsLowering` | 111,952 | 250 | 8 | 0 | `notInCache` | `unranked` |
| `/System/Library/Audio/Plug-Ins/HAL/NetworkUplinkClock.driver/NetworkUplinkClock` | `needsLowering` | 112,128 | 211 | 10 | 0 | `notInCache` | `unranked` |
| `/System/Library/Audio/Plug-Ins/HAL/OctaviaHalogen.driver/OctaviaHalogen` | `needsLowering` | 191,712 | 583 | 21 | 0 | `notInCache` | `unranked` |
| `/System/Library/Audio/Plug-Ins/HAL/usbaudiodxpc.driver/usbaudiodxpc` | `needsLowering` | 94,000 | 78 | 4 | 0 | `notInCache` | `unranked` |
| `/System/Library/Audio/Plug-Ins/RemoteInput/AudioAppleSiriRemoteInput.bundle/AudioAppleSiriRemoteInput` | `needsLowering` | 91,552 | 114 | 4 | 0 | `notInCache` | `unranked` |
| `/System/Library/Audio/Plug-Ins/RemoteInput/JarvisPlugin.bundle/JarvisPlugin` | `needsLowering` | 95,360 | 121 | 4 | 0 | `notInCache` | `unranked` |
| `/System/Library/Audio/Plug-Ins/RemoteInput/RemoteAudioInputPlugin.bundle/RemoteAudioInputPlugin` | `needsLowering` | 90,688 | 100 | 3 | 0 | `notInCache` | `unranked` |

### `/System/Library/BulletinDistributor` (4)

| Image path | Plan state | Original bytes | Planned instructions | Slots | Unvisited | Cache relation | Review |
| --- | --- | ---: | ---: | ---: | ---: | --- | --- |
| `/System/Library/BulletinDistributor/PingSubscribers/NanoCalendarPingSubscriber.bundle/NanoCalendarPingSubscriber` | `needsLowering` | 111,440 | 226 | 5 | 0 | `notInCache` | `unranked` |
| `/System/Library/BulletinDistributor/PingSubscribers/NanoHealthPingSubscriber.bundle/NanoHealthPingSubscriber` | `needsLowering` | 70,176 | 4 | 1 | 0 | `notInCache` | `unranked` |
| `/System/Library/BulletinDistributor/PingSubscribers/SearchPartyNotificationPingSubscriber.bundle/SearchPartyNotificationPingSubscriber` | `needsLowering` | 69,680 | 4 | 1 | 0 | `notInCache` | `unranked` |
| `/System/Library/BulletinDistributor/PingSubscribers/ShortcutsPingSubscriber.bundle/ShortcutsPingSubscriber` | `needsLowering` | 69,680 | 4 | 1 | 0 | `notInCache` | `unranked` |

### `/System/Library/CloudRecommendations` (2)

| Image path | Plan state | Original bytes | Planned instructions | Slots | Unvisited | Cache relation | Review |
| --- | --- | ---: | ---: | ---: | ---: | --- | --- |
| `/System/Library/CloudRecommendations/ClientSources/ICQReviewLargeFilesRecommendations.bundle/ICQReviewLargeFilesRecommendations` | `needsLowering` | 71,456 | 8 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/CloudRecommendations/ClientSources/PhotosCloudRecommendations.bundle/PhotosCloudRecommendations` | `needsLowering` | 70,800 | 4 | 1 | 0 | `notInCache` | `unranked` |

### `/System/Library/ControlCenter` (16)

| Image path | Plan state | Original bytes | Planned instructions | Slots | Unvisited | Cache relation | Review |
| --- | --- | ---: | ---: | ---: | ---: | --- | --- |
| `/System/Library/ControlCenter/Bundles/AirDropModule.bundle/AirDropModule` | `needsLowering` | 69,232 | 4 | 1 | 0 | `notInCache` | `unranked` |
| `/System/Library/ControlCenter/Bundles/AudioConferenceControlCenterModule.bundle/AudioConferenceControlCenterModule` | `needsLowering` | 315,344 | 1,066 | 35 | 0 | `notInCache` | `unranked` |
| `/System/Library/ControlCenter/Bundles/BluetoothModule.bundle/BluetoothModule` | `needsLowering` | 69,424 | 4 | 1 | 0 | `notInCache` | `unranked` |
| `/System/Library/ControlCenter/Bundles/ContinuousExposeModule.bundle/ContinuousExposeModule` | `needsLowering` | 72,384 | 47 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/ControlCenter/Bundles/DMCRRTSControlCenterModule.bundle/DMCRRTSControlCenterModule` | `needsLowering` | 94,784 | 137 | 4 | 0 | `notInCache` | `unranked` |
| `/System/Library/ControlCenter/Bundles/FocusUIModule.bundle/FocusUIModule` | `needsLowering` | 111,104 | 148 | 6 | 0 | `notInCache` | `unranked` |
| `/System/Library/ControlCenter/Bundles/NFCControlCenterModule.bundle/NFCControlCenterModule` | `needsLowering` | 109,088 | 219 | 7 | 0 | `notInCache` | `unranked` |
| `/System/Library/ControlCenter/Bundles/PingMyWatchControlCenterUI.bundle/PingMyWatchControlCenterUI` | `needsLowering` | 71,664 | 30 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/ControlCenter/Bundles/RPControlCenterModuleHQLR.bundle/RPControlCenterModuleHQLR` | `needsLowering` | 288,864 | 1,230 | 31 | 0 | `notInCache` | `unranked` |
| `/System/Library/ControlCenter/Bundles/ReplayKitModule.bundle/ReplayKitModule` | `needsLowering` | 163,056 | 355 | 13 | 0 | `notInCache` | `unranked` |
| `/System/Library/ControlCenter/Bundles/SatelliteModule.bundle/SatelliteModule` | `needsLowering` | 69,328 | 4 | 1 | 0 | `notInCache` | `unranked` |
| `/System/Library/ControlCenter/Bundles/SilenceCallsCCWidget.bundle/SilenceCallsCCWidget` | `needsLowering` | 69,728 | 8 | 1 | 0 | `notInCache` | `unranked` |
| `/System/Library/ControlCenter/Bundles/SystemQuickNoteModule.bundle/SystemQuickNoteModule` | `needsLowering` | 74,528 | 56 | 3 | 0 | `notInCache` | `unranked` |
| `/System/Library/ControlCenter/Bundles/VPNModule.bundle/VPNModule` | `needsLowering` | 69,200 | 4 | 1 | 0 | `notInCache` | `unranked` |
| `/System/Library/ControlCenter/Bundles/VideoConferenceControlCenterModule.bundle/VideoConferenceControlCenterModule` | `needsLowering` | 332,880 | 1,273 | 40 | 0 | `notInCache` | `unranked` |
| `/System/Library/ControlCenter/Bundles/WiFiModule.bundle/WiFiModule` | `needsLowering` | 69,376 | 4 | 1 | 0 | `notInCache` | `unranked` |

### `/System/Library/CoreImage` (6)

| Image path | Plan state | Original bytes | Planned instructions | Slots | Unvisited | Cache relation | Review |
| --- | --- | ---: | ---: | ---: | ---: | --- | --- |
| `/System/Library/CoreImage/CIInpainting.cifilter/CIInpainting` | `needsLowering` | 144,640 | 154 | 11 | 0 | `notInCache` | `P1` |
| `/System/Library/CoreImage/CIPassThrough.cifilter/CIPassThrough` | `needsLowering` | 70,944 | 16 | 2 | 0 | `notInCache` | `P1` |
| `/System/Library/CoreImage/CIStyleEngine.cifilter/CIStyleEngine` | `needsLowering` | 69,760 | 4 | 1 | 0 | `notInCache` | `P1` |
| `/System/Library/CoreImage/CIToneMap.cifilter/CIToneMap` | `needsLowering` | 69,760 | 4 | 1 | 0 | `notInCache` | `P1` |
| `/System/Library/CoreImage/CIVisionFilters.cifilter/CIVisionFilters` | `needsLowering` | 92,768 | 64 | 3 | 0 | `notInCache` | `P1` |
| `/System/Library/CoreImage/PortraitFilters.cifilter/PortraitFilters` | `needsLowering` | 634,864 | 2,202 | 73 | 0 | `notInCache` | `P1` |

### `/System/Library/CoreServices` (1)

| Image path | Plan state | Original bytes | Planned instructions | Slots | Unvisited | Cache relation | Review |
| --- | --- | ---: | ---: | ---: | ---: | --- | --- |
| `/System/Library/CoreServices/CSUIAUpcallBundle.bundle/CSUIAUpcallBundle` | `needsLowering` | 134,480 | 357 | 10 | 0 | `notInCache` | `unranked` |

### `/System/Library/DataClassMigrators` (49)

| Image path | Plan state | Original bytes | Planned instructions | Slots | Unvisited | Cache relation | Review |
| --- | --- | ---: | ---: | ---: | ---: | --- | --- |
| `/System/Library/DataClassMigrators/00LaunchServicesMigrator.migrator/00LaunchServicesMigrator` | `needsLowering` | 70,352 | 14 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/DataClassMigrators/AMFIMigrator.migrator/AMFIMigrator` | `needsLowering` | 69,584 | 2 | 1 | 0 | `notInCache` | `unranked` |
| `/System/Library/DataClassMigrators/AccessibilityDataMigration.migrator/AccessibilityDataMigration` | `needsLowering` | 91,744 | 66 | 3 | 0 | `notInCache` | `unranked` |
| `/System/Library/DataClassMigrators/Accounts.migrator/Accounts` | `needsLowering` | 72,384 | 32 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/DataClassMigrators/AccountsObsolescence.migrator/AccountsObsolescence` | `needsLowering` | 69,472 | 4 | 1 | 0 | `notInCache` | `unranked` |
| `/System/Library/DataClassMigrators/AddressBookLegacy.migrator/AddressBookLegacy` | `needsLowering` | 91,840 | 64 | 4 | 0 | `notInCache` | `unranked` |
| `/System/Library/DataClassMigrators/AirTrafficMigrator.migrator/AirTrafficMigrator` | `needsLowering` | 71,616 | 16 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/DataClassMigrators/AnisetteMigrator.migrator/AnisetteMigrator` | `needsLowering` | 73,040 | 12 | 1 | 0 | `notInCache` | `unranked` |
| `/System/Library/DataClassMigrators/AppUserDataMigrator.migrator/AppUserDataMigrator` | `needsLowering` | 73,744 | 38 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/DataClassMigrators/AppleAccountMigrator.migrator/AppleAccountMigrator` | `needsLowering` | 89,376 | 48 | 3 | 0 | `notInCache` | `unranked` |
| `/System/Library/DataClassMigrators/BuddyMigrator.migrator/BuddyMigrator` | `needsLowering` | 415,152 | 1,551 | 44 | 0 | `notInCache` | `unranked` |
| `/System/Library/DataClassMigrators/CallHistoryDataMigrator.migrator/CallHistoryDataMigrator` | `needsLowering` | 71,440 | 16 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/DataClassMigrators/CloudRecentsMigrator.migrator/CloudRecentsMigrator` | `needsLowering` | 72,752 | 58 | 3 | 0 | `notInCache` | `unranked` |
| `/System/Library/DataClassMigrators/ContainerMigrator.migrator/ContainerMigrator` | `needsLowering` | 68,560 | 8 | 1 | 0 | `notInCache` | `unranked` |
| `/System/Library/DataClassMigrators/CookieDataMigrator.migrator/CookieDataMigrator` | `needsLowering` | 69,840 | 8 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/DataClassMigrators/CoreLocationMigrator.migrator/CoreLocationMigrator` | `needsLowering` | 68,912 | 2 | 1 | 0 | `notInCache` | `unranked` |
| `/System/Library/DataClassMigrators/CoreTimeMigrator.migrator/CoreTimeMigrator` | `needsLowering` | 68,832 | 2 | 1 | 0 | `notInCache` | `unranked` |
| `/System/Library/DataClassMigrators/FitnessMigrator.migrator/FitnessMigrator` | `needsLowering` | 70,400 | 8 | 1 | 0 | `notInCache` | `unranked` |
| `/System/Library/DataClassMigrators/HAENDataMigrator.migrator/HAENDataMigrator` | `needsLowering` | 70,656 | 6 | 1 | 0 | `notInCache` | `unranked` |
| `/System/Library/DataClassMigrators/InternationalSupportMigrator.migrator/InternationalSupportMigrator` | `needsLowering` | 69,216 | 2 | 1 | 0 | `notInCache` | `unranked` |
| `/System/Library/DataClassMigrators/KeyboardMigrator.migrator/KeyboardMigrator` | `needsLowering` | 108,992 | 62 | 6 | 0 | `notInCache` | `unranked` |
| `/System/Library/DataClassMigrators/KeyboardUIMigrator.migrator/KeyboardUIMigrator` | `needsLowering` | 69,424 | 10 | 1 | 0 | `notInCache` | `unranked` |
| `/System/Library/DataClassMigrators/KeychainMigrator.migrator/KeychainMigrator` | `needsLowering` | 68,992 | 2 | 1 | 0 | `notInCache` | `unranked` |
| `/System/Library/DataClassMigrators/LegacyMessageAccountsMigrator.migrator/LegacyMessageAccountsMigrator` | `needsLowering` | 91,728 | 50 | 3 | 0 | `notInCache` | `unranked` |
| `/System/Library/DataClassMigrators/MCCleanup.migrator/MCCleanup` | `needsLowering` | 69,280 | 6 | 1 | 0 | `notInCache` | `unranked` |
| `/System/Library/DataClassMigrators/MCMDM.migrator/MCMDM` | `needsLowering` | 69,152 | 4 | 1 | 0 | `notInCache` | `unranked` |
| `/System/Library/DataClassMigrators/MCProfile.migrator/MCProfile` | `needsLowering` | 72,800 | 30 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/DataClassMigrators/MKBMigrator.migrator/MKBMigrator` | `needsLowering` | 69,264 | 2 | 1 | 0 | `notInCache` | `unranked` |
| `/System/Library/DataClassMigrators/MSUDataMigrator.migrator/MSUDataMigrator` | `needsLowering` | 75,760 | 26 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/DataClassMigrators/MediaLibrary.migrator/MediaLibrary` | `needsLowering` | 70,848 | 8 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/DataClassMigrators/MergeBuddyProvisioningResponse.migrator/MergeBuddyProvisioningResponse` | `needsLowering` | 90,464 | 85 | 4 | 0 | `notInCache` | `unranked` |
| `/System/Library/DataClassMigrators/MessageAccountsMigrator.migrator/MessageAccountsMigrator` | `needsLowering` | 74,096 | 28 | 3 | 0 | `notInCache` | `unranked` |
| `/System/Library/DataClassMigrators/MobileActivationMigrator.migrator/MobileActivationMigrator` | `needsLowering` | 186,304 | 102 | 4 | 0 | `notInCache` | `unranked` |
| `/System/Library/DataClassMigrators/MobileGestaltMigrator.migrator/MobileGestaltMigrator` | `needsLowering` | 69,792 | 4 | 1 | 0 | `notInCache` | `unranked` |
| `/System/Library/DataClassMigrators/MobileMailMigrator.migrator/MobileMailMigrator` | `needsLowering` | 94,176 | 94 | 5 | 0 | `notInCache` | `unranked` |
| `/System/Library/DataClassMigrators/MobileSlideShow.migrator/MobileSlideShow` | `needsLowering` | 91,040 | 35 | 4 | 0 | `notInCache` | `unranked` |
| `/System/Library/DataClassMigrators/PassbookDataMigrator.migrator/PassbookDataMigrator` | `needsLowering` | 69,104 | 2 | 1 | 0 | `notInCache` | `unranked` |
| `/System/Library/DataClassMigrators/PreferencesMigrator.migrator/PreferencesMigrator` | `needsLowering` | 90,496 | 53 | 3 | 0 | `notInCache` | `unranked` |
| `/System/Library/DataClassMigrators/RestorePostProcess.migrator/RestorePostProcess` | `needsLowering` | 224,080 | 486 | 18 | 0 | `notInCache` | `unranked` |
| `/System/Library/DataClassMigrators/Shortcuts.migrator/Shortcuts` | `needsLowering` | 69,296 | 2 | 1 | 0 | `notInCache` | `unranked` |
| `/System/Library/DataClassMigrators/Siri.migrator/Siri` | `needsLowering` | 94,400 | 68 | 5 | 0 | `notInCache` | `unranked` |
| `/System/Library/DataClassMigrators/SpringBoard.migrator/SpringBoard` | `needsLowering` | 197,616 | 952 | 16 | 0 | `notInCache` | `unranked` |
| `/System/Library/DataClassMigrators/StocksMigrator.migrator/StocksMigrator` | `needsLowering` | 69,824 | 2 | 1 | 0 | `notInCache` | `unranked` |
| `/System/Library/DataClassMigrators/SystemAppMigrator.migrator/SystemAppMigrator` | `needsLowering` | 148,128 | 194 | 9 | 0 | `notInCache` | `unranked` |
| `/System/Library/DataClassMigrators/TVMigrator.migrator/TVMigrator` | `needsLowering` | 68,512 | 2 | 1 | 0 | `notInCache` | `unranked` |
| `/System/Library/DataClassMigrators/Vibrations.migrator/Vibrations` | `needsLowering` | 68,864 | 2 | 1 | 0 | `notInCache` | `unranked` |
| `/System/Library/DataClassMigrators/WebBookmarks.migrator/WebBookmarks` | `needsLowering` | 69,376 | 2 | 1 | 0 | `notInCache` | `unranked` |
| `/System/Library/DataClassMigrators/WiFiDataMigrator.migrator/WiFiDataMigrator` | `needsLowering` | 76,624 | 50 | 3 | 0 | `notInCache` | `unranked` |
| `/System/Library/DataClassMigrators/iTunesStore.migrator/iTunesStore` | `needsLowering` | 125,808 | 72 | 9 | 0 | `notInCache` | `unranked` |

### `/System/Library/DigitalSeparation` (10)

| Image path | Plan state | Original bytes | Planned instructions | Slots | Unvisited | Cache relation | Review |
| --- | --- | ---: | ---: | ---: | ---: | --- | --- |
| `/System/Library/DigitalSeparation/SharingSources/ActivityDigitalSeparation.bundle/ActivityDigitalSeparation` | `needsLowering` | 116,208 | 262 | 8 | 0 | `notInCache` | `unranked` |
| `/System/Library/DigitalSeparation/SharingSources/CalendarSeparation.bundle/CalendarSeparation` | `needsLowering` | 90,816 | 74 | 4 | 0 | `notInCache` | `unranked` |
| `/System/Library/DigitalSeparation/SharingSources/DSNotesPlugin.bundle/DSNotesPlugin` | `needsLowering` | 187,200 | 602 | 18 | 0 | `notInCache` | `unranked` |
| `/System/Library/DigitalSeparation/SharingSources/DigitalSeparationBundle.bundle/DigitalSeparationBundle` | `needsLowering` | 106,784 | 156 | 7 | 0 | `notInCache` | `unranked` |
| `/System/Library/DigitalSeparation/SharingSources/FindMyItemsDigitalSeparation.bundle/FindMyItemsDigitalSeparation` | `needsLowering` | 165,248 | 419 | 16 | 0 | `notInCache` | `unranked` |
| `/System/Library/DigitalSeparation/SharingSources/FindMyPeopleDigitalSeparation.bundle/FindMyPeopleDigitalSeparation` | `needsLowering` | 112,208 | 245 | 7 | 0 | `notInCache` | `unranked` |
| `/System/Library/DigitalSeparation/SharingSources/HealthSharingSeparation.bundle/HealthSharingSeparation` | `needsLowering` | 72,016 | 31 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/DigitalSeparation/SharingSources/MapsDigitalSeparation.bundle/MapsDigitalSeparation` | `needsLowering` | 113,088 | 453 | 6 | 0 | `notInCache` | `unranked` |
| `/System/Library/DigitalSeparation/SharingSources/PhotosSeparation.bundle/PhotosSeparation` | `needsLowering` | 91,952 | 84 | 4 | 0 | `notInCache` | `unranked` |
| `/System/Library/DigitalSeparation/SharingSources/SafetyMonitorSeparation.bundle/SafetyMonitorSeparation` | `needsLowering` | 72,032 | 23 | 2 | 0 | `notInCache` | `unranked` |

### `/System/Library/DistributedEvaluation` (7)

| Image path | Plan state | Original bytes | Planned instructions | Slots | Unvisited | Cache relation | Review |
| --- | --- | ---: | ---: | ---: | ---: | --- | --- |
| `/System/Library/DistributedEvaluation/Plugins/DictationPersonalizationFides2Plugin.desPlugin/DictationPersonalizationFides2Plugin` | `needsLowering` | 130,992 | 90 | 10 | 0 | `notInCache` | `unranked` |
| `/System/Library/DistributedEvaluation/Plugins/GlobalNNLMFidesPlugin.desPlugin/GlobalNNLMFidesPlugin` | `needsLowering` | 71,376 | 19 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/DistributedEvaluation/Plugins/InertiaCamDES.desPlugin/InertiaCamDES` | `needsLowering` | 70,336 | 2 | 1 | 0 | `notInCache` | `unranked` |
| `/System/Library/DistributedEvaluation/Plugins/PMLDESPlugin.desPlugin/PMLDESPlugin` | `needsLowering` | 89,872 | 28 | 3 | 0 | `notInCache` | `unranked` |
| `/System/Library/DistributedEvaluation/Plugins/RemindersDES.desPlugin/RemindersDES` | `needsLowering` | 95,632 | 86 | 3 | 0 | `notInCache` | `unranked` |
| `/System/Library/DistributedEvaluation/Plugins/TypingDESPlugin.desPlugin/TypingDESPlugin` | `needsLowering` | 143,968 | 398 | 12 | 0 | `notInCache` | `unranked` |
| `/System/Library/DistributedEvaluation/Plugins/siriinference-dodml-plugin.desPlugin/siriinference-dodml-plugin` | `needsLowering` | 94,624 | 105 | 4 | 0 | `notInCache` | `unranked` |

### `/System/Library/DuetActivityScheduler` (1)

| Image path | Plan state | Original bytes | Planned instructions | Slots | Unvisited | Cache relation | Review |
| --- | --- | ---: | ---: | ---: | ---: | --- | --- |
| `/System/Library/DuetActivityScheduler/Scheduler/DuetActivitySchedulerDaemon.bundle/DuetActivitySchedulerDaemon` | `needsLowering` | 70,160 | 14 | 1 | 0 | `notInCache` | `unranked` |

### `/System/Library/Extensions` (12)

| Image path | Plan state | Original bytes | Planned instructions | Slots | Unvisited | Cache relation | Review |
| --- | --- | ---: | ---: | ---: | ---: | --- | --- |
| `/System/Library/Extensions/AppleBiometricSensor.kext/PlugIns/AppleMesaLib.plugin/AppleMesaLib` | `needsLowering` | 76,688 | 79 | 4 | 0 | `notInCache` | `unranked` |
| `/System/Library/Extensions/AppleGameControllerPersonality.kext/PlugIns/GCHIDLib.plugin/GCHIDLib` | `needsLowering` | 71,344 | 22 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/Extensions/AppleHIDALSService.kext/PlugIns/AppleHIDALS.plugin/AppleHIDALS` | `needsLowering` | 157,408 | 352 | 12 | 0 | `notInCache` | `unranked` |
| `/System/Library/Extensions/AppleHPM.kext/PlugIns/AppleHPMLib.plugin/AppleHPMLib` | `needsLowering` | 92,336 | 92 | 4 | 0 | `notInCache` | `unranked` |
| `/System/Library/Extensions/AppleSPU.kext/PlugIns/FastpathLib.plugin/FastpathLib` | `needsLowering` | 72,432 | 88 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/Extensions/AppleSPURose.kext/PlugIns/RoseControllerLib.plugin/RoseControllerLib` | `needsLowering` | 120,032 | 429 | 8 | 0 | `notInCache` | `unranked` |
| `/System/Library/Extensions/AppleUVDM.kext/PlugIns/AppleUVDMLib.plugin/AppleUVDMLib` | `needsLowering` | 72,320 | 38 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/Extensions/EAP-RSA.ppp/EAP-RSA` | `needsLowering` | 55,536 | 74 | 3 | 0 | `notInCache` | `unranked` |
| `/System/Library/Extensions/IOGameControllerFamily.kext/PlugIns/PSVR2.plugin/PSVR2` | `needsLowering` | 125,920 | 297 | 9 | 0 | `notInCache` | `unranked` |
| `/System/Library/Extensions/IOStreamFamily.kext/PlugIns/IOStreamLib.plugin/IOStreamLib` | `needsLowering` | 80,576 | 77 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/Extensions/IOUSBHostFamily.kext/PlugIns/IOUSBLib.bundle/IOUSBLib` | `needsLowering` | 139,040 | 201 | 8 | 0 | `notInCache` | `unranked` |
| `/System/Library/Extensions/VTLAdapter.kext/PlugIns/VTL.plugin/VTL` | `needsLowering` | 110,992 | 332 | 8 | 0 | `notInCache` | `unranked` |

### `/System/Library/FamilyCircle` (1)

| Image path | Plan state | Original bytes | Planned instructions | Slots | Unvisited | Cache relation | Review |
| --- | --- | ---: | ---: | ---: | ---: | --- | --- |
| `/System/Library/FamilyCircle/Bundles/FamilyCircleUIPlugin.bundle/FamilyCircleUIPlugin` | `needsLowering` | 70,976 | 14 | 1 | 0 | `notInCache` | `unranked` |

### `/System/Library/FlowTools` (26)

| Image path | Plan state | Original bytes | Planned instructions | Slots | Unvisited | Cache relation | Review |
| --- | --- | ---: | ---: | ---: | ---: | --- | --- |
| `/System/Library/FlowTools/SnippetService/ResponsePlugins/CalendarSnippetProviderPlugin.bundle/CalendarSnippetProviderPlugin` | `needsLowering` | 210,816 | 602 | 26 | 0 | `notInCache` | `unranked` |
| `/System/Library/FlowTools/SnippetService/ResponsePlugins/DeviceExpertSnippetProviderPlugin.bundle/DeviceExpertSnippetProviderPlugin` | `needsLowering` | 183,728 | 159 | 9 | 0 | `notInCache` | `unranked` |
| `/System/Library/FlowTools/SnippetService/ResponsePlugins/MessagesSnippetProviderPlugin.bundle/MessagesSnippetProviderPlugin` | `needsLowering` | 329,408 | 758 | 43 | 0 | `notInCache` | `unranked` |
| `/System/Library/FlowTools/SnippetService/ResponsePlugins/MusicSnippetProviderPlugin.bundle/MusicSnippetProviderPlugin` | `needsLowering` | 94,208 | 52 | 4 | 0 | `notInCache` | `unranked` |
| `/System/Library/FlowTools/SnippetService/ResponsePlugins/NotebookSnippetProviderPlugin.bundle/NotebookSnippetProviderPlugin` | `needsLowering` | 263,920 | 597 | 35 | 0 | `notInCache` | `unranked` |
| `/System/Library/FlowTools/SnippetService/ResponsePlugins/SiriAppLaunchSnippetProviderPlugin.bundle/SiriAppLaunchSnippetProviderPlugin` | `needsLowering` | 96,880 | 128 | 6 | 0 | `notInCache` | `unranked` |
| `/System/Library/FlowTools/SnippetService/ResponsePlugins/SiriContactsSnippetProviderPlugin.bundle/SiriContactsSnippetProviderPlugin` | `needsLowering` | 149,344 | 103 | 5 | 0 | `notInCache` | `unranked` |
| `/System/Library/FlowTools/SnippetService/ResponsePlugins/SiriGeoSnippetProviderPlugin.bundle/SiriGeoSnippetProviderPlugin` | `needsLowering` | 1,102,464 | 1,981 | 81 | 0 | `notInCache` | `unranked` |
| `/System/Library/FlowTools/SnippetService/ResponsePlugins/SiriKitSnippetProviderPlugin.bundle/SiriKitSnippetProviderPlugin` | `needsLowering` | 181,200 | 103 | 6 | 0 | `notInCache` | `unranked` |
| `/System/Library/FlowTools/SnippetService/ResponsePlugins/SiriMailSnippetProviderPlugin.bundle/SiriMailSnippetProviderPlugin` | `needsLowering` | 156,848 | 192 | 12 | 0 | `notInCache` | `unranked` |
| `/System/Library/FlowTools/SnippetService/ResponsePlugins/SiriPhoneSnippetProviderPlugin.bundle/SiriPhoneSnippetProviderPlugin` | `needsLowering` | 3,859,664 | 7,104 | 237 | 0 | `notInCache` | `unranked` |
| `/System/Library/FlowTools/SnippetService/ResponsePlugins/SiriTimeSnippetProviderPlugin.bundle/SiriTimeSnippetProviderPlugin` | `needsLowering` | 773,568 | 1,493 | 57 | 0 | `notInCache` | `unranked` |
| `/System/Library/FlowTools/SnippetService/ResponsePlugins/SiriVideoSnippetProviderPlugin.bundle/SiriVideoSnippetProviderPlugin` | `needsLowering` | 156,992 | 328 | 15 | 0 | `notInCache` | `unranked` |
| `/System/Library/FlowTools/Tools/FlowToolsInternal.flowtool/FlowToolsInternal` | `needsLowering` | 180,656 | 538 | 16 | 0 | `notInCache` | `unranked` |
| `/System/Library/FlowTools/Tools/GeoFlowTools.flowtool/GeoFlowTools` | `needsLowering` | 244,320 | 816 | 32 | 0 | `notInCache` | `unranked` |
| `/System/Library/FlowTools/Tools/GetCurrentLocationFlowToolPlugin.flowtool/GetCurrentLocationFlowToolPlugin` | `needsLowering` | 193,248 | 462 | 20 | 0 | `notInCache` | `unranked` |
| `/System/Library/FlowTools/Tools/SiriAudioFlowTools.flowtool/SiriAudioFlowTools` | `needsLowering` | 637,552 | 2,428 | 99 | 0 | `notInCache` | `unranked` |
| `/System/Library/FlowTools/Tools/SiriCrisisFlowTools.flowtool/SiriCrisisFlowTools` | `needsLowering` | 212,960 | 763 | 22 | 0 | `notInCache` | `unranked` |
| `/System/Library/FlowTools/Tools/SiriMailFlowTools.flowtool/SiriMailFlowTools` | `needsLowering` | 456,112 | 1,558 | 71 | 0 | `notInCache` | `unranked` |
| `/System/Library/FlowTools/Tools/SiriNotebookFlowTools.flowtool/SiriNotebookFlowTools` | `needsLowering` | 496,352 | 1,753 | 81 | 0 | `notInCache` | `unranked` |
| `/System/Library/FlowTools/Tools/SiriNotificationsFlowTools.flowtool/SiriNotificationsFlowTools` | `needsLowering` | 208,912 | 881 | 25 | 0 | `notInCache` | `unranked` |
| `/System/Library/FlowTools/Tools/SiriPhoneFlowTools.flowtool/SiriPhoneFlowTools` | `needsLowering` | 2,865,344 | 5,544 | 171 | 0 | `notInCache` | `unranked` |
| `/System/Library/FlowTools/Tools/SiriPhotosFlowTools.flowtool/SiriPhotosFlowTools` | `needsLowering` | 189,616 | 474 | 18 | 0 | `notInCache` | `unranked` |
| `/System/Library/FlowTools/Tools/SiriTimeFlowTools.flowtool/SiriTimeFlowTools` | `needsLowering` | 756,848 | 1,451 | 75 | 0 | `notInCache` | `unranked` |
| `/System/Library/FlowTools/Tools/SiriTranslationFlowTools.flowtool/SiriTranslationFlowTools` | `needsLowering` | 93,584 | 99 | 3 | 0 | `notInCache` | `unranked` |
| `/System/Library/FlowTools/Tools/SiriVideoFlowTools.flowtool/SiriVideoFlowTools` | `needsLowering` | 232,576 | 802 | 26 | 0 | `notInCache` | `unranked` |

### `/System/Library/Frameworks` (9)

| Image path | Plan state | Original bytes | Planned instructions | Slots | Unvisited | Cache relation | Review |
| --- | --- | ---: | ---: | ---: | ---: | --- | --- |
| `/System/Library/Frameworks/ExternalAccessory.framework/PlugIns/ExternalAccessoryWACUIBits.bundle/ExternalAccessoryWACUIBits` | `needsLowering` | 93,520 | 97 | 4 | 0 | `notInCache` | `unranked` |
| `/System/Library/Frameworks/GameController.framework/VirtualGameController.bundle/VirtualGameController` | `needsLowering` | 138,512 | 183 | 8 | 0 | `notInCache` | `unranked` |
| `/System/Library/Frameworks/LocalAuthentication.framework/Support/MechanismPlugins/MechPasscode.bundle/MechPasscode` | `needsLowering` | 194,896 | 521 | 21 | 0 | `notInCache` | `unranked` |
| `/System/Library/Frameworks/LocalAuthentication.framework/Support/MechanismPlugins/MechPearl.bundle/MechPearl` | `needsLowering` | 131,040 | 183 | 9 | 0 | `notInCache` | `unranked` |
| `/System/Library/Frameworks/LocalAuthentication.framework/Support/MechanismPlugins/MechPushButton.bundle/MechPushButton` | `needsLowering` | 89,728 | 40 | 3 | 0 | `notInCache` | `unranked` |
| `/System/Library/Frameworks/LocalAuthentication.framework/Support/MechanismPlugins/MechTouchId.bundle/MechTouchId` | `needsLowering` | 93,200 | 86 | 5 | 0 | `notInCache` | `unranked` |
| `/System/Library/Frameworks/LocalAuthentication.framework/Support/ModulePlugins/ModuleACM.bundle/ModuleACM` | `needsLowering` | 283,472 | 728 | 33 | 0 | `notInCache` | `unranked` |
| `/System/Library/Frameworks/MessageUI.framework/PlugIns/MessageUI.wkbundle/MessageUI` | `needsLowering` | 158,272 | 192 | 7 | 0 | `notInCache` | `unranked` |
| `/System/Library/Frameworks/QuickLook.framework/PlugIns/QLWebKitBundle.wkbundle/QLWebKitBundle` | `needsLowering` | 70,512 | 22 | 2 | 0 | `notInCache` | `P2` |

### `/System/Library/HIDPlugins` (38)

| Image path | Plan state | Original bytes | Planned instructions | Slots | Unvisited | Cache relation | Review |
| --- | --- | ---: | ---: | ---: | ---: | --- | --- |
| `/System/Library/HIDPlugins/ColourSensorFilterPlugin.plugin/ColourSensorFilterPlugin` | `needsLowering` | 484,848 | 1,970 | 64 | 0 | `notInCache` | `unranked` |
| `/System/Library/HIDPlugins/ServiceFilters/AppleDeviceManagementHIDFilter.plugin/AppleDeviceManagementHIDFilter` | `needsLowering` | 170,016 | 471 | 14 | 0 | `notInCache` | `unranked` |
| `/System/Library/HIDPlugins/ServiceFilters/AppleProxServiceFilter.plugin/AppleProxServiceFilter` | `needsLowering` | 151,360 | 308 | 10 | 0 | `notInCache` | `unranked` |
| `/System/Library/HIDPlugins/ServiceFilters/AppleWirelessChargingServiceFilter.plugin/AppleWirelessChargingServiceFilter` | `needsLowering` | 90,272 | 76 | 4 | 0 | `notInCache` | `unranked` |
| `/System/Library/HIDPlugins/ServiceFilters/EXBrightHIDPlugin.plugin/EXBrightHIDPlugin` | `needsLowering` | 93,824 | 95 | 3 | 0 | `notInCache` | `unranked` |
| `/System/Library/HIDPlugins/ServiceFilters/GamepadHIDServiceFilter.plugin/GamepadHIDServiceFilter` | `needsLowering` | 90,864 | 81 | 4 | 0 | `notInCache` | `unranked` |
| `/System/Library/HIDPlugins/ServiceFilters/HIDRMServiceFilter.plugin/HIDRMServiceFilter` | `needsLowering` | 116,496 | 163 | 6 | 0 | `notInCache` | `unranked` |
| `/System/Library/HIDPlugins/ServiceFilters/HIDSensorControlFilter.plugin/HIDSensorControlFilter` | `needsLowering` | 113,936 | 256 | 7 | 0 | `notInCache` | `unranked` |
| `/System/Library/HIDPlugins/ServiceFilters/HIDSensorTimeFilter.plugin/HIDSensorTimeFilter` | `needsLowering` | 114,144 | 226 | 6 | 0 | `notInCache` | `unranked` |
| `/System/Library/HIDPlugins/ServiceFilters/IOHIDSensorPowerLoggingFilter.plugin/IOHIDSensorPowerLoggingFilter` | `needsLowering` | 72,064 | 28 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/HIDPlugins/ServiceFilters/P192HIDServiceFilter.plugin/P192HIDServiceFilter` | `needsLowering` | 74,624 | 80 | 3 | 0 | `notInCache` | `unranked` |
| `/System/Library/HIDPlugins/ServiceFilters/SafetyServiceFilter.plugin/SafetyServiceFilter` | `needsLowering` | 71,648 | 28 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/HIDPlugins/ServiceFilters/SpatialHIDServiceFilter.plugin/SpatialHIDServiceFilter` | `needsLowering` | 90,912 | 105 | 4 | 0 | `notInCache` | `unranked` |
| `/System/Library/HIDPlugins/ServiceFilters/TactSwitchHIDServiceFilter.plugin/TactSwitchHIDServiceFilter` | `needsLowering` | 104,048 | 98 | 4 | 0 | `notInCache` | `unranked` |
| `/System/Library/HIDPlugins/ServicePlugins/DualSenseHIDServicePlugin.plugin/DualSenseHIDServicePlugin` | `needsLowering` | 123,856 | 211 | 9 | 0 | `notInCache` | `unranked` |
| `/System/Library/HIDPlugins/ServicePlugins/DualShock4HIDServicePlugin.plugin/DualShock4HIDServicePlugin` | `needsLowering` | 89,664 | 115 | 5 | 0 | `notInCache` | `unranked` |
| `/System/Library/HIDPlugins/ServicePlugins/GenericGamepadHIDServicePlugin.plugin/GenericGamepadHIDServicePlugin` | `needsLowering` | 127,152 | 122 | 10 | 0 | `notInCache` | `unranked` |
| `/System/Library/HIDPlugins/ServicePlugins/HSTouchHIDService.plugin/HSTouchHIDService` | `needsLowering` | 2,402,192 | 8,894 | 205 | 0 | `notInCache` | `unranked` |
| `/System/Library/HIDPlugins/ServicePlugins/IOHIDEventServicePlugin.plugin/IOHIDEventServicePlugin` | `needsLowering` | 74,192 | 67 | 3 | 0 | `notInCache` | `unranked` |
| `/System/Library/HIDPlugins/ServicePlugins/JoyConHIDServicePlugin.plugin/JoyConHIDServicePlugin` | `needsLowering` | 158,480 | 420 | 17 | 0 | `notInCache` | `unranked` |
| `/System/Library/HIDPlugins/ServicePlugins/LunaHIDServicePlugin.plugin/LunaHIDServicePlugin` | `needsLowering` | 70,464 | 12 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/HIDPlugins/ServicePlugins/PSAccessControllerHIDServicePlugin.plugin/PSAccessControllerHIDServicePlugin` | `needsLowering` | 89,760 | 97 | 6 | 0 | `notInCache` | `unranked` |
| `/System/Library/HIDPlugins/ServicePlugins/PSVR2HIDServicePlugin.plugin/PSVR2HIDServicePlugin` | `needsLowering` | 111,664 | 118 | 6 | 0 | `notInCache` | `unranked` |
| `/System/Library/HIDPlugins/ServicePlugins/TouchSensitiveButtonHIDService.plugin/TouchSensitiveButtonHIDService` | `needsLowering` | 106,256 | 118 | 4 | 0 | `notInCache` | `unranked` |
| `/System/Library/HIDPlugins/ServicePlugins/XboxGamepadHIDServicePlugin.plugin/XboxGamepadHIDServicePlugin` | `needsLowering` | 89,600 | 83 | 4 | 0 | `notInCache` | `unranked` |
| `/System/Library/HIDPlugins/ServicePlugins/XboxOneHIDServicePlugin.plugin/XboxOneHIDServicePlugin` | `needsLowering` | 71,616 | 25 | 3 | 0 | `notInCache` | `unranked` |
| `/System/Library/HIDPlugins/SessionFilters/AppleMagicKeyboardSessionFilter.plugin/AppleMagicKeyboardSessionFilter` | `needsLowering` | 108,560 | 149 | 6 | 0 | `notInCache` | `unranked` |
| `/System/Library/HIDPlugins/SessionFilters/CoreRCPlugin.plugin/CoreRCPlugin` | `needsLowering` | 92,992 | 104 | 5 | 0 | `notInCache` | `unranked` |
| `/System/Library/HIDPlugins/SessionFilters/FTRemoteEventHIDSessionFilter.plugin/FTRemoteEventHIDSessionFilter` | `needsLowering` | 92,768 | 137 | 5 | 0 | `notInCache` | `unranked` |
| `/System/Library/HIDPlugins/SessionFilters/HIDRMSessionFilter.plugin/HIDRMSessionFilter` | `needsLowering` | 73,888 | 58 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/HIDPlugins/SessionFilters/IOAnalytics.plugin/IOAnalytics` | `needsLowering` | 343,584 | 566 | 22 | 0 | `notInCache` | `unranked` |
| `/System/Library/HIDPlugins/SessionFilters/IOHIDDisplaySessionFilter.plugin/IOHIDDisplaySessionFilter` | `needsLowering` | 71,648 | 30 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/HIDPlugins/SessionFilters/IOHIDMotionEventSessionFilter.plugin/IOHIDMotionEventSessionFilter` | `needsLowering` | 70,544 | 15 | 1 | 0 | `notInCache` | `unranked` |
| `/System/Library/HIDPlugins/SessionFilters/IOHIDRemoteSensorSessionFilter.plugin/IOHIDRemoteSensorSessionFilter` | `needsLowering` | 69,856 | 12 | 1 | 0 | `notInCache` | `unranked` |
| `/System/Library/HIDPlugins/SessionFilters/IOHIDTelemetrySessionFilter.plugin/IOHIDTelemetrySessionFilter` | `needsLowering` | 72,928 | 28 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/HIDPlugins/SessionFilters/IOHIDXPCEventSessionFilter.plugin/IOHIDXPCEventSessionFilter` | `needsLowering` | 94,816 | 115 | 4 | 0 | `notInCache` | `unranked` |
| `/System/Library/HIDPlugins/SessionFilters/MultitouchSessionFilter.plugin/MultitouchSessionFilter` | `needsLowering` | 195,968 | 579 | 16 | 0 | `notInCache` | `unranked` |
| `/System/Library/HIDPlugins/SessionFilters/TactSwitchHIDSessionFilter.plugin/TactSwitchHIDSessionFilter` | `needsLowering` | 74,128 | 16 | 2 | 0 | `notInCache` | `unranked` |

### `/System/Library/Health` (19)

| Image path | Plan state | Original bytes | Planned instructions | Slots | Unvisited | Cache relation | Review |
| --- | --- | ---: | ---: | ---: | ---: | --- | --- |
| `/System/Library/Health/DiagnosticExtensionPlugins/HealthAppDiagnosticExtensionPlugin.bundle/HealthAppDiagnosticExtensionPlugin` | `needsLowering` | 72,384 | 30 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/Health/DiagnosticExtensionPlugins/HealthFeaturesDiagnosticExtensionPlugin.bundle/HealthFeaturesDiagnosticExtensionPlugin` | `needsLowering` | 75,200 | 40 | 3 | 0 | `notInCache` | `unranked` |
| `/System/Library/Health/DiagnosticExtensionPlugins/HealthMedicationsDiagnosticExtensionPlugin.bundle/HealthMedicationsDiagnosticExtensionPlugin` | `needsLowering` | 73,328 | 52 | 3 | 0 | `notInCache` | `unranked` |
| `/System/Library/Health/DiagnosticExtensionPlugins/HealthServicesPlatformDiagnosticExtensionPlugin.bundle/HealthServicesPlatformDiagnosticExtensionPlugin` | `needsLowering` | 92,576 | 78 | 4 | 0 | `notInCache` | `unranked` |
| `/System/Library/Health/DiagnosticExtensionPlugins/HealthTopicsDiagnosticExtensionPlugin.bundle/HealthTopicsDiagnosticExtensionPlugin` | `needsLowering` | 74,832 | 83 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/Health/FeedItemPlugins/HealthBalanceAppPluginBundle.healthplugin/HealthBalanceAppPluginBundle` | `needsLowering` | 94,832 | 125 | 3 | 0 | `notInCache` | `unranked` |
| `/System/Library/Health/FeedItemPlugins/MedicationsHealthAppPluginBundle.healthplugin/MedicationsHealthAppPluginBundle` | `needsLowering` | 93,856 | 131 | 3 | 0 | `notInCache` | `unranked` |
| `/System/Library/Health/Plugins/FitnessIntelligencePlugin.bundle/FitnessIntelligencePlugin` | `needsLowering` | 764,368 | 2,907 | 124 | 0 | `notInCache` | `unranked` |
| `/System/Library/Health/Plugins/HealthActivityCache.bundle/HealthActivityCache` | `needsLowering` | 313,216 | 1,021 | 34 | 0 | `notInCache` | `unranked` |
| `/System/Library/Health/Plugins/HealthBalanceDaemonPlugin.bundle/HealthBalanceDaemonPlugin` | `needsLowering` | 69,904 | 13 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/Health/Plugins/HealthBluetoothPeripheral.bundle/HealthBluetoothPeripheral` | `needsLowering` | 569,344 | 2,004 | 62 | 0 | `notInCache` | `unranked` |
| `/System/Library/Health/Plugins/HealthDaemonControlsPlugin.bundle/HealthDaemonControlsPlugin` | `needsLowering` | 73,312 | 58 | 1 | 0 | `notInCache` | `unranked` |
| `/System/Library/Health/Plugins/HealthDaemonFeaturesPlugin.bundle/HealthDaemonFeaturesPlugin` | `needsLowering` | 69,456 | 9 | 1 | 0 | `notInCache` | `unranked` |
| `/System/Library/Health/Plugins/HealthOntologyDaemonPluginBundle.bundle/HealthOntologyDaemonPluginBundle` | `needsLowering` | 69,952 | 13 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/Health/Plugins/HealthRecordsPluginBundle.bundle/HealthRecordsPluginBundle` | `needsLowering` | 72,656 | 18 | 1 | 0 | `notInCache` | `unranked` |
| `/System/Library/Health/Plugins/HealthTopicsDaemonPluginBundle.bundle/HealthTopicsDaemonPluginBundle` | `needsLowering` | 69,472 | 9 | 1 | 0 | `notInCache` | `unranked` |
| `/System/Library/Health/Plugins/HealthWorkoutPlugin.bundle/HealthWorkoutPlugin` | `needsLowering` | 110,752 | 200 | 7 | 0 | `notInCache` | `unranked` |
| `/System/Library/Health/Plugins/MedicalIDDaemonPlugin.bundle/MedicalIDDaemonPlugin` | `needsLowering` | 69,856 | 13 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/Health/Plugins/WorkoutHealthPlugin.bundle/WorkoutHealthPlugin` | `needsLowering` | 257,872 | 316 | 20 | 0 | `notInCache` | `unranked` |

### `/System/Library/KerberosPlugins` (3)

| Image path | Plan state | Original bytes | Planned instructions | Slots | Unvisited | Cache relation | Review |
| --- | --- | ---: | ---: | ---: | ---: | --- | --- |
| `/System/Library/KerberosPlugins/GSSAPI/AppSSOReplacePlugin_iOS.bundle/AppSSOReplacePlugin_iOS` | `needsLowering` | 70,928 | 28 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/KerberosPlugins/KerberosFrameworkPlugins/AppSSOConfigPlugin_iOS.bundle/AppSSOConfigPlugin_iOS` | `needsLowering` | 70,688 | 34 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/KerberosPlugins/KerberosFrameworkPlugins/AppSSOLocatePlugin_iOS.bundle/AppSSOLocatePlugin_iOS` | `needsLowering` | 70,880 | 30 | 2 | 0 | `notInCache` | `unranked` |

### `/System/Library/MediaStreamPlugins` (1)

| Image path | Plan state | Original bytes | Planned instructions | Slots | Unvisited | Cache relation | Review |
| --- | --- | ---: | ---: | ---: | ---: | --- | --- |
| `/System/Library/MediaStreamPlugins/PhotoSharingPlugin.mediastream/PhotoSharingPlugin` | `needsLowering` | 106,752 | 96 | 5 | 0 | `notInCache` | `unranked` |

### `/System/Library/Messages` (23)

| Image path | Plan state | Original bytes | Planned instructions | Slots | Unvisited | Cache relation | Review |
| --- | --- | ---: | ---: | ---: | ---: | --- | --- |
| `/System/Library/Messages/PlugIns/RCS.imservice/RCS` | `needsLowering` | 1,580,944 | 6,762 | 264 | 0 | `notInCache` | `unranked` |
| `/System/Library/Messages/PlugIns/SMS.imservice/SMS` | `needsLowering` | 225,728 | 332 | 18 | 0 | `notInCache` | `unranked` |
| `/System/Library/Messages/PlugIns/SatelliteSMS.imservice/SatelliteSMS` | `needsLowering` | 175,808 | 333 | 15 | 0 | `notInCache` | `unranked` |
| `/System/Library/Messages/PlugIns/iMessage.imservice/iMessage` | `needsLowering` | 1,760,032 | 4,124 | 259 | 0 | `notInCache` | `unranked` |
| `/System/Library/Messages/PlugIns/iMessageLite.imservice/iMessageLite` | `needsLowering` | 1,014,288 | 2,073 | 80 | 0 | `notInCache` | `unranked` |
| `/System/Library/Messages/iMessageApps/AskToMessages.bundle/AskToMessages` | `needsLowering` | 217,152 | 520 | 24 | 0 | `notInCache` | `unranked` |
| `/System/Library/Messages/iMessageApps/FindMyMessagesApp.bundle/FindMyMessagesApp` | `needsLowering` | 153,568 | 338 | 15 | 0 | `notInCache` | `unranked` |
| `/System/Library/Messages/iMessageApps/MessagesPolls.bundle/MessagesPolls` | `needsLowering` | 513,168 | 2,243 | 69 | 0 | `notInCache` | `unranked` |
| `/System/Library/Messages/iMessageApps/SafetyMonitorMessages.bundle/SafetyMonitorMessages` | `needsLowering` | 212,576 | 386 | 23 | 0 | `notInCache` | `unranked` |
| `/System/Library/Messages/iMessageBalloons/ASMessagesProvider.bundle/ASMessagesProvider` | `needsLowering` | 10,806,352 | 47,432 | 1,817 | 0 | `notInCache` | `unranked` |
| `/System/Library/Messages/iMessageBalloons/DigitalTouchBalloonProvider.bundle/DigitalTouchBalloonProvider` | `needsLowering` | 241,488 | 669 | 20 | 0 | `notInCache` | `unranked` |
| `/System/Library/Messages/iMessageBalloons/HandwritingProvider.bundle/HandwritingProvider` | `needsLowering` | 254,592 | 574 | 19 | 0 | `notInCache` | `unranked` |
| `/System/Library/Messages/iMessageBalloons/MSMessageExtensionBalloonPlugin.bundle/MSMessageExtensionBalloonPlugin` | `needsLowering` | 427,984 | 1,423 | 42 | 0 | `notInCache` | `unranked` |
| `/System/Library/Messages/iMessageBalloons/SendLaterProvider.bundle/SendLaterProvider` | `needsLowering` | 131,376 | 187 | 7 | 0 | `notInCache` | `unranked` |
| `/System/Library/Messages/iMessageEffects/CKConfettiEffect.bundle/CKConfettiEffect` | `needsLowering` | 72,016 | 12 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/Messages/iMessageEffects/CKEchoEffect.bundle/CKEchoEffect` | `needsLowering` | 89,872 | 20 | 3 | 0 | `notInCache` | `unranked` |
| `/System/Library/Messages/iMessageEffects/CKFireworksEffect.bundle/CKFireworksEffect` | `needsLowering` | 107,728 | 68 | 6 | 0 | `notInCache` | `unranked` |
| `/System/Library/Messages/iMessageEffects/CKHappyBirthdayEffect.bundle/CKHappyBirthdayEffect` | `needsLowering` | 89,872 | 33 | 3 | 0 | `notInCache` | `unranked` |
| `/System/Library/Messages/iMessageEffects/CKHeartEffect.bundle/CKHeartEffect` | `needsLowering` | 90,016 | 35 | 3 | 0 | `notInCache` | `unranked` |
| `/System/Library/Messages/iMessageEffects/CKLasersEffect.bundle/CKLasersEffect` | `needsLowering` | 72,624 | 16 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/Messages/iMessageEffects/CKShootingStarEffect.bundle/CKShootingStarEffect` | `needsLowering` | 89,712 | 14 | 3 | 0 | `notInCache` | `unranked` |
| `/System/Library/Messages/iMessageEffects/CKSparklesEffect.bundle/CKSparklesEffect` | `needsLowering` | 89,472 | 14 | 3 | 0 | `notInCache` | `unranked` |
| `/System/Library/Messages/iMessageEffects/CKSpotlightEffect.bundle/CKSpotlightEffect` | `needsLowering` | 89,840 | 22 | 3 | 0 | `notInCache` | `unranked` |

### `/System/Library/NanoPreferenceBundles` (80)

| Image path | Plan state | Original bytes | Planned instructions | Slots | Unvisited | Cache relation | Review |
| --- | --- | ---: | ---: | ---: | ---: | --- | --- |
| `/System/Library/NanoPreferenceBundles/Applications/BridgeAppStoreDaemonSettings.bundle/BridgeAppStoreDaemonSettings` | `needsLowering` | 214,864 | 663 | 21 | 0 | `notInCache` | `unranked` |
| `/System/Library/NanoPreferenceBundles/Applications/BridgeHealthSettings.bundle/BridgeHealthSettings` | `needsLowering` | 166,784 | 383 | 12 | 0 | `notInCache` | `unranked` |
| `/System/Library/NanoPreferenceBundles/Applications/BridgeRemoteAccounts.bundle/BridgeRemoteAccounts` | `needsLowering` | 163,824 | 431 | 16 | 0 | `notInCache` | `unranked` |
| `/System/Library/NanoPreferenceBundles/Applications/BrookBridgeSettings.bundle/BrookBridgeSettings` | `needsLowering` | 90,304 | 48 | 3 | 0 | `notInCache` | `unranked` |
| `/System/Library/NanoPreferenceBundles/Applications/DeepBreathingSettings.bundle/DeepBreathingSettings` | `needsLowering` | 91,504 | 90 | 4 | 0 | `notInCache` | `unranked` |
| `/System/Library/NanoPreferenceBundles/Applications/DepthCompanionSettings.bundle/DepthCompanionSettings` | `needsLowering` | 138,224 | 227 | 9 | 0 | `notInCache` | `unranked` |
| `/System/Library/NanoPreferenceBundles/Applications/DoseSettings.bundle/DoseSettings` | `needsLowering` | 110,560 | 101 | 5 | 0 | `notInCache` | `unranked` |
| `/System/Library/NanoPreferenceBundles/Applications/FindMyNotificationsSettings.bundle/FindMyNotificationsSettings` | `needsLowering` | 70,992 | 14 | 1 | 0 | `notInCache` | `unranked` |
| `/System/Library/NanoPreferenceBundles/Applications/HealthAppsSettings.bundle/HealthAppsSettings` | `needsLowering` | 96,160 | 91 | 5 | 0 | `notInCache` | `unranked` |
| `/System/Library/NanoPreferenceBundles/Applications/HeartRateSettings.bundle/HeartRateSettings` | `needsLowering` | 196,032 | 483 | 14 | 0 | `notInCache` | `unranked` |
| `/System/Library/NanoPreferenceBundles/Applications/MessagesBridgeSettings.bundle/MessagesBridgeSettings` | `needsLowering` | 73,680 | 46 | 3 | 0 | `notInCache` | `unranked` |
| `/System/Library/NanoPreferenceBundles/Applications/MindSettings.bundle/MindSettings` | `needsLowering` | 196,896 | 569 | 17 | 0 | `notInCache` | `unranked` |
| `/System/Library/NanoPreferenceBundles/Applications/NanoBedtimeBridgeSettings.bundle/NanoBedtimeBridgeSettings` | `needsLowering` | 199,344 | 681 | 21 | 0 | `notInCache` | `unranked` |
| `/System/Library/NanoPreferenceBundles/Applications/NanoBooksBridgeSettings.bundle/NanoBooksBridgeSettings` | `needsLowering` | 210,896 | 621 | 18 | 0 | `notInCache` | `unranked` |
| `/System/Library/NanoPreferenceBundles/Applications/NanoCalendarBridgeSettings.bundle/NanoCalendarBridgeSettings` | `needsLowering` | 132,160 | 272 | 7 | 0 | `notInCache` | `unranked` |
| `/System/Library/NanoPreferenceBundles/Applications/NanoClockBridgeSettings.bundle/NanoClockBridgeSettings` | `needsLowering` | 113,088 | 185 | 6 | 0 | `notInCache` | `unranked` |
| `/System/Library/NanoPreferenceBundles/Applications/NanoContactsBridgeSettingsOther.bundle/NanoContactsBridgeSettingsOther` | `needsLowering` | 130,736 | 188 | 7 | 0 | `notInCache` | `unranked` |
| `/System/Library/NanoPreferenceBundles/Applications/NanoContactsBridgeSettingsPaired.bundle/NanoContactsBridgeSettingsPaired` | `needsLowering` | 92,352 | 71 | 4 | 0 | `notInCache` | `unranked` |
| `/System/Library/NanoPreferenceBundles/Applications/NanoHealthBalanceBridgeSettings.bundle/NanoHealthBalanceBridgeSettings` | `needsLowering` | 97,328 | 116 | 4 | 0 | `notInCache` | `unranked` |
| `/System/Library/NanoPreferenceBundles/Applications/NanoMailBridgeSettings.bundle/NanoMailBridgeSettings` | `needsLowering` | 318,672 | 890 | 30 | 0 | `notInCache` | `unranked` |
| `/System/Library/NanoPreferenceBundles/Applications/NanoMapsBridgeSettings.bundle/NanoMapsBridgeSettings` | `needsLowering` | 97,840 | 430 | 5 | 0 | `notInCache` | `unranked` |
| `/System/Library/NanoPreferenceBundles/Applications/NanoMenstrualCyclesCompanionSettings.bundle/NanoMenstrualCyclesCompanionSettings` | `needsLowering` | 120,864 | 220 | 8 | 0 | `notInCache` | `unranked` |
| `/System/Library/NanoPreferenceBundles/Applications/NanoMusicBridgeSettings.bundle/NanoMusicBridgeSettings` | `needsLowering` | 167,776 | 282 | 11 | 0 | `notInCache` | `unranked` |
| `/System/Library/NanoPreferenceBundles/Applications/NanoPassbookBridgeSettings.bundle/NanoPassbookBridgeSettings` | `needsLowering` | 271,776 | 677 | 21 | 0 | `notInCache` | `unranked` |
| `/System/Library/NanoPreferenceBundles/Applications/NanoPhotosBridgeSettings.bundle/NanoPhotosBridgeSettings` | `needsLowering` | 111,984 | 183 | 5 | 0 | `notInCache` | `unranked` |
| `/System/Library/NanoPreferenceBundles/Applications/NanoTipsBridgeSettings.bundle/NanoTipsBridgeSettings` | `needsLowering` | 70,224 | 4 | 1 | 0 | `notInCache` | `unranked` |
| `/System/Library/NanoPreferenceBundles/Applications/OxygenSaturationSettings.bundle/OxygenSaturationSettings` | `needsLowering` | 98,528 | 143 | 5 | 0 | `notInCache` | `unranked` |
| `/System/Library/NanoPreferenceBundles/Applications/PhoneBridgeSettings.bundle/PhoneBridgeSettings` | `needsLowering` | 93,440 | 119 | 3 | 0 | `notInCache` | `unranked` |
| `/System/Library/NanoPreferenceBundles/Applications/PodcastsBridgeSettings.bundle/PodcastsBridgeSettings` | `needsLowering` | 208,864 | 504 | 17 | 0 | `notInCache` | `unranked` |
| `/System/Library/NanoPreferenceBundles/Applications/SessionTrackerAppSettings.bundle/SessionTrackerAppSettings` | `needsLowering` | 370,128 | 1,285 | 34 | 0 | `notInCache` | `unranked` |
| `/System/Library/NanoPreferenceBundles/Applications/StocksBridgeSettings.bundle/StocksBridgeSettings` | `needsLowering` | 112,240 | 175 | 5 | 0 | `notInCache` | `unranked` |
| `/System/Library/NanoPreferenceBundles/Applications/TinCanSettings.bundle/TinCanSettings` | `needsLowering` | 90,112 | 44 | 3 | 0 | `notInCache` | `unranked` |
| `/System/Library/NanoPreferenceBundles/Applications/UrchinBridgeSettings.bundle/UrchinBridgeSettings` | `needsLowering` | 114,896 | 211 | 5 | 0 | `notInCache` | `unranked` |
| `/System/Library/NanoPreferenceBundles/Applications/WeatherExtensionBridgeSettings.bundle/WeatherExtensionBridgeSettings` | `needsLowering` | 93,152 | 78 | 3 | 0 | `notInCache` | `unranked` |
| `/System/Library/NanoPreferenceBundles/Customization/CarouselAppViewSettings.bundle/CarouselAppViewSettings` | `needsLowering` | 327,520 | 1,074 | 34 | 0 | `notInCache` | `unranked` |
| `/System/Library/NanoPreferenceBundles/Customization/CarouselLayoutSettings.bundle/CarouselLayoutSettings` | `needsLowering` | 308,896 | 1,032 | 33 | 0 | `notInCache` | `unranked` |
| `/System/Library/NanoPreferenceBundles/Customization/NTKCustomization.bundle/NTKCustomization` | `needsLowering` | 212,816 | 486 | 16 | 0 | `notInCache` | `unranked` |
| `/System/Library/NanoPreferenceBundles/Discover/AppsForYourWatchPlugin.bundle/AppsForYourWatchPlugin` | `needsLowering` | 69,536 | 8 | 1 | 0 | `notInCache` | `unranked` |
| `/System/Library/NanoPreferenceBundles/Discover/CustomizeYourWatchPlugin.bundle/CustomizeYourWatchPlugin` | `needsLowering` | 69,488 | 8 | 1 | 0 | `notInCache` | `unranked` |
| `/System/Library/NanoPreferenceBundles/Discover/GetToKnowCurrentSeriesPlugin.bundle/GetToKnowCurrentSeriesPlugin` | `needsLowering` | 69,712 | 10 | 1 | 0 | `notInCache` | `unranked` |
| `/System/Library/NanoPreferenceBundles/Discover/HealthAndFitnessPlugin.bundle/HealthAndFitnessPlugin` | `needsLowering` | 69,552 | 10 | 1 | 0 | `notInCache` | `unranked` |
| `/System/Library/NanoPreferenceBundles/Discover/UserGuidePlugin.bundle/UserGuidePlugin` | `needsLowering` | 69,408 | 8 | 1 | 0 | `notInCache` | `unranked` |
| `/System/Library/NanoPreferenceBundles/Discover/WelcomeToAppleWatchPlugin.bundle/WelcomeToAppleWatchPlugin` | `needsLowering` | 69,568 | 10 | 1 | 0 | `notInCache` | `unranked` |
| `/System/Library/NanoPreferenceBundles/Discover/WhatsNewPlugin.bundle/WhatsNewPlugin` | `needsLowering` | 69,664 | 10 | 1 | 0 | `notInCache` | `unranked` |
| `/System/Library/NanoPreferenceBundles/General/AssistantBridgeSettings.bundle/AssistantBridgeSettings` | `needsLowering` | 130,208 | 293 | 8 | 0 | `notInCache` | `unranked` |
| `/System/Library/NanoPreferenceBundles/General/CSLCompanionLiveActivitiesSettings.bundle/CSLCompanionLiveActivitiesSettings` | `needsLowering` | 213,280 | 824 | 21 | 0 | `notInCache` | `unranked` |
| `/System/Library/NanoPreferenceBundles/General/CellularBridgeSettings.bundle/CellularBridgeSettings` | `needsLowering` | 170,480 | 442 | 13 | 0 | `notInCache` | `unranked` |
| `/System/Library/NanoPreferenceBundles/General/CompanionAppBacklightPrivacySettings.bundle/CompanionAppBacklightPrivacySettings` | `needsLowering` | 89,712 | 34 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/NanoPreferenceBundles/General/CompanionAutoLaunchSettings.bundle/CompanionAutoLaunchSettings` | `needsLowering` | 329,440 | 1,617 | 37 | 0 | `notInCache` | `unranked` |
| `/System/Library/NanoPreferenceBundles/General/CompanionBARSettings.bundle/CompanionBARSettings` | `needsLowering` | 73,264 | 28 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/NanoPreferenceBundles/General/CompanionComplicationSettings.bundle/CompanionComplicationSettings` | `needsLowering` | 72,144 | 44 | 3 | 0 | `notInCache` | `unranked` |
| `/System/Library/NanoPreferenceBundles/General/CompanionDockSettings.bundle/CompanionDockSettings` | `needsLowering` | 89,808 | 74 | 3 | 0 | `notInCache` | `unranked` |
| `/System/Library/NanoPreferenceBundles/General/CompanionInternationalSettings.bundle/CompanionInternationalSettings` | `needsLowering` | 265,776 | 792 | 25 | 0 | `notInCache` | `unranked` |
| `/System/Library/NanoPreferenceBundles/General/CompanionNotificationSettings.bundle/CompanionNotificationSettings` | `needsLowering` | 141,952 | 272 | 10 | 0 | `notInCache` | `unranked` |
| `/System/Library/NanoPreferenceBundles/General/CompanionReturnToClockSettings.bundle/CompanionReturnToClockSettings` | `needsLowering` | 108,944 | 177 | 5 | 0 | `notInCache` | `unranked` |
| `/System/Library/NanoPreferenceBundles/General/CompanionStingSettings.bundle/CompanionStingSettings` | `needsLowering` | 111,056 | 195 | 8 | 0 | `notInCache` | `unranked` |
| `/System/Library/NanoPreferenceBundles/General/CompanionWakeSettings.bundle/CompanionWakeSettings` | `needsLowering` | 91,392 | 102 | 3 | 0 | `notInCache` | `unranked` |
| `/System/Library/NanoPreferenceBundles/General/NTKCTritiumSettings.bundle/NTKCTritiumSettings` | `needsLowering` | 92,464 | 74 | 3 | 0 | `notInCache` | `unranked` |
| `/System/Library/NanoPreferenceBundles/General/NanoControlCenterBridgeSettings.bundle/NanoControlCenterBridgeSettings` | `needsLowering` | 175,872 | 426 | 16 | 0 | `notInCache` | `unranked` |
| `/System/Library/NanoPreferenceBundles/General/PairedUnlockSettings.bundle/PairedUnlockSettings` | `needsLowering` | 128,800 | 194 | 7 | 0 | `notInCache` | `unranked` |
| `/System/Library/NanoPreferenceBundles/General/SmartStackSettingsPhone.bundle/SmartStackSettingsPhone` | `needsLowering` | 115,008 | 227 | 7 | 0 | `notInCache` | `unranked` |
| `/System/Library/NanoPreferenceBundles/General/WGAEltonUsersSettingsPhone.bundle/WGAEltonUsersSettingsPhone` | `needsLowering` | 94,272 | 126 | 6 | 0 | `notInCache` | `unranked` |
| `/System/Library/NanoPreferenceBundles/PrivacySettings/HealthBridgePrivacySettings.bundle/HealthBridgePrivacySettings` | `needsLowering` | 111,680 | 121 | 4 | 0 | `notInCache` | `unranked` |
| `/System/Library/NanoPreferenceBundles/SetupBundles/AccessibilityBridgeSetup.bundle/AccessibilityBridgeSetup` | `needsLowering` | 105,456 | 84 | 3 | 0 | `notInCache` | `unranked` |
| `/System/Library/NanoPreferenceBundles/SetupBundles/ActivityBridgeSetup.bundle/ActivityBridgeSetup` | `needsLowering` | 654,592 | 2,449 | 83 | 0 | `notInCache` | `unranked` |
| `/System/Library/NanoPreferenceBundles/SetupBundles/BPSStingSetup.bundle/BPSStingSetup` | `needsLowering` | 110,768 | 110 | 5 | 0 | `notInCache` | `unranked` |
| `/System/Library/NanoPreferenceBundles/SetupBundles/CellularSetupBridgeBuddyUI.bundle/CellularSetupBridgeBuddyUI` | `needsLowering` | 69,232 | 4 | 1 | 0 | `notInCache` | `unranked` |
| `/System/Library/NanoPreferenceBundles/SetupBundles/CompanionAppViewSetup.bundle/CompanionAppViewSetup` | `needsLowering` | 72,848 | 55 | 3 | 0 | `notInCache` | `unranked` |
| `/System/Library/NanoPreferenceBundles/SetupBundles/DepthCompanionSetup.bundle/DepthCompanionSetup` | `needsLowering` | 90,960 | 72 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/NanoPreferenceBundles/SetupBundles/HealthBridgeSetupPlugin.bundle/HealthBridgeSetupPlugin` | `needsLowering` | 110,480 | 155 | 5 | 0 | `notInCache` | `unranked` |
| `/System/Library/NanoPreferenceBundles/SetupBundles/HealthFeaturesBridgeSetupPlugin.bundle/HealthFeaturesBridgeSetupPlugin` | `needsLowering` | 136,960 | 278 | 10 | 0 | `notInCache` | `unranked` |
| `/System/Library/NanoPreferenceBundles/SetupBundles/HeartRateBridgePlugin.bundle/HeartRateBridgePlugin` | `needsLowering` | 72,064 | 22 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/NanoPreferenceBundles/SetupBundles/MessagesPairingRegistration.bundle/MessagesPairingRegistration` | `needsLowering` | 73,136 | 38 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/NanoPreferenceBundles/SetupBundles/NanoContactsBridgeSetup.bundle/NanoContactsBridgeSetup` | `needsLowering` | 188,192 | 546 | 15 | 0 | `notInCache` | `unranked` |
| `/System/Library/NanoPreferenceBundles/SetupBundles/NanoSleepBridgeSetup.bundle/NanoSleepBridgeSetup` | `needsLowering` | 94,816 | 85 | 4 | 0 | `notInCache` | `unranked` |
| `/System/Library/NanoPreferenceBundles/SetupBundles/SchoolTimeSetup.bundle/SchoolTimeSetup` | `needsLowering` | 92,032 | 99 | 3 | 0 | `notInCache` | `unranked` |
| `/System/Library/NanoPreferenceBundles/SetupBundles/SiriSetupBridgeBundle.bundle/SiriSetupBridgeBundle` | `needsLowering` | 136,416 | 318 | 10 | 0 | `notInCache` | `unranked` |
| `/System/Library/NanoPreferenceBundles/SetupBundles/SiriWatchPairingSetup.bundle/SiriWatchPairingSetup` | `needsLowering` | 91,504 | 150 | 5 | 0 | `notInCache` | `unranked` |
| `/System/Library/NanoPreferenceBundles/SetupBundles/TextSettingsBridgeSetup.bundle/TextSettingsBridgeSetup` | `needsLowering` | 134,128 | 133 | 5 | 0 | `notInCache` | `unranked` |
| `/System/Library/NanoPreferenceBundles/SetupBundles/WGAEltonPhoneBuddyFlowPanel.bundle/WGAEltonPhoneBuddyFlowPanel` | `needsLowering` | 109,536 | 137 | 7 | 0 | `notInCache` | `unranked` |

### `/System/Library/NanoTimeKit` (20)

| Image path | Plan state | Original bytes | Planned instructions | Slots | Unvisited | Cache relation | Review |
| --- | --- | ---: | ---: | ---: | ---: | --- | --- |
| `/System/Library/NanoTimeKit/ComplicationBundles/ActivityComplicationBundleCompanion.bundle/ActivityComplicationBundleCompanion` | `needsLowering` | 134,752 | 173 | 10 | 0 | `notInCache` | `unranked` |
| `/System/Library/NanoTimeKit/ComplicationBundles/DepthComplicationBundleCompanion.bundle/DepthComplicationBundleCompanion` | `needsLowering` | 372,768 | 1,098 | 48 | 0 | `notInCache` | `unranked` |
| `/System/Library/NanoTimeKit/ComplicationBundles/DoseComplicationsCompanion.bundle/DoseComplicationsCompanion` | `needsLowering` | 111,200 | 79 | 6 | 0 | `notInCache` | `unranked` |
| `/System/Library/NanoTimeKit/ComplicationBundles/HearingDevicesComplicationContainerCompanion.bundle/HearingDevicesComplicationContainerCompanion` | `needsLowering` | 93,968 | 126 | 5 | 0 | `notInCache` | `unranked` |
| `/System/Library/NanoTimeKit/ComplicationBundles/MindComplicationBundleCompanion.bundle/MindComplicationBundleCompanion` | `needsLowering` | 97,232 | 192 | 5 | 0 | `notInCache` | `unranked` |
| `/System/Library/NanoTimeKit/ComplicationBundles/NTKAstronomyComplicationCompanion.bundle/NTKAstronomyComplicationCompanion` | `needsLowering` | 116,832 | 169 | 6 | 0 | `notInCache` | `unranked` |
| `/System/Library/NanoTimeKit/ComplicationBundles/NTKCellularConnectivityCompanionComplicationBundle.bundle/NTKCellularConnectivityCompanionComplicationBundle` | `needsLowering` | 93,136 | 98 | 5 | 0 | `notInCache` | `unranked` |
| `/System/Library/NanoTimeKit/ComplicationBundles/NTKMoonPhaseComplicationCompanion.bundle/NTKMoonPhaseComplicationCompanion` | `needsLowering` | 91,856 | 61 | 3 | 0 | `notInCache` | `unranked` |
| `/System/Library/NanoTimeKit/ComplicationBundles/NTKTimelyComplications.bundle/NTKTimelyComplications` | `needsLowering` | 135,024 | 262 | 8 | 0 | `notInCache` | `unranked` |
| `/System/Library/NanoTimeKit/ComplicationBundles/NTKTimerComplicationBundle.bundle/NTKTimerComplicationBundle` | `needsLowering` | 116,224 | 184 | 7 | 0 | `notInCache` | `unranked` |
| `/System/Library/NanoTimeKit/ComplicationBundles/NanoCalendarComplicationsCompanion.bundle/NanoCalendarComplicationsCompanion` | `needsLowering` | 212,752 | 590 | 18 | 0 | `notInCache` | `unranked` |
| `/System/Library/NanoTimeKit/ComplicationBundles/NanoCameraComplication.bundle/NanoCameraComplication` | `needsLowering` | 73,168 | 26 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/NanoTimeKit/ComplicationBundles/NanoMapsComplications.bundle/NanoMapsComplications` | `needsLowering` | 95,760 | 400 | 4 | 0 | `notInCache` | `unranked` |
| `/System/Library/NanoTimeKit/ComplicationBundles/NanoRemindersComplication.bundle/NanoRemindersComplication` | `needsLowering` | 138,096 | 316 | 7 | 0 | `notInCache` | `unranked` |
| `/System/Library/NanoTimeKit/ComplicationBundles/SiriComplication.bundle/SiriComplication` | `needsLowering` | 127,840 | 131 | 4 | 0 | `notInCache` | `unranked` |
| `/System/Library/NanoTimeKit/ComplicationBundles/VoiceMemosComplication.bundle/VoiceMemosComplication` | `needsLowering` | 72,384 | 28 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/NanoTimeKit/ComplicationBundles/WorkoutComplicationBundleCompanion.bundle/WorkoutComplicationBundleCompanion` | `needsLowering` | 147,840 | 199 | 8 | 0 | `notInCache` | `unranked` |
| `/System/Library/NanoTimeKit/ComplicationBundles/com.apple.finddevices.complications.bundle/com.apple.finddevices.complications` | `needsLowering` | 92,736 | 84 | 3 | 0 | `notInCache` | `unranked` |
| `/System/Library/NanoTimeKit/ComplicationBundles/com.apple.finditems.complications.bundle/com.apple.finditems.complications` | `needsLowering` | 92,736 | 84 | 3 | 0 | `notInCache` | `unranked` |
| `/System/Library/NanoTimeKit/ComplicationBundles/com.apple.findpeople.complications.bundle/com.apple.findpeople.complications` | `needsLowering` | 92,736 | 84 | 3 | 0 | `notInCache` | `unranked` |

### `/System/Library/Photos` (1)

| Image path | Plan state | Original bytes | Planned instructions | Slots | Unvisited | Cache relation | Review |
| --- | --- | ---: | ---: | ---: | ---: | --- | --- |
| `/System/Library/Photos/Resources/PhotosBundle.bundle/PhotosBundle` | `needsLowering` | 77,744 | 63 | 3 | 0 | `notInCache` | `unranked` |

### `/System/Library/Posters` (1)

| Image path | Plan state | Original bytes | Planned instructions | Slots | Unvisited | Cache relation | Review |
| --- | --- | ---: | ---: | ---: | ---: | --- | --- |
| `/System/Library/Posters/HostConfigurationProviders/AmbientHostConfigurationProvider.bundle/AmbientHostConfigurationProvider` | `needsLowering` | 95,136 | 167 | 5 | 0 | `notInCache` | `unranked` |

### `/System/Library/PreferenceBundles` (200)

| Image path | Plan state | Original bytes | Planned instructions | Slots | Unvisited | Cache relation | Review |
| --- | --- | ---: | ---: | ---: | ---: | --- | --- |
| `/System/Library/PreferenceBundles/AboutSettings.bundle/AboutSettings` | `needsLowering` | 233,392 | 554 | 18 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/AccessibilitySettings.bundle/AccessibilitySettings` | `needsLowering` | 4,928,592 | 15,116 | 447 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/AccessoryDeveloperSettings.bundle/AccessoryDeveloperSettings` | `needsLowering` | 109,824 | 114 | 5 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/AccessorySetupDeveloperSettings.bundle/AccessorySetupDeveloperSettings` | `needsLowering` | 509,104 | 1,976 | 74 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/AccountSettings/ActiveSyncSettings.bundle/ActiveSyncSettings` | `needsLowering` | 292,112 | 644 | 27 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/AccountSettings/AppleAccountSettings.bundle/AppleAccountSettings` | `needsLowering` | 614,080 | 2,233 | 65 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/AccountSettings/CloudKitSettings.bundle/CloudKitSettings` | `needsLowering` | 128,928 | 150 | 8 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/AccountSettings/DAVSettings.bundle/DAVSettings` | `needsLowering` | 92,160 | 64 | 4 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/AccountSettings/LDAPSettings.bundle/LDAPSettings` | `needsLowering` | 91,552 | 70 | 4 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/AccountSettings/MailAccountSettings.bundle/MailAccountSettings` | `needsLowering` | 985,520 | 2,652 | 120 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/AccountSettings/RemoteManagementAccountSettings.bundle/RemoteManagementAccountSettings` | `needsLowering` | 70,672 | 8 | 1 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/AccountSettings/SubscribedCalendarSettings.bundle/SubscribedCalendarSettings` | `needsLowering` | 90,160 | 47 | 3 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/AccountSettings/icloudCalendarSettings.bundle/icloudCalendarSettings` | `needsLowering` | 233,440 | 317 | 11 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/AccountSettings/icloudMailSettings.bundle/icloudMailSettings` | `needsLowering` | 4,688,384 | 9,008 | 246 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/AccountSettingsUI.bundle/AccountSettingsUI` | `needsLowering` | 108,576 | 146 | 9 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/ActionButtonSettings.bundle/ActionButtonSettings` | `needsLowering` | 95,984 | 119 | 4 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/ActivitySettings.bundle/ActivitySettings` | `needsLowering` | 72,496 | 25 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/AdAttributionKitDeveloperSettings.bundle/AdAttributionKitDeveloperSettings` | `needsLowering` | 281,120 | 1,155 | 34 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/AirDropSettings.bundle/AirDropSettings` | `needsLowering` | 158,464 | 417 | 13 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/AirPlayAndHandoffSettings.bundle/AirPlayAndHandoffSettings` | `needsLowering` | 179,728 | 475 | 17 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/AmbientSettings.bundle/AmbientSettings` | `needsLowering` | 117,008 | 198 | 7 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/AppClipDeveloperSettings.bundle/AppClipDeveloperSettings` | `needsLowering` | 297,872 | 1,479 | 38 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/AppInstallationSettings.bundle/AppInstallationSettings` | `needsLowering` | 323,536 | 1,022 | 42 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/AppManagedFeaturesDeveloperSettings.bundle/AppManagedFeaturesDeveloperSettings` | `needsLowering` | 228,288 | 632 | 27 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/AppManagedFeaturesSettings.bundle/AppManagedFeaturesSettings` | `needsLowering` | 140,752 | 238 | 10 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/AppearanceSettings.bundle/AppearanceSettings` | `needsLowering` | 160,560 | 449 | 14 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/AppleEthernetSettingsPreferences.bundle/AppleEthernetSettingsPreferences` | `needsLowering` | 136,192 | 183 | 6 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/AssistantSettings.bundle/AssistantSettings` | `needsLowering` | 98,528 | 96 | 4 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/AuthenticationServicesDeveloperSettings.bundle/AuthenticationServicesDeveloperSettings` | `needsLowering` | 71,056 | 12 | 1 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/BackgroundAppRefresh.bundle/BackgroundAppRefresh` | `needsLowering` | 178,256 | 640 | 17 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/BackgroundSecurityImprovement.bundle/BackgroundSecurityImprovement` | `needsLowering` | 1,175,120 | 7,960 | 217 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/BatteryUsageUI.bundle/BatteryUsageUI` | `needsLowering` | 1,831,792 | 7,906 | 273 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/BlocklistSettings.bundle/BlocklistSettings` | `needsLowering` | 158,768 | 321 | 13 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/CallDirectorySettings.bundle/CallDirectorySettings` | `needsLowering` | 72,736 | 30 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/CallForwardingTelephonySettings.bundle/CallForwardingTelephonySettings` | `needsLowering` | 108,416 | 146 | 5 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/CallHapticsSettingsBundle.bundle/CallHapticsSettingsBundle` | `needsLowering` | 71,104 | 20 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/CallRecordingSettingsBundle.bundle/CallRecordingSettingsBundle` | `needsLowering` | 96,496 | 101 | 3 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/CallScreeningSettingsBundle.bundle/CallScreeningSettingsBundle` | `needsLowering` | 94,592 | 96 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/CallWaitingTelephonySettings.bundle/CallWaitingTelephonySettings` | `needsLowering` | 74,352 | 56 | 3 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/CallingLineIdRestrictionTelephonySettings.bundle/CallingLineIdRestrictionTelephonySettings` | `needsLowering` | 74,368 | 56 | 3 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/CameraSettings.bundle/CameraSettings` | `needsLowering` | 676,464 | 2,273 | 73 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/CarKitSettings.bundle/CarKitSettings` | `needsLowering` | 644,976 | 2,681 | 77 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/CellularNetworkTelephonySettings.bundle/CellularNetworkTelephonySettings` | `needsLowering` | 90,160 | 92 | 3 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/ClarityUICameraSettings.bundle/ClarityUICameraSettings` | `needsLowering` | 70,832 | 18 | 1 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/ClarityUIMessagesSettings.bundle/ClarityUIMessagesSettings` | `needsLowering` | 107,632 | 123 | 4 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/ClarityUIMusicSettings.bundle/ClarityUIMusicSettings` | `needsLowering` | 162,544 | 276 | 8 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/ClarityUIPhoneFaceTimeSettings.bundle/ClarityUIPhoneFaceTimeSettings` | `needsLowering` | 108,592 | 123 | 4 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/ClarityUIPhotosSettings.bundle/ClarityUIPhotosSettings` | `needsLowering` | 138,592 | 163 | 5 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/ClarityUITVSettings.bundle/ClarityUITVSettings` | `needsLowering` | 72,256 | 14 | 1 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/ClassKitDeveloperSettings.bundle/ClassKitDeveloperSettings` | `needsLowering` | 113,456 | 280 | 8 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/ClassKitSettings.bundle/ClassKitSettings` | `needsLowering` | 113,872 | 135 | 6 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/ClassificationAndReportingSettingsBundle.bundle/ClassificationAndReportingSettingsBundle` | `needsLowering` | 94,496 | 60 | 3 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/CommunicationSafetySettings.bundle/CommunicationSafetySettings` | `needsLowering` | 72,592 | 26 | 1 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/CompassSettings.bundle/CompassSettings` | `needsLowering` | 76,864 | 52 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/ConferenceExternalSettings.bundle/ConferenceExternalSettings` | `needsLowering` | 73,696 | 87 | 3 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/ConferenceRegistrationSettings.bundle/ConferenceRegistrationSettings` | `needsLowering` | 95,392 | 85 | 4 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/ContactsSettings.bundle/ContactsSettings` | `needsLowering` | 162,464 | 290 | 10 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/Content Caches.bundle/Content Caches` | `needsLowering` | 355,568 | 1,830 | 49 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/ControlCenterSettings.bundle/ControlCenterSettings` | `needsLowering` | 147,744 | 319 | 10 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/CoreRoutineSettings.bundle/CoreRoutineSettings` | `needsLowering` | 204,544 | 551 | 19 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/CoverageSettings.bundle/CoverageSettings` | `needsLowering` | 76,368 | 70 | 3 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/DateAndTime.bundle/DateAndTime` | `needsLowering` | 221,792 | 705 | 23 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/DeveloperSettings.bundle/DeveloperSettings` | `needsLowering` | 360,768 | 974 | 34 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/DeviceEnrollments.bundle/DeviceEnrollments` | `needsLowering` | 197,904 | 649 | 18 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/DeviceManagementClientDeveloperSettings.bundle/DeviceManagementClientDeveloperSettings` | `needsLowering` | 70,432 | 6 | 1 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/DialAssistTelephonySettings.bundle/DialAssistTelephonySettings` | `needsLowering` | 72,304 | 28 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/DictionarySettings.bundle/DictionarySettings` | `needsLowering` | 116,816 | 176 | 6 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/DigitalSeparationSettings.bundle/DigitalSeparationSettings` | `needsLowering` | 138,608 | 253 | 8 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/DirectToVMSettingsBundle.bundle/DirectToVMSettingsBundle` | `needsLowering` | 72,944 | 46 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/DisplayAndBrightness.bundle/DisplayAndBrightness` | `needsLowering` | 95,968 | 78 | 3 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/DriverKitSettings.bundle/DriverKitSettings` | `needsLowering` | 96,848 | 123 | 4 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/ENDeveloperSettings.bundle/ENDeveloperSettings` | `needsLowering` | 71,488 | 16 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/EmergencyAlertExtension.bundle/EmergencyAlertExtension` | `needsLowering` | 72,928 | 54 | 3 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/ExposureNotificationSettingsUI.bundle/ExposureNotificationSettingsUI` | `needsLowering` | 267,728 | 765 | 27 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/FTAUplevelSettingsBundle.bundle/FTAUplevelSettingsBundle` | `needsLowering` | 71,264 | 16 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/FamilySettings.bundle/FamilySettings` | `needsLowering` | 74,240 | 42 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/FilterAsNewCallersSettingsBundle.bundle/FilterAsNewCallersSettingsBundle` | `needsLowering` | 94,768 | 120 | 5 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/FilterSpamSettingsBundle.bundle/FilterSpamSettingsBundle` | `needsLowering` | 72,784 | 32 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/FitnessSettings.bundle/FitnessSettings` | `needsLowering` | 277,184 | 1,093 | 30 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/FocusSettings.bundle/FocusSettings` | `needsLowering` | 220,000 | 676 | 18 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/FontSettings.bundle/FontSettings` | `needsLowering` | 843,072 | 5,424 | 143 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/FreeformSettings.bundle/FreeformSettings` | `needsLowering` | 130,320 | 92 | 4 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/GameCenterSettings.bundle/GameCenterSettings` | `needsLowering` | 75,664 | 54 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/GameControllerSettings.bundle/GameControllerSettings` | `needsLowering` | 113,520 | 221 | 6 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/Games Settings.bundle/Games Settings` | `needsLowering` | 72,080 | 16 | 1 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/GenerativePartnerService-UI Extensions/GenerativePartnerSettingsExperience.bundle/GenerativePartnerService-UI Extensions/GenerativePartnerSettingsExperience` | `needsLowering` | 93,808 | 127 | 3 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/HealthRecordsSettings.bundle/HealthRecordsSettings` | `needsLowering` | 69,824 | 22 | 1 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/HealthSettings.bundle/HealthSettings` | `needsLowering` | 95,680 | 77 | 4 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/HearingSettings.bundle/HearingSettings` | `needsLowering` | 532,624 | 1,645 | 58 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/HoldAssistSettingsBundle.bundle/HoldAssistSettingsBundle` | `needsLowering` | 72,688 | 40 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/HomePrivacySettings.bundle/HomePrivacySettings` | `needsLowering` | 156,576 | 475 | 14 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/HomeScreenSettings.bundle/HomeScreenSettings` | `needsLowering` | 139,792 | 290 | 10 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/HomeSettings.bundle/HomeSettings` | `needsLowering` | 135,792 | 169 | 5 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/ICBSettingsBundle.bundle/ICBSettingsBundle` | `needsLowering` | 98,352 | 130 | 3 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/ICSSettingsBundle.bundle/ICSSettingsBundle` | `needsLowering` | 117,232 | 174 | 5 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/IDSExternalSettings.bundle/IDSExternalSettings` | `needsLowering` | 91,152 | 111 | 4 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/ImagePlaygroundSettings.bundle/ImagePlaygroundSettings` | `needsLowering` | 71,824 | 18 | 1 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/InputAccessoriesBundle.bundle/InputAccessoriesBundle` | `needsLowering` | 71,120 | 14 | 1 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/IntelligentCallScreeningSettingsBundle.bundle/IntelligentCallScreeningSettingsBundle` | `needsLowering` | 93,024 | 60 | 3 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/InternationalSettings.bundle/InternationalSettings` | `needsLowering` | 324,640 | 1,022 | 32 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/JournalNotifications.bundle/JournalNotifications` | `needsLowering` | 1,108,816 | 4,640 | 161 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/JournalSettings.bundle/JournalSettings` | `needsLowering` | 838,048 | 3,316 | 114 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/KeyboardSettings.bundle/KeyboardSettings` | `needsLowering` | 458,656 | 1,501 | 46 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/KeyboardSettingsBundle.bundle/KeyboardSettingsBundle` | `needsLowering` | 437,696 | 1,386 | 43 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/LegalAndRegulatorySettings.bundle/LegalAndRegulatorySettings` | `needsLowering` | 92,448 | 84 | 3 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/MadridExternalSettings.bundle/MadridExternalSettings` | `needsLowering` | 113,152 | 205 | 5 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/Managed Background Assets Development-Override Settings.bundle/Managed Background Assets Development-Override Settings` | `needsLowering` | 95,616 | 73 | 4 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/ManagedConfigurationUI.bundle/ManagedConfigurationUI` | `needsLowering` | 101,408 | 167 | 6 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/MapsSettings.bundle/MapsSettings` | `needsLowering` | 852,448 | 2,147 | 59 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/MatterAccessoriesSettings.bundle/MatterAccessoriesSettings` | `needsLowering` | 112,672 | 106 | 5 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/MeasureSettings.bundle/MeasureSettings` | `needsLowering` | 75,776 | 61 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/MessagesNotificationFiltering.bundle/MessagesNotificationFiltering` | `needsLowering` | 73,472 | 41 | 3 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/MetalHUDDeveloperSettings.bundle/MetalHUDDeveloperSettings` | `needsLowering` | 90,064 | 95 | 4 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/MobileCalSettings.bundle/MobileCalSettings` | `needsLowering` | 216,544 | 501 | 16 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/MobileMailSettings.bundle/MobileMailSettings` | `needsLowering` | 362,080 | 1,016 | 35 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/MobileSlideShowSettings.bundle/MobileSlideShowSettings` | `needsLowering` | 341,136 | 823 | 28 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/MobileStoreSettings.bundle/MobileStoreSettings` | `needsLowering` | 428,976 | 1,662 | 60 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/MomentsNotificationSettings.bundle/MomentsNotificationSettings` | `needsLowering` | 157,488 | 160 | 6 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/MultitaskingAndGesturesSettings.bundle/MultitaskingAndGesturesSettings` | `needsLowering` | 417,984 | 1,760 | 56 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/MusicSettings.bundle/MusicSettings` | `needsLowering` | 274,048 | 675 | 24 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/NFCSettings.bundle/NFCSettings` | `needsLowering` | 116,128 | 211 | 6 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/NameAndPhotoSettingsBundle.bundle/NameAndPhotoSettingsBundle` | `needsLowering` | 70,768 | 14 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/NewsSettings.bundle/NewsSettings` | `needsLowering` | 146,096 | 229 | 9 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/NotesSettings.bundle/NotesSettings` | `needsLowering` | 189,312 | 411 | 15 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/NotificationsSettings.bundle/NotificationsSettings` | `needsLowering` | 705,760 | 2,961 | 92 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/PairedMacsDeveloperSettings.bundle/PairedMacsDeveloperSettings` | `needsLowering` | 395,440 | 1,471 | 48 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/PassbookSettings.bundle/PassbookSettings` | `needsLowering` | 155,520 | 352 | 11 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/PasscodeAndBiometricsSettingsPref.bundle/PasscodeAndBiometricsSettingsPref` | `needsLowering` | 93,760 | 62 | 4 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/PasswordsDeveloperSettings.bundle/PasswordsDeveloperSettings` | `needsLowering` | 70,992 | 12 | 1 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/PasswordsSettings.bundle/PasswordsSettings` | `needsLowering` | 197,696 | 428 | 18 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/PaymentContactlessSettingsUIPlugin.bundle/PaymentContactlessSettingsUIPlugin` | `needsLowering` | 118,640 | 223 | 6 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/PencilSettings.bundle/PencilSettings` | `needsLowering` | 196,048 | 536 | 15 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/PerformanceTraceDeveloperSettings.bundle/PerformanceTraceDeveloperSettings` | `needsLowering` | 115,232 | 178 | 6 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/PersonalHotspotDataUsage.bundle/PersonalHotspotDataUsage` | `needsLowering` | 115,504 | 129 | 7 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/PhonebookTelephonySettings.bundle/PhonebookTelephonySettings` | `needsLowering` | 90,928 | 74 | 3 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/PhotosCustomNotifications.bundle/PhotosCustomNotifications` | `needsLowering` | 72,544 | 26 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/PictureInPictureSettings.bundle/PictureInPictureSettings` | `needsLowering` | 95,136 | 88 | 3 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/PodcastsSettingsPlugin.bundle/PodcastsSettingsPlugin` | `needsLowering` | 244,592 | 846 | 26 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/PrimaryCloudCallingSettingsBundle.bundle/PrimaryCloudCallingSettingsBundle` | `needsLowering` | 117,536 | 182 | 6 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/Privacy/ClipServicesSettings.bundle/ClipServicesSettings` | `needsLowering` | 152,608 | 246 | 10 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/Privacy/HealthPrivacySettings.bundle/HealthPrivacySettings` | `needsLowering` | 110,544 | 86 | 4 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/Privacy/SensorKitPrivacySettings.bundle/SensorKitPrivacySettings` | `needsLowering` | 109,488 | 108 | 5 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/Privacy/WalletPrivacySettings.bundle/WalletPrivacySettings` | `needsLowering` | 96,928 | 152 | 5 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/PrivacyAndSecuritySettings.bundle/PrivacyAndSecuritySettings` | `needsLowering` | 936,464 | 4,404 | 139 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/QuickSwitchDeveloperSettings.bundle/QuickSwitchDeveloperSettings` | `needsLowering` | 150,672 | 462 | 12 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/RecentsCellTapBehaviorSettingsBundle.bundle/RecentsCellTapBehaviorSettingsBundle` | `needsLowering` | 70,848 | 18 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/RemindersSettings.bundle/RemindersSettings` | `needsLowering` | 294,656 | 1,039 | 33 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/ReplayKitLocalCaptureSettings.bundle/ReplayKitLocalCaptureSettings` | `needsLowering` | 93,824 | 94 | 4 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/ReplyWithMessageSettings.bundle/ReplyWithMessageSettings` | `needsLowering` | 94,816 | 62 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/SIMApplicationsTelephonySettings.bundle/SIMApplicationsTelephonySettings` | `needsLowering` | 72,624 | 42 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/SIMPasscodeTelephonySettings.bundle/SIMPasscodeTelephonySettings` | `needsLowering` | 92,016 | 109 | 4 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/SIMSettings.bundle/SIMSettings` | `needsLowering` | 70,336 | 2 | 1 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/SMSPreferences.bundle/SMSPreferences` | `needsLowering` | 121,584 | 191 | 7 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/SOSSettings.bundle/SOSSettings` | `needsLowering` | 237,344 | 671 | 20 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/ScreenTimeSettings.bundle/ScreenTimeSettings` | `needsLowering` | 97,328 | 122 | 4 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/ScreenTimeSettingsNotificationCustomization.bundle/ScreenTimeSettingsNotificationCustomization` | `needsLowering` | 75,856 | 35 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/ScreenshotServicesSettings.bundle/ScreenshotServicesSettings` | `needsLowering` | 139,968 | 357 | 10 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/SecondaryCloudCallingSettingsBundle.bundle/SecondaryCloudCallingSettingsBundle` | `needsLowering` | 118,144 | 196 | 6 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/SecuritySettings.bundle/SecuritySettings` | `needsLowering` | 149,232 | 267 | 10 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/SettingsCellular.bundle/SettingsCellular` | `needsLowering` | 116,368 | 173 | 7 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/SharePlaySettings.bundle/SharePlaySettings` | `needsLowering` | 114,208 | 157 | 5 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/ShortcutsSettings.bundle/ShortcutsSettings` | `needsLowering` | 117,968 | 160 | 6 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/SilenceCallsSettingBundle.bundle/SilenceCallsSettingBundle` | `needsLowering` | 91,952 | 68 | 3 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/SiriMessagesSettings.bundle/SiriMessagesSettings` | `needsLowering` | 290,896 | 966 | 41 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/SiriSettings.bundle/SiriSettings` | `needsLowering` | 300,976 | 688 | 16 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/SmartVoicemailActionsSettingsBundle.bundle/SmartVoicemailActionsSettingsBundle` | `needsLowering` | 71,136 | 20 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/SoftwareUpdateUIMobileSettingsPlugin.bundle/SoftwareUpdateUIMobileSettingsPlugin` | `needsLowering` | 619,040 | 4,013 | 100 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/SoundsAndHaptics.bundle/SoundsAndHaptics` | `needsLowering` | 95,808 | 117 | 4 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/SpotlightIndexingProgressSettings.bundle/SpotlightIndexingProgressSettings` | `needsLowering` | 157,680 | 515 | 14 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/SpotlightSetting.bundle/SpotlightSetting` | `needsLowering` | 72,512 | 18 | 1 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/StocksSettings.bundle/StocksSettings` | `needsLowering` | 93,296 | 71 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/StoragePlugins/CameraStoragePlugin.bundle/CameraStoragePlugin` | `needsLowering` | 70,720 | 20 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/StoragePlugins/HealthStoragePlugin.bundle/HealthStoragePlugin` | `needsLowering` | 91,440 | 72 | 4 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/StoragePlugins/PhotosStorageManagementSettings.bundle/PhotosStorageManagementSettings` | `needsLowering` | 90,416 | 72 | 4 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/StoragePlugins/PodcastsUsagePlugin.bundle/PodcastsUsagePlugin` | `needsLowering` | 116,288 | 233 | 8 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/StoragePlugins/UsagePlugin.bundle/UsagePlugin` | `needsLowering` | 91,296 | 38 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/StorageSettings.bundle/StorageSettings` | `needsLowering` | 298,880 | 618 | 28 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/StorageSettingsUI.bundle/StorageSettingsUI` | `needsLowering` | 931,104 | 4,126 | 134 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/SystemVersionSettings.bundle/SystemVersionSettings` | `needsLowering` | 368,272 | 2,277 | 53 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/TVNotificationSettings.bundle/TVNotificationSettings` | `needsLowering` | 95,088 | 124 | 6 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/TVSettings.bundle/TVSettings` | `needsLowering` | 188,288 | 475 | 16 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/TetsuoNotifications.bundle/TetsuoNotifications` | `needsLowering` | 94,560 | 158 | 5 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/TrackpadAndMouse.bundle/TrackpadAndMouse` | `needsLowering` | 157,664 | 425 | 12 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/TransferOrResetSettings.bundle/TransferOrResetSettings` | `needsLowering` | 175,680 | 342 | 12 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/TranslateSettings.bundle/TranslateSettings` | `needsLowering` | 76,624 | 50 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/VPNPreferences.bundle/VPNPreferences` | `needsLowering` | 360,176 | 808 | 37 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/VideoSubscriberAccountDeveloperSettings.bundle/VideoSubscriberAccountDeveloperSettings` | `needsLowering` | 109,680 | 173 | 7 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/VideoSubscriberAccountSettings.bundle/VideoSubscriberAccountSettings` | `needsLowering` | 170,080 | 360 | 11 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/VideoSubscriberAccountTVAppDeveloperSettings.bundle/VideoSubscriberAccountTVAppDeveloperSettings` | `needsLowering` | 90,384 | 96 | 4 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/VisionCompanionSettings.bundle/VisionCompanionSettings` | `needsLowering` | 93,760 | 100 | 3 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/VoiceControlSettings.bundle/VoiceControlSettings` | `needsLowering` | 261,456 | 692 | 23 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/VoiceMemosSettings.bundle/VoiceMemosSettings` | `needsLowering` | 135,776 | 297 | 9 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/VolumeLimitSettings.bundle/VolumeLimitSettings` | `needsLowering` | 142,720 | 355 | 9 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/WISDeveloperSettings.bundle/WISDeveloperSettings` | `needsLowering` | 134,000 | 340 | 10 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/WallpaperSettings.bundle/WallpaperSettings` | `needsLowering` | 415,472 | 1,713 | 48 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/WeatherSettings.bundle/WeatherSettings` | `needsLowering` | 136,400 | 307 | 9 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/WiFiCallingTelephonySettings.bundle/WiFiCallingTelephonySettings` | `needsLowering` | 90,800 | 128 | 4 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/WiFiSettings.bundle/WiFiSettings` | `needsLowering` | 159,200 | 347 | 13 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/iBooksSettings.bundle/iBooksSettings` | `needsLowering` | 157,216 | 315 | 11 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferenceBundles/iCloudPreferences.bundle/iCloudPreferences` | `needsLowering` | 94,240 | 70 | 3 | 0 | `notInCache` | `unranked` |

### `/System/Library/PreferencesSyncBundles` (3)

| Image path | Plan state | Original bytes | Planned instructions | Slots | Unvisited | Cache relation | Review |
| --- | --- | ---: | ---: | ---: | ---: | --- | --- |
| `/System/Library/PreferencesSyncBundles/FindMyDevicePreferencesSync.bundle/FindMyDevicePreferencesSync` | `needsLowering` | 68,672 | 77 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferencesSyncBundles/NanoClockBridgeSettingsPreferencesSyncCompanion.bundle/NanoClockBridgeSettingsPreferencesSyncCompanion` | `needsLowering` | 52,048 | 5 | 1 | 0 | `notInCache` | `unranked` |
| `/System/Library/PreferencesSyncBundles/NanoPhonePreferencesSyncCompanion.bundle/NanoPhonePreferencesSyncCompanion` | `needsLowering` | 52,224 | 18 | 1 | 0 | `notInCache` | `unranked` |

### `/System/Library/PrivateFrameworks` (41)

| Image path | Plan state | Original bytes | Planned instructions | Slots | Unvisited | Cache relation | Review |
| --- | --- | ---: | ---: | ---: | ---: | --- | --- |
| `/System/Library/PrivateFrameworks/AccessibilityAudit.framework/AccessibilityAuditCategories.bundle/AccessibilityAuditCategories` | `needsLowering` | 134,704 | 186 | 8 | 0 | `notInCache` | `P2` |
| `/System/Library/PrivateFrameworks/BlastDoor.framework/Resources/BlastDoorPosterArchiveBridging.bundle/BlastDoorPosterArchiveBridging` | `needsLowering` | 118,288 | 22 | 3 | 0 | `notInCache` | `unranked` |
| `/System/Library/PrivateFrameworks/CDDataAccess.framework/Frameworks/DACalDAV.framework/DADaemonCalDAV.bundle/DADaemonCalDAV` | `needsLowering` | 182,720 | 342 | 15 | 0 | `notInCache` | `unranked` |
| `/System/Library/PrivateFrameworks/CoreRC.framework/PlugIns/CoreRCHIDService.plugin/CoreRCHIDService` | `needsLowering` | 89,152 | 87 | 3 | 0 | `notInCache` | `unranked` |
| `/System/Library/PrivateFrameworks/CoreRC.framework/PlugIns/InterfacePlugins/CECIOCECInterfaceListener.plugin/CECIOCECInterfaceListener` | `needsLowering` | 73,184 | 70 | 3 | 0 | `notInCache` | `unranked` |
| `/System/Library/PrivateFrameworks/CoreTime.framework/TimeSources/AccessoryTimeSync.bundle/AccessoryTimeSync` | `needsLowering` | 135,904 | 183 | 7 | 0 | `notInCache` | `unranked` |
| `/System/Library/PrivateFrameworks/CoreTime.framework/TimeSources/CellularSource.bundle/CellularSource` | `needsLowering` | 89,344 | 74 | 3 | 0 | `notInCache` | `unranked` |
| `/System/Library/PrivateFrameworks/CoreTime.framework/TimeSources/LinkSource.bundle/LinkSource` | `needsLowering` | 128,496 | 293 | 9 | 0 | `notInCache` | `unranked` |
| `/System/Library/PrivateFrameworks/CoreTime.framework/TimeSources/PeerTimeSyncPlugin.bundle/PeerTimeSyncPlugin` | `needsLowering` | 246,368 | 887 | 28 | 0 | `notInCache` | `unranked` |
| `/System/Library/PrivateFrameworks/CoreTime.framework/TimeSources/RemoteServiceDiscoveryTimeSync.bundle/RemoteServiceDiscoveryTimeSync` | `needsLowering` | 95,200 | 131 | 5 | 0 | `notInCache` | `unranked` |
| `/System/Library/PrivateFrameworks/CoreTime.framework/TimeSources/timeAsset.bundle/timeAsset` | `needsLowering` | 88,176 | 60 | 3 | 0 | `notInCache` | `unranked` |
| `/System/Library/PrivateFrameworks/DVTInstrumentsFoundation.framework/PlugIns/DTODRAssetStatus.bundle/DTODRAssetStatus` | `needsLowering` | 90,048 | 46 | 3 | 0 | `notInCache` | `P2` |
| `/System/Library/PrivateFrameworks/DVTInstrumentsFoundation.framework/PlugIns/IDEDebugGaugeDataProviders.bundle/IDEDebugGaugeDataProviders` | `needsLowering` | 131,216 | 247 | 11 | 0 | `notInCache` | `P2` |
| `/System/Library/PrivateFrameworks/DVTInstrumentsFoundation.framework/libRemoteInjectionPayload.dylib` | `needsLowering` | 35,040 | 3 | 1 | 0 | `notInCache` | `P1` |
| `/System/Library/PrivateFrameworks/DVTInstrumentsFoundation.framework/liboainject.dylib` | `needsLowering` | 107,664 | 120 | 6 | 0 | `notInCache` | `P1` |
| `/System/Library/PrivateFrameworks/DataAccess.framework/Frameworks/DACalDAV.framework/DADaemonCalDAV.bundle/DADaemonCalDAV` | `needsLowering` | 257,632 | 516 | 21 | 0 | `notInCache` | `unranked` |
| `/System/Library/PrivateFrameworks/DataAccess.framework/Frameworks/DACardDAV.framework/DADaemonCardDAV.bundle/DADaemonCardDAV` | `needsLowering` | 347,936 | 771 | 36 | 0 | `notInCache` | `unranked` |
| `/System/Library/PrivateFrameworks/DataAccess.framework/Frameworks/DAIMAPNotes.framework/DADaemonIMAPNotes.bundle/DADaemonIMAPNotes` | `needsLowering` | 182,736 | 296 | 14 | 0 | `notInCache` | `unranked` |
| `/System/Library/PrivateFrameworks/DataAccess.framework/Frameworks/DALDAP.framework/DADaemonLDAP.bundle/DADaemonLDAP` | `needsLowering` | 71,856 | 6 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/PrivateFrameworks/DataAccess.framework/Frameworks/DASubCal.framework/DADaemonSubCal.bundle/DADaemonSubCal` | `needsLowering` | 163,920 | 287 | 12 | 0 | `notInCache` | `unranked` |
| `/System/Library/PrivateFrameworks/DeviceToDeviceManager.framework/PlugIns/BTD2DPlugin.bundle/BTD2DPlugin` | `needsLowering` | 118,256 | 407 | 9 | 0 | `notInCache` | `unranked` |
| `/System/Library/PrivateFrameworks/DeviceToDeviceManager.framework/PlugIns/WiFiAwareD2DPlugin.bundle/WiFiAwareD2DPlugin` | `needsLowering` | 69,712 | 20 | 1 | 0 | `notInCache` | `unranked` |
| `/System/Library/PrivateFrameworks/DeviceToDeviceManager.framework/PlugIns/WiFiD2DPlugin.bundle/WiFiD2DPlugin` | `needsLowering` | 69,712 | 20 | 1 | 0 | `notInCache` | `unranked` |
| `/System/Library/PrivateFrameworks/EmailCore.framework/PlugIns/EmailCore.wkbundle/EmailCore` | `needsLowering` | 70,912 | 24 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/PrivateFrameworks/ExchangeSync.framework/Frameworks/DAEAS.framework/DADaemonEAS.bundle/DADaemonEAS` | `needsLowering` | 542,944 | 837 | 63 | 0 | `notInCache` | `unranked` |
| `/System/Library/PrivateFrameworks/ExclavesStats.framework/ExclavesStats` | `needsLowering` | 317,696 | 513 | 19 | 0 | `notInCache` | `unranked` |
| `/System/Library/PrivateFrameworks/FontServices.framework/UITypographyPanel.bundle/UITypographyPanel` | `needsLowering` | 579,792 | 3,188 | 89 | 0 | `notInCache` | `unranked` |
| `/System/Library/PrivateFrameworks/GeoServices.framework/MapsOfflineService.bundle/MapsOfflineService` | `needsLowering` | 40,129,632 | 172,985 | 6,507 | 0 | `notInCache` | `unranked` |
| `/System/Library/PrivateFrameworks/InAppMessages.framework/PlugIns/InAppMessagesWebProcessBundle.bundle/InAppMessagesWebProcessBundle` | `needsLowering` | 89,264 | 54 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/PrivateFrameworks/MapsIntelligence.framework/IntelligenceBundles/SearchPersonalization.bundle/SearchPersonalization` | `needsLowering` | 4,378,816 | 38,621 | 772 | 0 | `notInCache` | `unranked` |
| `/System/Library/PrivateFrameworks/MobileMailUI.framework/PlugIns/MailWebProcessBundle.bundle/MailWebProcessBundle` | `needsLowering` | 90,544 | 85 | 4 | 0 | `notInCache` | `unranked` |
| `/System/Library/PrivateFrameworks/PromotedContentProxy.framework/PlugIns/PromotedContentWebProcessBundle.bundle/PromotedContentWebProcessBundle` | `needsLowering` | 125,888 | 235 | 6 | 0 | `notInCache` | `unranked` |
| `/System/Library/PrivateFrameworks/SiriTTSTraining.framework/SiriTTSTraining` | `needsLowering` | 4,628,592 | 16,325 | 556 | 0 | `notInCache` | `unranked` |
| `/System/Library/PrivateFrameworks/SlideshowKit.framework/PlugIns/OpusMagazineProducer.opplugin/OpusMagazineProducer` | `needsLowering` | 127,376 | 163 | 10 | 0 | `notInCache` | `unranked` |
| `/System/Library/PrivateFrameworks/SlideshowKit.framework/PlugIns/OpusNewClassicProducer.opplugin/OpusNewClassicProducer` | `needsLowering` | 91,392 | 62 | 5 | 0 | `notInCache` | `unranked` |
| `/System/Library/PrivateFrameworks/SlideshowKit.framework/PlugIns/OpusOrigamiProducer.opplugin/OpusOrigamiProducer` | `needsLowering` | 2,249,488 | 9,558 | 301 | 0 | `notInCache` | `unranked` |
| `/System/Library/PrivateFrameworks/SoftwareUpdateServicesUI.framework/Plugins/SoftwareUpdateServicesUIPlugin.servicebundle/SoftwareUpdateServicesUIPlugin` | `needsLowering` | 509,760 | 1,548 | 66 | 0 | `notInCache` | `unranked` |
| `/System/Library/PrivateFrameworks/TextToSpeechKonaSupport.framework/TextToSpeechKonaSupport` | `needsLowering` | 309,648 | 459 | 18 | 0 | `notInCache` | `unranked` |
| `/System/Library/PrivateFrameworks/UnifiedAssetFramework.framework/Resources/UAFPSUSPlugin.bundle/UAFPSUSPlugin` | `needsLowering` | 72,128 | 14 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/PrivateFrameworks/VisualUnderstanding.framework/Plugins.bundle/Plugins` | `needsLowering` | 150,384 | 266 | 12 | 0 | `notInCache` | `unranked` |
| `/System/Library/PrivateFrameworks/iWorkImport.framework/iWorkImport` | `needsLowering` | 878,144 | 2,982 | 84 | 0 | `notInCache` | `P2` |

### `/System/Library/Recents` (2)

| Image path | Plan state | Original bytes | Planned instructions | Slots | Unvisited | Cache relation | Review |
| --- | --- | ---: | ---: | ---: | ---: | --- | --- |
| `/System/Library/Recents/Plugins/GenericAddressHandler.addresshandler/GenericAddressHandler` | `needsLowering` | 70,208 | 10 | 1 | 0 | `notInCache` | `unranked` |
| `/System/Library/Recents/Plugins/MapsRecents.addresshandler/MapsRecents` | `needsLowering` | 69,472 | 2 | 1 | 0 | `notInCache` | `unranked` |

### `/System/Library/RelevanceEngine` (5)

| Image path | Plan state | Original bytes | Planned instructions | Slots | Unvisited | Cache relation | Review |
| --- | --- | ---: | ---: | ---: | ---: | --- | --- |
| `/System/Library/RelevanceEngine/NanoDataSources/BreatheRelevanceEngineDataSource.bundle/BreatheRelevanceEngineDataSource` | `needsLowering` | 71,728 | 16 | 1 | 0 | `notInCache` | `unranked` |
| `/System/Library/RelevanceEngine/NanoDataSources/MindRelevanceEngineDataSource.bundle/MindRelevanceEngineDataSource` | `needsLowering` | 117,248 | 257 | 9 | 0 | `notInCache` | `unranked` |
| `/System/Library/RelevanceEngine/NanoDataSources/RelevanceEngineActivityRings.bundle/RelevanceEngineActivityRings` | `needsLowering` | 92,864 | 60 | 4 | 0 | `notInCache` | `unranked` |
| `/System/Library/RelevanceEngine/NanoDataSources/RelevanceEngineActivityUpNext.bundle/RelevanceEngineActivityUpNext` | `needsLowering` | 112,368 | 138 | 5 | 0 | `notInCache` | `unranked` |
| `/System/Library/RelevanceEngine/NanoDataSources/RelevanceEngineReminders.bundle/RelevanceEngineReminders` | `needsLowering` | 75,360 | 28 | 2 | 0 | `notInCache` | `unranked` |

### `/System/Library/RemoteUI` (1)

| Image path | Plan state | Original bytes | Planned instructions | Slots | Unvisited | Cache relation | Review |
| --- | --- | ---: | ---: | ---: | ---: | --- | --- |
| `/System/Library/RemoteUI/Plugins/RemoteUINavigationProxy.bundle/RemoteUINavigationProxy` | `needsLowering` | 71,872 | 31 | 1 | 0 | `notInCache` | `unranked` |

### `/System/Library/ScreenReader` (22)

| Image path | Plan state | Original bytes | Planned instructions | Slots | Unvisited | Cache relation | Review |
| --- | --- | ---: | ---: | ---: | ---: | --- | --- |
| `/System/Library/ScreenReader/BrailleDrivers/Alva6Series.brailledriver/Alva6Series` | `needsLowering` | 92,016 | 25 | 4 | 0 | `notInCache` | `unranked` |
| `/System/Library/ScreenReader/BrailleDrivers/Baum.brailledriver/Baum` | `needsLowering` | 97,440 | 26 | 3 | 0 | `notInCache` | `unranked` |
| `/System/Library/ScreenReader/BrailleDrivers/BrailleNoteApex.brailledriver/BrailleNoteApex` | `needsLowering` | 91,792 | 24 | 3 | 0 | `notInCache` | `unranked` |
| `/System/Library/ScreenReader/BrailleDrivers/BrailleSense.brailledriver/BrailleSense` | `needsLowering` | 91,584 | 26 | 3 | 0 | `notInCache` | `unranked` |
| `/System/Library/ScreenReader/BrailleDrivers/Brailliant 2 Driver.brailledriver/Brailliant 2 Driver` | `needsLowering` | 92,128 | 24 | 3 | 0 | `notInCache` | `unranked` |
| `/System/Library/ScreenReader/BrailleDrivers/DOT Driver.brailledriver/DOT Driver` | `needsLowering` | 89,520 | 68 | 4 | 0 | `notInCache` | `unranked` |
| `/System/Library/ScreenReader/BrailleDrivers/EasyLink.brailledriver/EasyLink` | `needsLowering` | 92,208 | 26 | 3 | 0 | `notInCache` | `unranked` |
| `/System/Library/ScreenReader/BrailleDrivers/Eurobraille.brailledriver/Eurobraille` | `needsLowering` | 92,640 | 25 | 3 | 0 | `notInCache` | `unranked` |
| `/System/Library/ScreenReader/BrailleDrivers/FreedomScientific.brailledriver/FreedomScientific` | `needsLowering` | 92,480 | 24 | 3 | 0 | `notInCache` | `unranked` |
| `/System/Library/ScreenReader/BrailleDrivers/GenericHID.brailledriver/GenericHID` | `needsLowering` | 109,040 | 83 | 6 | 0 | `notInCache` | `unranked` |
| `/System/Library/ScreenReader/BrailleDrivers/HIMS Driver.brailledriver/HIMS Driver` | `needsLowering` | 91,584 | 24 | 3 | 0 | `notInCache` | `unranked` |
| `/System/Library/ScreenReader/BrailleDrivers/HandyTech.brailledriver/HandyTech` | `needsLowering` | 92,432 | 25 | 3 | 0 | `notInCache` | `unranked` |
| `/System/Library/ScreenReader/BrailleDrivers/KGS Driver.brailledriver/KGS Driver` | `needsLowering` | 91,888 | 25 | 4 | 0 | `notInCache` | `unranked` |
| `/System/Library/ScreenReader/BrailleDrivers/MDV.brailledriver/MDV` | `needsLowering` | 92,368 | 32 | 3 | 0 | `notInCache` | `unranked` |
| `/System/Library/ScreenReader/BrailleDrivers/Ninepoint Systems Driver.brailledriver/Ninepoint Systems Driver` | `needsLowering` | 74,992 | 24 | 3 | 0 | `notInCache` | `unranked` |
| `/System/Library/ScreenReader/BrailleDrivers/Papenmeier.brailledriver/Papenmeier` | `needsLowering` | 92,128 | 24 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/ScreenReader/BrailleDrivers/Seika.brailledriver/Seika` | `needsLowering` | 92,032 | 24 | 3 | 0 | `notInCache` | `unranked` |
| `/System/Library/ScreenReader/BrailleTables/AppleBrailleTranslator.brailletable/AppleBrailleTranslator` | `needsLowering` | 264,048 | 623 | 27 | 0 | `notInCache` | `unranked` |
| `/System/Library/ScreenReader/BrailleTables/BrailleNBSC.brailletable/BrailleNBSC` | `needsLowering` | 214,704 | 414 | 20 | 0 | `notInCache` | `unranked` |
| `/System/Library/ScreenReader/BrailleTables/Duxbury.brailletable/Duxbury` | `needsLowering` | 348,032 | 606 | 28 | 0 | `notInCache` | `unranked` |
| `/System/Library/ScreenReader/BrailleTables/LiblouisBrailleTranslator.brailletable/LiblouisBrailleTranslator` | `needsLowering` | 212,480 | 770 | 32 | 0 | `notInCache` | `unranked` |
| `/System/Library/ScreenReader/BrailleTables/Rhine.brailletable/Rhine` | `needsLowering` | 678,752 | 239 | 22 | 0 | `notInCache` | `unranked` |

### `/System/Library/ScreenTime` (1)

| Image path | Plan state | Original bytes | Planned instructions | Slots | Unvisited | Cache relation | Review |
| --- | --- | ---: | ---: | ---: | ---: | --- | --- |
| `/System/Library/ScreenTime/ScreenTimeSettingsPostMigrationSetup.bundle/ScreenTimeSettingsPostMigrationSetup` | `needsLowering` | 70,528 | 6 | 1 | 0 | `notInCache` | `unranked` |

### `/System/Library/Settings` (20)

| Image path | Plan state | Original bytes | Planned instructions | Slots | Unvisited | Cache relation | Review |
| --- | --- | ---: | ---: | ---: | ---: | --- | --- |
| `/System/Library/Settings/DefaultApps.settings/DefaultApps` | `needsLowering` | 72,048 | 24 | 1 | 0 | `notInCache` | `unranked` |
| `/System/Library/Settings/DefaultApps/AppInstallation.plugin/AppInstallation` | `needsLowering` | 120,304 | 310 | 9 | 0 | `notInCache` | `unranked` |
| `/System/Library/Settings/DefaultApps/CallFiltering.plugin/CallFiltering` | `needsLowering` | 98,784 | 229 | 5 | 0 | `notInCache` | `unranked` |
| `/System/Library/Settings/DefaultApps/DefaultAppsPasswordManagerSettings.plugin/DefaultAppsPasswordManagerSettings` | `needsLowering` | 73,744 | 55 | 1 | 0 | `notInCache` | `unranked` |
| `/System/Library/Settings/DefaultApps/DefaultCallingAppsSettings.plugin/DefaultCallingAppsSettings` | `needsLowering` | 231,040 | 813 | 26 | 0 | `notInCache` | `unranked` |
| `/System/Library/Settings/DefaultApps/DefaultContactlessAppSettingsUIPlugin.plugin/DefaultContactlessAppSettingsUIPlugin` | `needsLowering` | 117,216 | 346 | 8 | 0 | `notInCache` | `unranked` |
| `/System/Library/Settings/DefaultApps/DefaultMessagingAppsSettings.plugin/DefaultMessagingAppsSettings` | `needsLowering` | 214,224 | 733 | 21 | 0 | `notInCache` | `unranked` |
| `/System/Library/Settings/DefaultApps/Keyboards.plugin/Keyboards` | `needsLowering` | 99,936 | 184 | 4 | 0 | `notInCache` | `unranked` |
| `/System/Library/Settings/DefaultApps/MDESettings.plugin/MDESettings` | `needsLowering` | 121,728 | 286 | 7 | 0 | `notInCache` | `unranked` |
| `/System/Library/Settings/DeviceDiscoveryUISettings.settings/DeviceDiscoveryUISettings` | `needsLowering` | 191,840 | 582 | 21 | 0 | `notInCache` | `unranked` |
| `/System/Library/Settings/EnhancedFraudProtectionSettings.settings/EnhancedFraudProtectionSettings` | `needsLowering` | 71,344 | 14 | 1 | 0 | `notInCache` | `unranked` |
| `/System/Library/Settings/ExtensionKitSettings.settings/ExtensionKitSettings` | `needsLowering` | 119,776 | 280 | 8 | 0 | `notInCache` | `unranked` |
| `/System/Library/Settings/FollowUp.settings/FollowUp` | `needsLowering` | 95,440 | 100 | 3 | 0 | `notInCache` | `unranked` |
| `/System/Library/Settings/Headphones.settings/Headphones` | `needsLowering` | 74,800 | 38 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/Settings/InstalledApps.settings/InstalledApps` | `needsLowering` | 293,040 | 1,148 | 37 | 0 | `notInCache` | `unranked` |
| `/System/Library/Settings/NFCTCCSettings.settings/NFCTCCSettings` | `needsLowering` | 137,664 | 338 | 9 | 0 | `notInCache` | `unranked` |
| `/System/Library/Settings/ScreenTimeSettingsExperience.settings/ScreenTimeSettingsExperience` | `needsLowering` | 116,144 | 179 | 7 | 0 | `notInCache` | `unranked` |
| `/System/Library/Settings/SideButtonSettings.settings/SideButtonSettings` | `needsLowering` | 178,368 | 514 | 15 | 0 | `notInCache` | `unranked` |
| `/System/Library/Settings/TVRemoteSettings.settings/TVRemoteSettings` | `needsLowering` | 75,856 | 52 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/Settings/WalletPrivacySettings.settings/WalletPrivacySettings` | `needsLowering` | 94,944 | 88 | 3 | 0 | `notInCache` | `unranked` |

### `/System/Library/SetupAssistantBundles` (7)

| Image path | Plan state | Original bytes | Planned instructions | Slots | Unvisited | Cache relation | Review |
| --- | --- | ---: | ---: | ---: | ---: | --- | --- |
| `/System/Library/SetupAssistantBundles/FaceTimeSetupAssistantBundle.bundle/FaceTimeSetupAssistantBundle` | `needsLowering` | 69,136 | 2 | 1 | 0 | `notInCache` | `unranked` |
| `/System/Library/SetupAssistantBundles/GameCenterSetupAssistant.bundle/GameCenterSetupAssistant` | `needsLowering` | 69,696 | 6 | 1 | 0 | `notInCache` | `unranked` |
| `/System/Library/SetupAssistantBundles/MadridSetupAssistantBundle.bundle/MadridSetupAssistantBundle` | `needsLowering` | 68,976 | 2 | 1 | 0 | `notInCache` | `unranked` |
| `/System/Library/SetupAssistantBundles/SBSyncServiceSetupAssistantBundle.bundle/SBSyncServiceSetupAssistantBundle` | `needsLowering` | 71,280 | 12 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/SetupAssistantBundles/SetupDataAndPrivacyBundle.bundle/SetupDataAndPrivacyBundle` | `needsLowering` | 95,888 | 79 | 3 | 0 | `notInCache` | `unranked` |
| `/System/Library/SetupAssistantBundles/SetupDataAndPrivacyBundleUI.bundle/SetupDataAndPrivacyBundleUI` | `needsLowering` | 130,192 | 236 | 7 | 0 | `notInCache` | `unranked` |
| `/System/Library/SetupAssistantBundles/iTunesStoreSetupAssistant.bundle/iTunesStoreSetupAssistant` | `needsLowering` | 72,336 | 22 | 3 | 0 | `notInCache` | `unranked` |

### `/System/Library/Siri` (16)

| Image path | Plan state | Original bytes | Planned instructions | Slots | Unvisited | Cache relation | Review |
| --- | --- | ---: | ---: | ---: | ---: | --- | --- |
| `/System/Library/Siri/DM/SiriSuggestions/Owners/AppLaunchSuggestionsPlugin.bundle/AppLaunchSuggestionsPlugin` | `needsLowering` | 120,368 | 247 | 7 | 0 | `notInCache` | `unranked` |
| `/System/Library/Siri/DM/SiriSuggestions/Owners/AudioSuggestionsPlugin.bundle/AudioSuggestionsPlugin` | `needsLowering` | 211,376 | 722 | 25 | 0 | `notInCache` | `unranked` |
| `/System/Library/Siri/DM/SiriSuggestions/Owners/CalendarSuggestions.bundle/CalendarSuggestions` | `needsLowering` | 97,504 | 191 | 5 | 0 | `notInCache` | `unranked` |
| `/System/Library/Siri/DM/SiriSuggestions/Owners/HomeAutomationSiriSuggestions.bundle/HomeAutomationSiriSuggestions` | `needsLowering` | 406,896 | 1,311 | 45 | 0 | `notInCache` | `unranked` |
| `/System/Library/Siri/DM/SiriSuggestions/Owners/PhoneSuggestions.bundle/PhoneSuggestions` | `needsLowering` | 263,936 | 358 | 11 | 0 | `notInCache` | `unranked` |
| `/System/Library/Siri/DM/SiriSuggestions/Owners/PlaybackControlsSuggestionsPlugin.bundle/PlaybackControlsSuggestionsPlugin` | `needsLowering` | 92,928 | 98 | 3 | 0 | `notInCache` | `unranked` |
| `/System/Library/Siri/DM/SiriSuggestions/Owners/SiriGeoSuggestions.bundle/SiriGeoSuggestions` | `needsLowering` | 240,528 | 465 | 12 | 0 | `notInCache` | `unranked` |
| `/System/Library/Siri/DM/SiriSuggestions/Owners/SiriInformationSuggestionsPlugin.bundle/SiriInformationSuggestionsPlugin` | `needsLowering` | 426,688 | 730 | 24 | 0 | `notInCache` | `unranked` |
| `/System/Library/Siri/DM/SiriSuggestions/Owners/SiriLinkSuggestionsPlugin.bundle/SiriLinkSuggestionsPlugin` | `needsLowering` | 1,052,256 | 2,251 | 60 | 0 | `notInCache` | `unranked` |
| `/System/Library/Siri/DM/SiriSuggestions/Owners/SiriMessagesSuggestions.bundle/SiriMessagesSuggestions` | `needsLowering` | 118,992 | 238 | 8 | 0 | `notInCache` | `unranked` |
| `/System/Library/Siri/DM/SiriSuggestions/Owners/SiriNotebookSuggestionsPlugin.bundle/SiriNotebookSuggestionsPlugin` | `needsLowering` | 176,848 | 540 | 15 | 0 | `notInCache` | `unranked` |
| `/System/Library/Siri/DM/SiriSuggestions/Owners/SiriSettingsSuggestionsPlugin.bundle/SiriSettingsSuggestionsPlugin` | `needsLowering` | 115,696 | 256 | 6 | 0 | `notInCache` | `unranked` |
| `/System/Library/Siri/DM/SiriSuggestions/Owners/SiriSocialConversationSuggestionsPlugin.bundle/SiriSocialConversationSuggestionsPlugin` | `needsLowering` | 113,088 | 273 | 8 | 0 | `notInCache` | `unranked` |
| `/System/Library/Siri/DM/SiriSuggestions/Owners/SiriTimeSuggestionsPlugin.bundle/SiriTimeSuggestionsPlugin` | `needsLowering` | 157,136 | 402 | 14 | 0 | `notInCache` | `unranked` |
| `/System/Library/Siri/DM/SiriSuggestions/Owners/SystemCommandsSuggestionsPlugin.bundle/SystemCommandsSuggestionsPlugin` | `needsLowering` | 95,872 | 152 | 3 | 0 | `notInCache` | `unranked` |
| `/System/Library/Siri/DM/SiriSuggestions/Owners/VideoSuggestionsPlugin.bundle/VideoSuggestionsPlugin` | `needsLowering` | 79,184 | 103 | 2 | 0 | `notInCache` | `unranked` |

### `/System/Library/Snippets` (39)

| Image path | Plan state | Original bytes | Planned instructions | Slots | Unvisited | Cache relation | Review |
| --- | --- | ---: | ---: | ---: | ---: | --- | --- |
| `/System/Library/Snippets/UIPlugins/AlarmUIPlugin.bundle/AlarmUIPlugin` | `needsLowering` | 95,536 | 98 | 3 | 0 | `notInCache` | `unranked` |
| `/System/Library/Snippets/UIPlugins/AudioUIPlugin.bundle/AudioUIPlugin` | `needsLowering` | 182,960 | 509 | 15 | 0 | `notInCache` | `unranked` |
| `/System/Library/Snippets/UIPlugins/CalendarUIPlugin.bundle/CalendarUIPlugin` | `needsLowering` | 70,992 | 14 | 1 | 0 | `notInCache` | `unranked` |
| `/System/Library/Snippets/UIPlugins/CarCommandsUIPlugin.bundle/CarCommandsUIPlugin` | `needsLowering` | 68,576 | 8 | 1 | 0 | `notInCache` | `unranked` |
| `/System/Library/Snippets/UIPlugins/ClockUIPlugin.bundle/ClockUIPlugin` | `needsLowering` | 68,704 | 8 | 1 | 0 | `notInCache` | `unranked` |
| `/System/Library/Snippets/UIPlugins/ContactsFlowUIPlugin.bundle/ContactsFlowUIPlugin` | `needsLowering` | 122,736 | 61 | 3 | 0 | `notInCache` | `unranked` |
| `/System/Library/Snippets/UIPlugins/FindMyUIPlugin.bundle/FindMyUIPlugin` | `needsLowering` | 73,200 | 40 | 1 | 0 | `notInCache` | `unranked` |
| `/System/Library/Snippets/UIPlugins/GenerativeAssistantUIPlugin.bundle/GenerativeAssistantUIPlugin` | `needsLowering` | 74,400 | 12 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/Snippets/UIPlugins/GeoUIPlugin.bundle/GeoUIPlugin` | `needsLowering` | 73,904 | 8 | 1 | 0 | `notInCache` | `unranked` |
| `/System/Library/Snippets/UIPlugins/HomeAutomationUIPlugin.bundle/HomeAutomationUIPlugin` | `needsLowering` | 68,592 | 8 | 1 | 0 | `notInCache` | `unranked` |
| `/System/Library/Snippets/UIPlugins/HomeCommunicationUIPlugin.bundle/HomeCommunicationUIPlugin` | `needsLowering` | 77,472 | 58 | 3 | 0 | `notInCache` | `unranked` |
| `/System/Library/Snippets/UIPlugins/MessagesUIPlugin.bundle/MessagesUIPlugin` | `needsLowering` | 70,224 | 9 | 1 | 0 | `notInCache` | `unranked` |
| `/System/Library/Snippets/UIPlugins/MusicRecognitionUIPlugin.bundle/MusicRecognitionUIPlugin` | `needsLowering` | 165,424 | 413 | 14 | 0 | `notInCache` | `unranked` |
| `/System/Library/Snippets/UIPlugins/MusicSnippetsUI.bundle/MusicSnippetsUI` | `needsLowering` | 429,568 | 1,628 | 57 | 0 | `notInCache` | `unranked` |
| `/System/Library/Snippets/UIPlugins/NotebookUIPlugin.bundle/NotebookUIPlugin` | `needsLowering` | 69,040 | 2 | 1 | 0 | `notInCache` | `unranked` |
| `/System/Library/Snippets/UIPlugins/PhoneUIPlugin.bundle/PhoneUIPlugin` | `needsLowering` | 130,736 | 60 | 3 | 0 | `notInCache` | `unranked` |
| `/System/Library/Snippets/UIPlugins/ResponseGenerationUIPlugin.bundle/ResponseGenerationUIPlugin` | `needsLowering` | 285,552 | 999 | 31 | 0 | `notInCache` | `unranked` |
| `/System/Library/Snippets/UIPlugins/SearchToolUIPlugin.bundle/SearchToolUIPlugin` | `needsLowering` | 118,064 | 208 | 6 | 0 | `notInCache` | `unranked` |
| `/System/Library/Snippets/UIPlugins/SettingsCustomPlugin.bundle/SettingsCustomPlugin` | `needsLowering` | 120,304 | 257 | 7 | 0 | `notInCache` | `unranked` |
| `/System/Library/Snippets/UIPlugins/ShazamUIPlugin.bundle/ShazamUIPlugin` | `needsLowering` | 118,160 | 277 | 8 | 0 | `notInCache` | `unranked` |
| `/System/Library/Snippets/UIPlugins/SiriAppLaunchUIPlugin.bundle/SiriAppLaunchUIPlugin` | `needsLowering` | 74,992 | 62 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/Snippets/UIPlugins/SiriExpanseInternalUIPlugin.bundle/SiriExpanseInternalUIPlugin` | `needsLowering` | 92,080 | 235 | 6 | 0 | `notInCache` | `unranked` |
| `/System/Library/Snippets/UIPlugins/SiriInferenceFlowsUIPlugin.bundle/SiriInferenceFlowsUIPlugin` | `needsLowering` | 142,208 | 408 | 11 | 0 | `notInCache` | `unranked` |
| `/System/Library/Snippets/UIPlugins/SiriInformationUIPlugin.bundle/SiriInformationUIPlugin` | `needsLowering` | 280,480 | 393 | 9 | 0 | `notInCache` | `unranked` |
| `/System/Library/Snippets/UIPlugins/SiriKitFlowSnippetUIPlugin.bundle/SiriKitFlowSnippetUIPlugin` | `needsLowering` | 93,312 | 164 | 4 | 0 | `notInCache` | `unranked` |
| `/System/Library/Snippets/UIPlugins/SiriKitUIPlugin.bundle/SiriKitUIPlugin` | `needsLowering` | 195,312 | 198 | 7 | 0 | `notInCache` | `unranked` |
| `/System/Library/Snippets/UIPlugins/SiriLinkUIPlugin.bundle/SiriLinkUIPlugin` | `needsLowering` | 1,836,016 | 3,113 | 78 | 0 | `notInCache` | `unranked` |
| `/System/Library/Snippets/UIPlugins/SiriMailUIPlugin.bundle/SiriMailUIPlugin` | `needsLowering` | 74,160 | 49 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/Snippets/UIPlugins/SiriPaymentsUIPlugin.bundle/SiriPaymentsUIPlugin` | `needsLowering` | 174,112 | 572 | 17 | 0 | `notInCache` | `unranked` |
| `/System/Library/Snippets/UIPlugins/SiriSocialConversationUIPlugin.bundle/SiriSocialConversationUIPlugin` | `needsLowering` | 169,888 | 979 | 19 | 0 | `notInCache` | `unranked` |
| `/System/Library/Snippets/UIPlugins/SiriSuggestionsUIPlugin.bundle/SiriSuggestionsUIPlugin` | `needsLowering` | 204,640 | 525 | 20 | 0 | `notInCache` | `unranked` |
| `/System/Library/Snippets/UIPlugins/SiriSystemCommandsUIPlugin.bundle/SiriSystemCommandsUIPlugin` | `needsLowering` | 68,768 | 8 | 1 | 0 | `notInCache` | `unranked` |
| `/System/Library/Snippets/UIPlugins/SiriTranslationUIPlugin.bundle/SiriTranslationUIPlugin` | `needsLowering` | 70,720 | 10 | 1 | 0 | `notInCache` | `unranked` |
| `/System/Library/Snippets/UIPlugins/SiriVideoUIPlugin.bundle/SiriVideoUIPlugin` | `needsLowering` | 164,240 | 463 | 12 | 0 | `notInCache` | `unranked` |
| `/System/Library/Snippets/UIPlugins/SiriVideoUIPluginV2.bundle/SiriVideoUIPluginV2` | `needsLowering` | 71,456 | 22 | 1 | 0 | `notInCache` | `unranked` |
| `/System/Library/Snippets/UIPlugins/SnippetServiceUIPlugin.bundle/SnippetServiceUIPlugin` | `needsLowering` | 1,093,360 | 4,822 | 154 | 0 | `notInCache` | `unranked` |
| `/System/Library/Snippets/UIPlugins/SystemPlugin.bundle/SystemPlugin` | `needsLowering` | 326,336 | 1,352 | 39 | 0 | `notInCache` | `unranked` |
| `/System/Library/Snippets/UIPlugins/TimerUIPlugin.bundle/TimerUIPlugin` | `needsLowering` | 241,888 | 743 | 29 | 0 | `notInCache` | `unranked` |
| `/System/Library/Snippets/UIPlugins/WellnessUIPlugin.bundle/WellnessUIPlugin` | `needsLowering` | 68,720 | 8 | 1 | 0 | `notInCache` | `unranked` |

### `/System/Library/SpringBoardPlugins` (4)

| Image path | Plan state | Original bytes | Planned instructions | Slots | Unvisited | Cache relation | Review |
| --- | --- | ---: | ---: | ---: | ---: | --- | --- |
| `/System/Library/SpringBoardPlugins/FindMyiPhoneLockScreen.lockbundle/FindMyiPhoneLockScreen` | `needsLowering` | 91,200 | 118 | 4 | 0 | `notInCache` | `unranked` |
| `/System/Library/SpringBoardPlugins/PassesLockScreenPlugin.lockbundle/PassesLockScreenPlugin` | `needsLowering` | 128,480 | 200 | 8 | 0 | `notInCache` | `unranked` |
| `/System/Library/SpringBoardPlugins/StoreDemoPlugin.servicebundle/StoreDemoPlugin` | `needsLowering` | 166,992 | 416 | 12 | 0 | `notInCache` | `unranked` |
| `/System/Library/SpringBoardPlugins/ZoomTouch.bundle/ZoomTouch` | `needsLowering` | 112,128 | 146 | 5 | 0 | `notInCache` | `unranked` |

### `/System/Library/StreamingExtractorPlugins` (2)

| Image path | Plan state | Original bytes | Planned instructions | Slots | Unvisited | Cache relation | Review |
| --- | --- | ---: | ---: | ---: | ---: | --- | --- |
| `/System/Library/StreamingExtractorPlugins/Managed Background Assets Processing Pipeline.bundle/Managed Background Assets Processing Pipeline` | `needsLowering` | 452,128 | 1,574 | 75 | 0 | `notInCache` | `unranked` |
| `/System/Library/StreamingExtractorPlugins/STAEAExtractionPlugin.bundle/STAEAExtractionPlugin` | `needsLowering` | 91,808 | 136 | 5 | 0 | `notInCache` | `unranked` |

### `/System/Library/SyncBundles` (11)

| Image path | Plan state | Original bytes | Planned instructions | Slots | Unvisited | Cache relation | Review |
| --- | --- | ---: | ---: | ---: | ---: | --- | --- |
| `/System/Library/SyncBundles/AirFair.syncBundle/AirFair` | `incomplete` | 933,424 | 42 | 3 | 31 | `notInCache` | `analyze` |
| `/System/Library/SyncBundles/AirFair2.syncBundle/AirFair2` | `incomplete` | 2,291,488 | 119 | 7 | 296 | `notInCache` | `analyze` |
| `/System/Library/SyncBundles/Apps.syncBundle/Apps` | `needsLowering` | 162,448 | 194 | 11 | 0 | `notInCache` | `unranked` |
| `/System/Library/SyncBundles/Books.syncBundle/Books` | `needsLowering` | 200,912 | 621 | 20 | 0 | `notInCache` | `unranked` |
| `/System/Library/SyncBundles/LogsPlugin.syncBundle/LogsPlugin` | `needsLowering` | 69,504 | 2 | 1 | 0 | `notInCache` | `unranked` |
| `/System/Library/SyncBundles/MBATCPlugin.syncBundle/MBATCPlugin` | `needsLowering` | 70,240 | 6 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/SyncBundles/MobileSlideShow.syncBundle/MobileSlideShow` | `needsLowering` | 219,088 | 435 | 21 | 0 | `notInCache` | `unranked` |
| `/System/Library/SyncBundles/MusicLibrary.syncBundle/MusicLibrary` | `incomplete` | 2,296,992 | 780 | 44 | 296 | `notInCache` | `analyze` |
| `/System/Library/SyncBundles/SMS.syncBundle/SMS` | `needsLowering` | 72,224 | 36 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/SyncBundles/Tones.syncBundle/Tones` | `needsLowering` | 89,872 | 51 | 4 | 0 | `notInCache` | `unranked` |
| `/System/Library/SyncBundles/UserDataPlugin.syncBundle/UserDataPlugin` | `needsLowering` | 89,312 | 26 | 3 | 0 | `notInCache` | `unranked` |

### `/System/Library/SystemConfiguration` (6)

| Image path | Plan state | Original bytes | Planned instructions | Slots | Unvisited | Cache relation | Review |
| --- | --- | ---: | ---: | ---: | ---: | --- | --- |
| `/System/Library/SystemConfiguration/EAPOLController.bundle/EAPOLController` | `needsLowering` | 96,656 | 168 | 6 | 0 | `notInCache` | `unranked` |
| `/System/Library/SystemConfiguration/IPConfiguration.bundle/IPConfiguration` | `needsLowering` | 550,672 | 1,752 | 93 | 0 | `notInCache` | `unranked` |
| `/System/Library/SystemConfiguration/PPPController.bundle/PPPController` | `needsLowering` | 370,016 | 925 | 42 | 0 | `notInCache` | `unranked` |
| `/System/Library/SystemConfiguration/PPPController.bundle/PlugIns/L2TP.ppp/L2TP` | `needsLowering` | 154,048 | 263 | 15 | 0 | `notInCache` | `unranked` |
| `/System/Library/SystemConfiguration/PPPController.bundle/PlugIns/PPPDialogs.ppp/PPPDialogs` | `needsLowering` | 72,384 | 22 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/SystemConfiguration/USBDeviceConfiguration.bundle/USBDeviceConfiguration` | `needsLowering` | 73,104 | 26 | 2 | 0 | `notInCache` | `unranked` |

### `/System/Library/TextInput` (1)

| Image path | Plan state | Original bytes | Planned instructions | Slots | Unvisited | Cache relation | Review |
| --- | --- | ---: | ---: | ---: | ---: | --- | --- |
| `/System/Library/TextInput/Plugins/MessagesDataKeyboardPlugin.bundle/MessagesDataKeyboardPlugin` | `needsLowering` | 69,824 | 10 | 2 | 0 | `notInCache` | `unranked` |

### `/System/Library/Trace` (7)

| Image path | Plan state | Original bytes | Planned instructions | Slots | Unvisited | Cache relation | Review |
| --- | --- | ---: | ---: | ---: | ---: | --- | --- |
| `/System/Library/Trace/PassiveDataSources/AppInFocus.bundle/AppInFocus` | `needsLowering` | 72,624 | 16 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/Trace/PassiveDataSources/Microstackshot.bundle/Microstackshot` | `needsLowering` | 72,400 | 12 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/Trace/Providers/CPUTrace.bundle/CPUTrace` | `needsLowering` | 143,856 | 297 | 9 | 0 | `notInCache` | `unranked` |
| `/System/Library/Trace/Providers/Logging.bundle/Logging` | `needsLowering` | 150,928 | 477 | 11 | 0 | `notInCache` | `unranked` |
| `/System/Library/Trace/Providers/Required.bundle/Required` | `needsLowering` | 132,672 | 480 | 10 | 0 | `notInCache` | `unranked` |
| `/System/Library/Trace/Providers/SwiftUI.bundle/SwiftUI` | `needsLowering` | 81,520 | 29 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/Trace/Providers/Symbolication.bundle/Symbolication` | `needsLowering` | 71,648 | 19 | 2 | 0 | `notInCache` | `unranked` |

### `/System/Library/UsageBundles` (11)

| Image path | Plan state | Original bytes | Planned instructions | Slots | Unvisited | Cache relation | Review |
| --- | --- | ---: | ---: | ---: | ---: | --- | --- |
| `/System/Library/UsageBundles/CalendarUsage.bundle/CalendarUsage` | `needsLowering` | 72,272 | 22 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/UsageBundles/ContactsUsage.bundle/ContactsUsage` | `needsLowering` | 70,720 | 6 | 1 | 0 | `notInCache` | `unranked` |
| `/System/Library/UsageBundles/MailUsage.bundle/MailUsage` | `needsLowering` | 72,464 | 25 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/UsageBundles/MessagesUsagePreferencesPlugin.bundle/MessagesUsagePreferencesPlugin` | `needsLowering` | 69,552 | 4 | 1 | 0 | `notInCache` | `unranked` |
| `/System/Library/UsageBundles/MusicUsage.bundle/MusicUsage` | `needsLowering` | 130,656 | 197 | 10 | 0 | `notInCache` | `unranked` |
| `/System/Library/UsageBundles/NanoBackupUsage.bundle/NanoBackupUsage` | `needsLowering` | 91,856 | 48 | 4 | 0 | `notInCache` | `unranked` |
| `/System/Library/UsageBundles/PassbookUsageBundle.bundle/PassbookUsageBundle` | `needsLowering` | 70,864 | 10 | 1 | 0 | `notInCache` | `unranked` |
| `/System/Library/UsageBundles/SoftwareUpdateUsage.bundle/SoftwareUpdateUsage` | `needsLowering` | 73,696 | 15 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/UsageBundles/ToneSettingsUsage.bundle/ToneSettingsUsage` | `needsLowering` | 71,248 | 13 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/UsageBundles/VideosUsage.bundle/VideosUsage` | `needsLowering` | 111,856 | 137 | 7 | 0 | `notInCache` | `unranked` |
| `/System/Library/UsageBundles/VisualVoicemailUsage.bundle/VisualVoicemailUsage` | `needsLowering` | 70,416 | 12 | 2 | 0 | `notInCache` | `unranked` |

### `/System/Library/UserEventPlugins` (33)

| Image path | Plan state | Original bytes | Planned instructions | Slots | Unvisited | Cache relation | Review |
| --- | --- | ---: | ---: | ---: | ---: | --- | --- |
| `/System/Library/UserEventPlugins/ADEventListenerPlugin.plugin/ADEventListenerPlugin` | `needsLowering` | 56,784 | 33 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/UserEventPlugins/AHTUserEventAgent.plugin/AHTUserEventAgent` | `needsLowering` | 95,168 | 161 | 7 | 0 | `notInCache` | `unranked` |
| `/System/Library/UserEventPlugins/BonjourEvents.plugin/BonjourEvents` | `needsLowering` | 56,704 | 36 | 3 | 0 | `notInCache` | `unranked` |
| `/System/Library/UserEventPlugins/GreenTeaUserEventAgent.plugin/GreenTeaUserEventAgent` | `needsLowering` | 52,256 | 10 | 1 | 0 | `notInCache` | `unranked` |
| `/System/Library/UserEventPlugins/ManagedConfigurationUEA.plugin/ManagedConfigurationUEA` | `needsLowering` | 56,352 | 38 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/UserEventPlugins/MemoryMonitor.plugin/MemoryMonitor` | `needsLowering` | 56,832 | 32 | 3 | 0 | `notInCache` | `unranked` |
| `/System/Library/UserEventPlugins/MobileBackupUEA.plugin/MobileBackupUEA` | `needsLowering` | 131,776 | 231 | 10 | 0 | `notInCache` | `unranked` |
| `/System/Library/UserEventPlugins/MobileGestaltEvents.plugin/MobileGestaltEvents` | `needsLowering` | 54,400 | 8 | 1 | 0 | `notInCache` | `unranked` |
| `/System/Library/UserEventPlugins/MobileKeyBagLockState.plugin/MobileKeyBagLockState` | `needsLowering` | 53,248 | 6 | 1 | 0 | `notInCache` | `unranked` |
| `/System/Library/UserEventPlugins/PerfPowerServicesEventListenerPlugin.plugin/PerfPowerServicesEventListenerPlugin` | `needsLowering` | 114,608 | 319 | 9 | 0 | `notInCache` | `unranked` |
| `/System/Library/UserEventPlugins/USBEthernetSharing.plugin/USBEthernetSharing` | `needsLowering` | 60,864 | 69 | 3 | 0 | `notInCache` | `unranked` |
| `/System/Library/UserEventPlugins/com.apple.AppleKeyStoreEvents.plugin/com.apple.AppleKeyStoreEvents` | `needsLowering` | 57,264 | 63 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/UserEventPlugins/com.apple.BackgroundTaskAgentPlugin.plugin/com.apple.BackgroundTaskAgentPlugin` | `needsLowering` | 96,960 | 252 | 7 | 0 | `notInCache` | `unranked` |
| `/System/Library/UserEventPlugins/com.apple.ExternalAccessory.matching.plugin/com.apple.ExternalAccessory.matching` | `needsLowering` | 55,120 | 25 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/UserEventPlugins/com.apple.accessoryd.matching.plugin/com.apple.accessoryd.matching` | `needsLowering` | 745,088 | 1,540 | 55 | 0 | `notInCache` | `unranked` |
| `/System/Library/UserEventPlugins/com.apple.alarm.plugin/com.apple.alarm` | `needsLowering` | 57,824 | 64 | 3 | 0 | `notInCache` | `unranked` |
| `/System/Library/UserEventPlugins/com.apple.bonjour.plugin/com.apple.bonjour` | `needsLowering` | 55,136 | 21 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/UserEventPlugins/com.apple.cfnotification.plugin/com.apple.cfnotification` | `needsLowering` | 54,560 | 18 | 1 | 0 | `notInCache` | `unranked` |
| `/System/Library/UserEventPlugins/com.apple.cts.plugin/com.apple.cts` | `needsLowering` | 137,888 | 114 | 9 | 0 | `notInCache` | `unranked` |
| `/System/Library/UserEventPlugins/com.apple.dispatch.vfs.plugin/com.apple.dispatch.vfs` | `needsLowering` | 53,680 | 13 | 1 | 0 | `notInCache` | `unranked` |
| `/System/Library/UserEventPlugins/com.apple.fsevents.matching.plugin/com.apple.fsevents.matching` | `needsLowering` | 77,264 | 82 | 4 | 0 | `notInCache` | `unranked` |
| `/System/Library/UserEventPlugins/com.apple.iokit.matching.plugin/com.apple.iokit.matching` | `needsLowering` | 54,224 | 12 | 1 | 0 | `notInCache` | `unranked` |
| `/System/Library/UserEventPlugins/com.apple.launchd.helper.plugin/com.apple.launchd.helper` | `needsLowering` | 54,336 | 9 | 1 | 0 | `notInCache` | `unranked` |
| `/System/Library/UserEventPlugins/com.apple.netsvcproxy.plugin/com.apple.netsvcproxy` | `needsLowering` | 133,232 | 328 | 11 | 0 | `notInCache` | `unranked` |
| `/System/Library/UserEventPlugins/com.apple.networkextension.plugin/com.apple.networkextension` | `needsLowering` | 77,488 | 55 | 3 | 0 | `notInCache` | `unranked` |
| `/System/Library/UserEventPlugins/com.apple.nsurlsessiond.plugin/com.apple.nsurlsessiond` | `needsLowering` | 54,416 | 15 | 1 | 0 | `notInCache` | `unranked` |
| `/System/Library/UserEventPlugins/com.apple.rapport.events.plugin/com.apple.rapport.events` | `needsLowering` | 52,672 | 11 | 1 | 0 | `notInCache` | `unranked` |
| `/System/Library/UserEventPlugins/com.apple.spd.plugin/com.apple.spd` | `needsLowering` | 78,784 | 218 | 6 | 0 | `notInCache` | `unranked` |
| `/System/Library/UserEventPlugins/com.apple.systemconfiguration.plugin/com.apple.systemconfiguration` | `needsLowering` | 53,952 | 12 | 1 | 0 | `notInCache` | `unranked` |
| `/System/Library/UserEventPlugins/com.apple.tailspin.plugin/com.apple.tailspin` | `needsLowering` | 54,432 | 11 | 1 | 0 | `notInCache` | `unranked` |
| `/System/Library/UserEventPlugins/com.apple.telemetry.plugin/com.apple.telemetry` | `needsLowering` | 112,224 | 246 | 9 | 0 | `notInCache` | `unranked` |
| `/System/Library/UserEventPlugins/locationd.events.plugin/locationd.events` | `needsLowering` | 57,248 | 42 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/UserEventPlugins/routined.events.plugin/routined.events` | `needsLowering` | 55,136 | 25 | 2 | 0 | `notInCache` | `unranked` |

### `/System/Library/UserNotifications` (2)

| Image path | Plan state | Original bytes | Planned instructions | Slots | Unvisited | Cache relation | Review |
| --- | --- | ---: | ---: | ---: | ---: | --- | --- |
| `/System/Library/UserNotifications/Bundles/com.apple.Siri.ActionPredictionNotifications.bundle/com.apple.Siri.ActionPredictionNotifications` | `needsLowering` | 52,192 | 188 | 2 | 0 | `notInCache` | `unranked` |
| `/System/Library/UserNotifications/Bundles/com.apple.asktod.bundle/com.apple.asktod` | `needsLowering` | 69,504 | 2 | 1 | 0 | `notInCache` | `unranked` |

### `/System/Library/Video` (2)

| Image path | Plan state | Original bytes | Planned instructions | Slots | Unvisited | Cache relation | Review |
| --- | --- | ---: | ---: | ---: | ---: | --- | --- |
| `/System/Library/Video/Plug-Ins/AppleMCTF.bundle/AppleMCTF` | `needsLowering` | 990,560 | 1,472 | 135 | 0 | `notInCache` | `P2` |
| `/System/Library/Video/Plug-Ins/AppleVideoEncoder.bundle/AppleVideoEncoder` | `needsLowering` | 2,361,472 | 3,503 | 392 | 0 | `notInCache` | `P2` |

### `/System/Library/VideoProcessors` (10)

| Image path | Plan state | Original bytes | Planned instructions | Slots | Unvisited | Cache relation | Review |
| --- | --- | ---: | ---: | ---: | ---: | --- | --- |
| `/System/Library/VideoProcessors/ColourConstancyV1.bundle/ColourConstancyV1` | `needsLowering` | 282,064 | 1,073 | 23 | 0 | `notInCache` | `unranked` |
| `/System/Library/VideoProcessors/GenIEV1.bundle/GenIEV1` | `needsLowering` | 180,944 | 254 | 12 | 0 | `notInCache` | `unranked` |
| `/System/Library/VideoProcessors/RTSCV1.bundle/RTSCV1` | `needsLowering` | 238,592 | 477 | 17 | 0 | `notInCache` | `unranked` |
| `/System/Library/VideoProcessors/SemanticStyleV1.bundle/SemanticStyleV1` | `needsLowering` | 159,312 | 508 | 15 | 0 | `notInCache` | `unranked` |
| `/System/Library/VideoProcessors/SmartStyleV1.bundle/SmartStyleV1` | `needsLowering` | 288,176 | 660 | 15 | 0 | `notInCache` | `unranked` |
| `/System/Library/VideoProcessors/SuperResolutionV2.bundle/SuperResolutionV2` | `needsLowering` | 159,696 | 250 | 18 | 0 | `notInCache` | `unranked` |
| `/System/Library/VideoProcessors/VideoDeghostingV1.bundle/VideoDeghostingV1` | `needsLowering` | 266,720 | 1,251 | 32 | 0 | `notInCache` | `unranked` |
| `/System/Library/VideoProcessors/VideoDeghostingV2.bundle/VideoDeghostingV2` | `needsLowering` | 331,856 | 1,064 | 38 | 0 | `notInCache` | `unranked` |
| `/System/Library/VideoProcessors/VideoDeghostingV3.bundle/VideoDeghostingV3` | `needsLowering` | 508,560 | 1,363 | 42 | 0 | `notInCache` | `unranked` |
| `/System/Library/VideoProcessors/VideoStabilizationV2.bundle/VideoStabilizationV2` | `needsLowering` | 643,568 | 2,159 | 54 | 0 | `notInCache` | `unranked` |

### `/System/Library/VoiceServices` (1)

| Image path | Plan state | Original bytes | Planned instructions | Slots | Unvisited | Cache relation | Review |
| --- | --- | ---: | ---: | ---: | ---: | --- | --- |
| `/System/Library/VoiceServices/PlugIns/Base.vsplugin/Base` | `needsLowering` | 70,672 | 11 | 1 | 0 | `notInCache` | `unranked` |

### `/System/Library/iCloudSettings` (1)

| Image path | Plan state | Original bytes | Planned instructions | Slots | Unvisited | Cache relation | Review |
| --- | --- | ---: | ---: | ---: | ---: | --- | --- |
| `/System/Library/iCloudSettings/com.apple.Dataclass.Siri.bundle/com.apple.Dataclass.Siri` | `needsLowering` | 99,552 | 82 | 2 | 0 | `notInCache` | `unranked` |

### `/usr/lib` (4)

| Image path | Plan state | Original bytes | Planned instructions | Slots | Unvisited | Cache relation | Review |
| --- | --- | ---: | ---: | ---: | ---: | --- | --- |
| `/usr/lib/libCoreFP.dylib` | `incomplete` | 1,127,488 | 4 | 1 | 163 | `notInCache` | `analyze` |
| `/usr/lib/libCoreKE.dylib` | `incomplete` | 22,866,944 | 983 | 36 | 1,107 | `notInCache` | `analyze` |
| `/usr/lib/libSystem.B_asan.dylib` | `needsLowering` | 75,344 | 18 | 1 | 0 | `differentBuildInCache` | `P1` |
| `/usr/lib/swift/libswiftRemoteMirror.dylib` | `needsLowering` | 1,631,808 | 5,855 | 207 | 0 | `notInCache` | `P1` |
