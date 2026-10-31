# HomePod SoundBoard controls and setup

## Scope and validation boundary

This extends the HomePod mini support for AudioAccessory5,1, HomePod Software
27.0 (24J361). The implementation adds a Metal top-cap renderer, the complete
SoundBoardServices debug interface, and optional local setup completion. Initial
validation was offline; on 2026-10-22 the owner authorized bundle installation
and live tests on the existing `homepod-mini` VM. The live results and remaining
service boundaries are recorded below.

## Runtime Metal renderer

`VPhoneHomePodMetalView` replaces AppKit gradient/LED drawing while native
buttons retain accessibility, focus and the existing consumer HID input path.
The source string in `VPhoneHomePodShader.swift` is compiled at runtime using
`MTL4Compiler` and `MTL4LibraryDescriptor`, then an `MTL4RenderPipelineDescriptor`.
Submission uses an actual `MTL4CommandQueue`, command allocator, command buffer,
argument table and explicit residency set. Each of three slots owns its input
buffers and command memory until GPU feedback. Snapshots arriving while all
slots are busy collapse to the newest pending frame. The UI does not wait for
GPU completion. Drawable acquisition/presentation uses the Metal 4 drawable
wait/signal protocol.

Metal 4 is used on a supporting GPU on macOS 26 or later. The macOS 15 minimum
is retained with runtime MSL 3.1 compilation and the older command queue API;
both paths use the same optical shader. There are no `.metal` build inputs,
`metal`/`metallib` invocations or optional Xcode Metal toolchain dependencies.
Apple's [Metal 4 compilation API](https://developer.apple.com/documentation/metal/using-the-metal-4-compilation-api)
and [core API documentation](https://developer.apple.com/documentation/metal/understanding-the-metal-4-core-api),
checked against the selected SDK headers, describe these separate APIs.

The shader uses the donor device-tree coordinates without stretching the
unpopulated rim. A normalized Gaussian mixture (weights 0.86/0.14, sigma
0.155/0.29 in cap coordinates) spreads the guest's two summed light banks.
Normalization includes unlit emitters so sparse patterns remain visible. A
smooth radial mask suppresses light near the opaque rim. Exposure and a soft
shoulder preserve colored highlights; an sRGB render target performs one final
transfer. Static glass/rim shading and analytic +/- masks supply the surface.
Only guest brightness controls illumination. There is no time input, host Siri
animation or interpolated invented frame.

The optical parameters are an approximation informed by the original mini's
[Apple launch photography](https://www.apple.com/newsroom/2020/10/apple-introduces-homepod-mini-a-powerful-smart-speaker-with-amazing-sound/)
and [Apple's status-light examples](https://support.apple.com/en-us/101607).
They reproduce broad mixed light and a dark edge; they are not measurements of
the diffuser, spectral response or exact layer composition. The current product
page describes a newer mini and was not treated as B520 hardware evidence.

`VPhoneExecutable/VPhoneVirtualization/Tests/run-homepod-metal-tests.sh` compiles
the actual shader/backend with Swift and runs without a VM. On macOS 27.0.1,
Apple M2 Max, the real Metal 4 compiler/queue passed off/white/RGB isolation,
edge attenuation, independent icon lighting, diffuser blending, identical-frame
determinism and eight rounds of three concurrent frames. The MSL 3.1 path
matched Metal 4 output within two byte levels. Synthetic image fixtures are in
`.build/homepod-metal-tests/`; multicolor fixtures are not evidence of Siri
working in a guest. The GPU probe needs GPU access outside the process sandbox.
A separate scratch app compiled the actual `VPhoneHomePodDisplayView`, renderer
and shader. Its 640-point Retina window displayed the synthetic multicolor
frame through a real CAMetalDrawable, retained accessible volume buttons, and
redrew correctly when zoomed to a wide desktop window and restored. This needed
no VM or installed bundle. The initial scratch-app minimize test hit a UI automation limitation; its two
owned test processes were terminated. The later live VM window was successfully
minimized and restored, with continued native frames, as recorded below.

## Complete SoundBoard debug interface

The donor SoundBoardServices cache image was extracted with repaired Objective-C
metadata and stubs; SHA-256
`5e5d68df84c8c3a54669a1618ea1cb8f3d12996b4ffe5d9be3828b62917cf41a`.
REA inventory `ev_9490010b3a7f2ac743b300cfd85baa88060529dde104530675217ac23d7be5e2`
contains 29 debug methods plus lifecycle methods. Exact argument encodings and
reply block types were recovered from the original cache's optimized relative
method lists and `SBSDebugInfoImplementer` protocol, rather than inferred from
decompiler casts. Original-cache disassembly of `SBSServer` demonstrates the
`com.apple.debuginfo.soundboard` entitlement gate; vphoned carries that grant.
SoundBoard's executable is not changed for this interface.

| Group | Exposed selectors |
| --- | --- |
| Diagnostics | `getAllDebugInfo:`, `getSelectDebugInfo:reply:` |
| Display | `getLEDInfo:`, `sendLEDCommand:`, `render:`, `setLEDContents:`, `setBootSpinner:` |
| Audio | `getVolume:`, `setVolume:`, `playTone:`, `stopTone:`, `siriSay:` |
| Input | `sendButtonCommand:` |
| Tuning | `getTuningInfo:`, `setTuningInfoOnBox:at:withValue:` |
| Preferences | `getUserDefaults:`, `setUserDefaults:withValue:`, `resetUserDefault:`, `resetAllUserDefaults`, `getFeatureFlags:`, `setFeatureFlags:` |
| Network | `triggerWiFiCoreCapture:`, `setWifiEnabled:`, `disassociateCurrentNetwork`, `disassociateNetworkWithName:` |
| Software Update | `injectSWUpdateToHome:`, `setHomeUpdateState:`, `clearHomeSWUpdate`, `suScanForSoftwareUpdate` |

`homepod.debug.catalog` advertises the fixed operations and per-method ABI
availability. `homepod.debug.call` accepts an operation from that catalog and a
typed arguments object. There is no arbitrary selector invocation. Availability
requires SoundBoard.app and a loadable `SBSDebugInterface`; `homepod_debug` is
independent of top-cap patch selection. Host visibility comes from the VM's
HomePod identity, so this section does not appear for Apple TV or iPhone guests.
It remains visible but disabled while disconnected and explains unavailable
guest support.

Seven operations return asynchronous replies (five dictionaries, a feature-flag
array and Float volume). Reads have a three-second deadline; late replies are
ignored, and a timed-out XPC client is reopened for a later call. The remaining
22 native methods have no acknowledgement; the UI reports submission, without
claiming that SoundBoard applied the command. JSON replies preserve Foundation
collections and data, and decode native feature flags/default metadata where
available while retaining archived bytes.

The native wire adapters follow the donor implementations:

- `render:` uses animation and phase strings. All 25 feature names and 20 phase
  values recovered from the native enum tables appear in pickers. SoundBoard
  converts space-separated animation words to its feature spelling.
- `sendButtonCommand:` requires secure archived `HPButtonEvent` data. Typed
  fields produce the native archive; existing archives can be sent as base64.
  Buttons are Minus, Plus, Center and Cover (1–4). Actions are TouchMightHaveBegun,
  TapRegistered, HoldBegan, HoldEnded and TouchCancelled (1–5). Integer widths,
  tap counts, mach times and Boolean fields are checked before construction.
- `setLEDContents:` requires a nonempty replay array, not HID report bytes.
  Each frame contains `LedValuesTimestamp` (ascending UInt64) and
  `LedValuesData` (native NSData). B520's replay buffer contains 40 Float RGB
  triples, 480 bytes, including icon channels; it differs from the 245-byte
  packed MiniDisplay output report. The editor accepts exact base64, RGB triples
  or an RGB fill and converts to native data with geometry/length validation.
- Feature-flag dictionaries use `domain`, `feature`, `value`. User-default
  replies include secure `SBSDefaultInfo` archives, retained as base64 and
  additionally decoded for readable metadata. Software-update injection retains
  the native dictionary interface and documented keys in the editor.

`VPhoneDaemon/Tests/run-homepod-debug-tests.sh` exercises all 29 unique catalog
IDs against a frozen, independently recovered 24J361 method-encoding fixture,
object/Float replies, typed multi-argument invocation, strict Boolean versus
numeric types, native button archives (including UInt64.max mach time), replay
encoding/base64, missing ABI/unknown operation rejection and timeout behavior.
It also delivers a reply after the timeout and confirms the next request does
not inherit that stale result. The setup-journal harness explicitly rejects both
duplicate absent keys and keys appearing in both original and absent sets,
without writing preferences.
These host stubs verify marshaling; they do not establish SoundBoard XPC effects.
Detailed REA records, method encodings, enum tables and annotated cache
disassembly are retained under `.build/homepod-ui-research/`.

## User defaults browser (2026-10-23)

Device Controls → HomePod → User Defaults opens a sheet populated by the
guest's `getUserDefaults:` reply. The `info.decoded` SBSDefaultInfo metadata
defines each row's name, description, Boolean/integer/floating-point/string
editor, factory value, bounds and reinitialization hint. The native `mod`
field identifies stored overrides, including overrides equal to the factory
value. No host list of preference names is used; unknown types remain visible
and read-only. Search matches names and descriptions, and Overrides Only
filters on the native override state.

Edits remain drafts until Save. Numeric input is finite, checked against the
declared range, and integers preserve 64-bit precision. Set sends the native
string argument through `setUserDefaults:withValue:`; Reset removes a single
override through `resetUserDefault:`. Both setters report submission, so the
model rereads the defaults for up to six attempts before confirming success.
Unconfirmed writes retain their drafts and report the failed readback.
Refreshing preserves other drafts; closing with edits asks before discarding.
The HomePod section also offers Restart SoundBoard, using the existing
`services.kickstart` operation for `com.apple.SoundBoard` with kill and force.
No new guest operation or firmware patch is required.

Validation used the owner's Copy Reply export (150 defaults) and an isolated
simulated SoundBoard store. Tests cover all exported current values, string
Booleans, bounds, large integers, unsupported metadata, duplicate rejection,
search, draft retention, asynchronous save/reset, unconfirmed writes and
readback errors. A captured guest connection checks restart's service label,
kill/force arguments, disconnect guard and failure state. The actual SwiftUI
sheet was reviewed with all 150 exported rows: search, Boolean save/reset,
numeric range feedback, disabled invalid saves and discard confirmation.
These UI checks used the simulated store and did not modify guest defaults.
The full VPhone bundle build passed.

## Setup completion and inverse

`system-homepod-exp-setup_bypass` is a declared optional patch, gated to HomePod
26.5 and later and enabled only in the `homepod-mini` preset. HomePod Software
26.5 (23L471) has the same four SetupAssistant exports; the helper succeeded on
it on 2026-10-26 (see the binary patch comparison). Other presets explicitly
disable it, and explicit selection for another family is rejected. Its System
marker is `/usr/share/vphone/HomePodSetup.plist`, with `Enabled=true`.

The reveal procedure uses the donor's own setup flow:

1. Extract SoundBoardFramework and SetupAssistant from the 24J361 cache with
   Objective-C/stub repair. Their SHA-256 values are respectively
   `a352a2ba4025e714ca8b7208490991d821f63387aeb5268c7937974029246749` and
   `b214983fb007e97304bdb18299a9d71f4828f0563844d3c4134a92f82cb598d9`.
2. Follow `SBSetupController.deviceNeedsSetup` into
   `BYSetupAssistantNeedsToRun`. The internal function has an explicit
   AudioAccessory branch returning the inverse of `SetupDone`; this is not an
   assumption borrowed from iPhone setup.
3. Follow `SBSetupController._setBuddyComplete`: it writes `SetupDone` in
   `com.apple.purplebuddy`, current user/any host, synchronizes, and calls
   `BYSetupAssistantPrepareLaunchSentinel`. Independently follow
   `BYSetupAssistantHasCompletedInitialRun` to `SetupFinishedAllSteps`.
4. Trace stock sentinel preparation/clearing: it uses
   `sem_open`/`sem_unlink("purplebuddy.sentinel")`, a per-user semaphore, and
   publishes the native finished notification. SoundBoard's setup check either
   calls `runSetupGatedInitialization` immediately or waits for that notification.
   This supports either process launch ordering without invoking SoundBoard's
   private initialization manually.

Relevant REA records include
`ev_d061572b15543450b80e40a49a80a4a9fa7a2fb5ea9f98ca432783fc8675f0ba`
(AudioAccessory gate),
`ev_ee864420a79b7fcd589e2a5e715f737d1504258744899d0604f78f84875dc202`
(native completion), and
`ev_974490d0674d54c2e49d69fb08ea8dab75d760c323cb8d5574fd6b9037858fce`
(sentinel preparation). Unresolved decompiler stubs were correlated with original
cache disassembly. These are reconstructed control-flow observations, not source.

Data is encrypted during host installation. The installer instead stages
`vphone-homepod-setup` and a launchd job running as mobile (501). Before its
first write the helper saves exactly the original two preference values,
including which keys were absent, in
`/var/mobile/Library/Application Support/vphone/HomePodSetupOriginal.plist`
(0600 inside a 0700 directory). Repeated boots preserve the first inverse and
leave unrelated preferences alone. After synchronization it calls stock
sentinel preparation and requires `NeedsToRun=false` and
`HasCompletedInitialRun=true`. Native preparation publishes completion when
creating the sentinel. If the native gate was already complete immediately
before preparation, the helper replays the donor's exported
`BYSetupAssistantFinishedDarwinNotification` instead, avoiding duplicate
post-setup initialization for a newly created sentinel. It gracefully ends any remaining
mobile HPSetup session. Process enumeration is restricted to effective UID 501;
the full `/Applications/HPSetup.app/HPSetup` executable path is checked again
immediately before SIGTERM. A bounded disappearance/quiet check handles an app
launch already in flight. There is no escalation to SIGKILL. Missing process
APIs, unreadable owned-process identity, signal errors or a lingering setup
process make the helper fail and retry, retaining its original-key journal.
Status/error/date are written to
`HomePodSetupStatus.plist` in the same directory.

On deselection the marker is removed, and the helper restores just those two
keys, prepares the stock sentinel and verifies the restored native state before
deleting the journal. A failed synchronization or native verification keeps the
journal for retry. The runtime is installed for every HomePod environment update
even if vphoned and the bypass are deselected, so opt-out retains a rollback
path. With neither marker nor journal the helper exits without loading the
framework or modifying preferences. launchd retries unsuccessful runs with a
15-second throttle; successful runs exit.

This supplies local setup completion only. It does not create activation
tickets, Apple Account credentials, a HomeKit home, network pairing or identity.
`make -C VPhoneGuestComponents test-homepod-setup` passed journal creation,
idempotence, absent/existing-key restoration, unrelated edits, synchronization
failure retention, invalid/duplicate journal rejection and file-mode checks.
Native transition tests additionally model the donor's creation-only event and
verify one fresh-completion event, one existing-sentinel recovery event, no
opt-out publication, and no publication after failed verification. This
conditional relies on the analyzed retail HomePod path (`ForceNoBuddy=false`);
internal NonUI/unsupported overrides and concurrent external sentinel mutation
are outside that evidence. The tvOS arm64e helper builds and signs with system
SDK/framework dependencies.
All 35 owning Xcode catalog/selection tests passed, including preset roundtrips,
version/family gates and exclusion of Apple TV payloads.
The process harness additionally covers both launch orderings, an in-flight
launch, exact executable matching, identity changes before signaling, denied
identity lookup, enumeration failure, timeout without stronger signals and
refusal to operate as another user.

Xcode MCP builds of `vphone-vm` and the iOS-device `vphoned` target passed.
The aggregate `VPhone` scheme is absent from MCP's scheme list, so the finished
bundle was built with the documented `xcodebuild` fallback and passed both bundle
admission and `codesign --verify --deep --strict`. The initial offline build log is
`.build/homepod-ui-research/metal-debug-setup-bundle-build.log`; subsequent live
iteration logs are in `.build/homepod-ui-research/live-metal-debug-setup/`.

## Live validation scope

The completed tests cover signed bundle installation, real Metal drawable
presentation and window lifecycle, native XPC queries and representative
reversible writes, setup completion from an unconfigured baseline, late
HPSetup teardown, repeat boot and opt-out restoration. All 29 operations are
exposed and runtime ABI-available; all seven query operations return native
replies. The remaining write methods are submission-only native APIs. Their
physical Wi-Fi, tuning, update/HomeKit and Apple-service effects depend on guest
hardware and real provisioning; interface availability is not proof of those
effects. Audible tone/speech output and cloud Siri requests were not established.
TestLEDDraw's internal-content gate is documented rather than bypassed.

## Live investigation (2026-10-22)

The owner authorized bundle updates. Launchpad installed
`2.11.0-local.352ddbd3` with `--keep-default`, rebound only `homepod-mini`, and
updated its guest environment through the normal helper. An APFS clone of the
stopped VM disk and its original patch selection were saved under
`.build/homepod-ui-research/live-metal-debug-setup/` before mutation.

- The guest booted in five seconds. All 29 runtime method signatures are
  available. All seven reads returned native replies, including 150 default
  records and 2,917 feature flags. Volume changed from 0.53 to 0.58 and read
  back within Float precision, then was restored. A debug default changed and
  reset with readback. Tone 0 was submitted and stopped; audible output has not
  yet been established.
- The real HomePod Controls window shows the complete grouped operation menu,
  argument editors and animation/phase choices. Native volume input produced
  the white HUD through the Metal renderer. A native replay with 40 red RGB
  triples produced nineteen red HID pixels and lit icon channels; the real cap
  rendered red. Evidence includes `native-volume-metal.png` and
  `native-replay-red-metal.png` in that directory.
- Further native tracing establishes prerequisites that are now described in
  the catalog help: `render:` needs `HomePodBuddyConnection=1` and SoundBoard
  restart to create its debug Buddy controller. `sendLEDCommand:` requires the
  TestLEDDraw activity, created only on internal-content builds. Retail firmware
  may accept and ignore it; this is distinct from shader or wire-format failure.
  The native all-color grammar is `all 255 0 0` (channels divided by 256), and an
  empty command clears TestLEDDraw. Replay works independently of those gates.
  Its exact order is nineteen Siri RGB triples, two icon RGB triples, then
  nineteen AOD RGB triples. Times are deltas from the first timestamp; a single
  black frame replaces replay and ends it safely. Empty arrays are rejected
  because the native implementation indexes the first element unconditionally.
- `SoundBoardFinishedSetup=false` does not contradict configured startup. It
  is a legacy persisted diagnostic record, while functional activity/application
  gates use `SBSetupController.deviceNeedsSetup` → native SetupAssistant state.
  Already-completed startup intentionally skips the legacy controller and goes
  directly to post-setup initialization. The bounded source analysis and REA
  IDs are in `soundboard-finished-setup-findings.md` under the evidence directory's
  parent. Real HomeKit provisioning remains separate.
- Initial opt-out restored the two original values and removed the journal.
  A temporary mobile fixture then removed exactly the two completion keys and
  called stock sentinel preparation: native NeedsSetup became true and initial
  run completion false. Restarting SoundBoard brought HPSetup to the foreground
  and disabled Siri, establishing a real unconfigured baseline.
- **Late-start defect reproduced and corrected:** with that unconfigured baseline, the shipped helper was
  deliberately disabled at boot and then started after HPSetup was active.
  It reported success and changed the native predicates, but HPSetup remained
  foreground and Siri remained disabled. The flags alone do not prove successful
  late completion. Captured native logs show `setupdone` received,
  `_setupFinished` and `Doing post setup init`; that path alone does not dismiss
  HPSetup. A graceful termination of only the verified HPSetup process immediately
  removed the foreground activity and enabled Siri/Hey Siri. The helper now
  performs that exact teardown after verified completion and reports success
  only after disappearance. Bundle `2.11.0-local.a2a1cf33` passed the controlled
  late-start test: native needs-setup was false, initial-run completion true,
  HPSetup process count zero, and Siri/Hey Siri enabled. Its bundled and running
  helper hashes matched. Logs showed graceful HPSetup exit and released
  assertions. This first correction also exposed duplicate completion
  notifications; the conditional publication described above addresses that.
- Opt-out on the corrected helper restored both originally absent completion
  keys, removed the inverse journal and returned native NeedsSetup=true /
  CompletedInitialRun=false. A new boot ran HPSetup in the foreground with Siri
  disabled, confirming restoration rather than just marker removal.

The final bundle is `2.11.0-local.26745ac8`, installed through Launchpad and
bound only to `homepod-mini`; the library default and other VMs are unchanged.
The final helper SHA-256 is
`1e7ec8eb39b18055ab0e11d4aa2b719f964b86397d06cd59583baef48f103f8e`, verified
against bytes read back from the running guest. Final results:

- With HPSetup deliberately running before the helper, captured SoundBoard logs
  contain exactly one `setupdone`, one `_setupFinished`, and one `Doing post
  setup init`. HPSetup exited by SIGTERM, its assertions were invalidated, and
  native Siri/Hey Siri became enabled. The helper reported success only after
  the process disappeared.
- A fresh normal boot from native NeedsSetup=true / CompletedInitialRun=false
  completed successfully without HPSetup remaining. A second normal boot
  reported fresh success, preserved the original absent-key journal, and kept
  Siri/Hey Siri enabled with no foreground setup activity. These cover normal
  concurrent startup and deliberately late helper startup; only the latter
  has a controlled, observed process ordering.
- Native Siri `On` then `Thinking` produced changing multicolor inner-bank
  frames through SoundBoard → virtual MiniDisplay HID → guest WebSocket → the
  actual Metal cap. The live window redrew when zoomed and restored. It also
  redrew after minimize/restore; restoring required the owner because the UI
  automation tool could not reactivate a minimized `.bundle` through Launch
  Services. Native volume HUD and replay-color presentation were tested above.
- Restarting SoundBoard recovered debug replies. Restarting vphoned interrupted
  the request as expected, then display reports and queries resumed; the new
  display generation had zero rejected reports. The short disconnect's blank
  frame was not separately captured.
- The actual Controls menu lists all 29 operations. Its live volume reply and
  final Center/TapRegistered `coalesced:true` editor were inspected. Other
  hardware/service-dependent effects remain within the boundary above.
- Cleanup reset `HomePodBuddyConnection` to its stock false value, restarted
  SoundBoard, restored the original volume 0.53, and removed the temporary
  fixture job/output. Boot had removed the fixture binary/plist from `/var/tmp`.
  The final selection is the `homepod-mini` preset with empty override lists,
  setup helper enabled, native setup complete, and the final GUI VM running.
- No SoundBoard, vphoned or setup-helper crash report was present. Existing
  guest `ProxiedCrashCopier`, locationd and other service reports remain; the
  result is not a claim that all donor daemons run without faults.

Evidence is in `.build/homepod-ui-research/live-metal-debug-setup/`: final
bundle build log; `final-late-*`, `final-normal-*`, `final-repeat-*` and
`corrected-optout-*` native records; `final-native-siri-metal*.png`,
`final-native-metal-restored.png`, and Controls screenshots. The APFS disk clone
and original patch selection are retained there for local recovery. No
activation ticket, Apple Account or HomeKit identity was fabricated. The
fixture is not shipped in the bundle.
