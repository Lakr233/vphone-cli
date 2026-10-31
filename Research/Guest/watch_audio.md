# Apple Watch audio through virtio-snd

## Scope

This puts the existing virtio-snd output transport on an Apple Watch guest
(`Watch7,18`, N227b, watchOS 26.4 / 23T240). The host already attaches
`VZVirtioSoundDeviceConfiguration` to every VM, so nothing changes there. What a
watch lacked is a HAL plugin for the device and a VirtualAudio product that
initializes on a VM.

The standard `watchos` preset selects the single `filesystem-exp-watch_audio`
declaration. The separate experimental speaker preset has been removed.
Ringtones, text-tone previews and user-provided media audio were audible on
WatchAudioGraphTest. Existing watches require a restore to acquire these patches.

## Why this is a restore-image patch

Every other guest gets the plugin after its restore, from
`system-virtiosound-cfw-hal_plugin`. A watch cannot. Its System volume is
sealed and nothing writes it after the restore (that is the whole point of the
Restore Image set), so the plugin has to be inside the image before its trust
cache and seal are made. `cfw update-environment` therefore cannot add or
remove watch audio, and turning the patch on or off needs another restore.

## The three routing-gate bypasses

Native watch product selection enters VirtualAudio's generic playback handler,
and three separate refusals sit between that handler and a running speaker
route. They were brought up one at a time on 2026-10-28, and each one revealed
the next, which is why all three ship together and none is sufficient alone:

1. **Missing speaker protection.** `RoutingHandler_Playback_GenericConfig1`
   declines a route whose VAD has no speaker protection. Bypassing only this
   one, playback constructs the generic speaker graph, then fails
   `RoutingHandler_Playback_GenericConfig1.cpp:252 PRECONDITION FAILURE
   (std::logic_error)` immediately after the per-VAD volume description reports
   `SWVolumeMode:SoftwareHardwareMix`, and falls back to Null_Device.
2. **Volume-mode precondition.** That is the next decline, documented as Layer 4
   in `virtualaudio_speaker_route_throws.md`. With both declines gone, the later
   speaker-route serialization path logs `VA/HAL Speaker protection for VAD
   '[vdef]' is none` and then `Speaker Protection is not active on speaker
   route`; audiomxd aborts with EXC_CRASH/SIGABRT through libc++abi and
   crash-loops (three PIDs in a 12-second capture), and an AVAudioPlayer probe
   cannot complete within 30 seconds while the service restarts.
3. **Fault-logged inactive-protection termination.** Retargeting that one
   terminating call in the speaker-route walker is what makes the route survive.

Each is matched semantically, not by offset. The speaker-protection gate and the
volume-mode precondition use the existing source-file and log-string anchors,
the latter also keying on the 33-bit volume-mode packing-mask comparison. The
inactive-protection bypass uses the walker locator and the exact fault-string
call-flow matcher to recover the terminating call and its own function's
epilogue. Each recognises its own output on a second run for idempotence, and
each refuses the patch when its anchor is absent.

### Validated state

On WatchAudioGraphTest, freshly restored, the live arm64e executable text
differs from stock 23T240 at exactly twelve bytes, three instructions:

- playback speaker-protection decline: 0x2199d4–0x2199d7, branching to 0x219750;
- playback volume-mode decline: 0x21aa44–0x21aa47, branching to 0x219b20;
- inactive-protection terminating call: 0x2a7794–0x2a7797, now branching to the
  walker's epilogue at 0x2a746c. The original callee stub 0x405a10 resolves
  through the indirect symbol table to `__ZSt9terminatev`.

No other VirtualAudio executable-code byte changed. Full graph-plist comparison confirms only
the eight speaker chainTypes differ from stock; tuning references and volume
commands remain unchanged.

What stays disabled: the five other walker exception sites, the mute exception
bypass, the play-and-record gate, the raw-speaker tuning rewrite and the
microphone fixes.

### Runtime evidence

AVAudioPlayer preparation and playback both succeeded for the built-in
NanoRingtone3.caf. AVAudioSession selected Speaker / PuffinOutput and the HAL
entered Running; repeated stop/start playback also succeeded, and audiomxd
stayed at PID 110 before, after and across it. After unmuting the Mac, the owner
explicitly confirmed the replay was audible. This validates ringtone playback
through the virtual output, but not every audio session category, and not
long-duration timing. S11 and its pairing were not changed.

Stock-binary regression tests cover dry run, single-instruction scope,
preservation of the other throw sites, idempotence and refusal when the fatal
anchor is absent. 103 focused tests passed, with full bundle build and admission.

On 2026-10-31 a new VM restored from the latest bundle (the shipped `watchos`
payload, not the bring-up test image) produced audible system sounds: the
charging chime and ringtones. A paired control restore with
`filesystem-exp-watch_audio` blocked was silent (recorded under Testing below),
which attributes the speaker route to the payload. Playback-category media
(music, text tones and notification tones) still depends on the unimplemented
MediaExperience power-budget fix described below.

## Speaker graph construction

The payload installs the plugin and rewrites the eight `speaker_*` entries in
`AID4017/VAD/graph_configurations_halspp.plist` from `clhs` to `dflt`.
The existing graphs, AudioUnit settings and microphone entries stay unchanged.
The current payload also applies the three VirtualAudio routing-gate bypasses
described above.

On 2026-10-28, the minimal-payload S11 reproduced the missing dependency:
VirtualAudio creates `speaker_general` as `DSPGraphChain_HAL_SpeakerProtection`,
throws `Could not lock weak ptr (:60)`, rejects the connected `PuffinOutput`
route and falls back to `Null_Device`. The live graph file matched stock bytes.
The earlier working image also carried the generic speaker-chain rewrite;
native product 4017 alone does not make physical speaker protection usable.

The restore-image installer now reuses the existing graph patch helper on
HALSPP configuration files through confined file operations before sealing.
A missing HALSPP configuration fails the selected install. All broader
VirtualAudio instruction patches and the raw-speaker tuning rewrite remain off.
Graph-only runtime validation on 2026-10-28: WatchAudioGraphTest was restored.
All eight live speaker entries are `dflt` and ProductIDOverride is 4017. A
synchronized audiomxd capture around an
AVAudioPlayer playing NanoRingtone3.caf shows successful generic
`speaker_general` graph construction, with no weak-pointer exception. The
next blocker is `RoutingHandler_Playback_GenericConfig1.cpp:223 HAL Speaker
Protection is missing. Failing route`, followed by Null_Device fallback.
Thus the graph rewrite is necessary but not sufficient: native watch product
selection still enters the generic playback handler, which is what the three
routing-gate bypasses above address. No executable patch was enabled in this
test.

Trimming in this test run removed update assets, watch faces and some linguistic
data, not the audio tunings. That is a limitation of the test setup, not of the
payload; S11 and its pairing were not changed.

## Product selection

Read from the 23T240 arm64e `VirtualAudio` slice; addresses are image-relative.
The watch executable is universal arm64_32 + arm64e and the research VM runs the
arm64e slice.

- `0x1cab94` caches what the product resolver at `0x1cac08` answers. The
  resolver reads integer `ProductIDOverride` in `com.apple.audio.virtualaudio`
  first (`0x1cac3c`–`0x1cac54`) and takes it directly.
- With no override it calls the hardware product lookup, which asks
  `MGGetProductType`. That answers nothing a watch VM knows, so at
  `0x1cad28`–`0x1cad50` it falls back to `DeviceClassNumber` and indexes the
  table at `0x409050`: `[195, 0, 196, 199, 0, 198]`. This watch takes the last
  entry, **198**.
- `0x1cd398` caches the HALSPP-all-routes predicate, which classifies the
  resolved product through `0x1cd41c` and answers true for classification 2 or
  3. Acoustic products 4013–4017 classify as 3 unconditionally; anything else
  consults NanoMediaUI/SpeakerPlayback and DeviceSupportsWatchSpeakerPlayback.
- The routing constructor calls that predicate at `0x158078`. True selects
  `graph_configurations_halspp.plist`; false selects
  `graph_configurations.plist`.

198 therefore asks for `graph_configurations.plist`, which no watch ships: the
guest has only `Library/Audio/Tunings/AID4017/VAD/graph_configurations_halspp.plist`.
`DSPGraphConfig_Utilities` throws `Could not construct`, initialization ends
with `VA Init Status: 1`, `HALDeviceManager` admits only `Null_Device` under its
`AllowOnlyNull` filter, and `AVAudioSession` reports no output routes, zero
channels and a zero sample rate.

**4017** is one of the acoustic products that classify without consulting
hardware, so the route reads the HALSPP graph the watch already has. Renaming
the graph would not do: it would bypass the matching HALSPP settings and still
leave the product wrong.

With 4017 stored and nothing else changed (no sealed file and no binary
modified), initialization reports `PlugIn initialized ? 2` and `VA Init Status:
0`, no missing-graph exception, and `HALDeviceManager` admits `PuffinOutput`,
creates its `PhysicalDevice` and publishes the routable `pspk` speaker port.
`AVAudioSession` then exposes Speaker/`PuffinOutput` at 44100 Hz, one channel.
The early `AllowOnlyNull` messages still appear: that filter is a transient
restriction during initialization, not a permanent VM-product blacklist, so no
filter bypass is needed.

Both `VPGuestProductID` in the plugin and `GuestVirtualAudioProduct` in vphoned
answer 4017 for `Watch7,18`, the way they answer 4 for `AudioAccessory5,1`.
Whichever starts first, audiomxd finds the value: the plugin sets it in process
on every launch, and vphoned stores it at startup so no launch ordering is
relied on. An explicit `VPhoneVirtIOSoundProductID` still wins, and 0 there
leaves VirtualAudio to itself.

Only `Watch7,18` is tested. Another watch model keeps native selection rather
than borrowing an acoustic product whose tunings it may not carry.

## Routing identity

The output's UID is `PuffinOutput`, which is the only name VirtualAudio's device
factory builds a speaker port for. A watch claims it the way a HomePod does, and
in fact uses it natively even with no override stored.

Input keeps a UID of ours. Record routes ask the port for the product's
microphone sub-ports, which the virtual device does not present, so claiming
`Digital Mic` on a watch would offer a microphone array that is not there.
Watch microphone routing is outside this output port's scope.

Neither of HomePod's two driver-side quirks applies. The `mode/glob/0` raw
custom property and the withheld 44.1 kHz physical format are both gated on
`AudioAccessory5,1` exactly. A watch's HALSPP route reports 44100 Hz and does
not read `mode/glob/0`; the `who?` throw at `RoutingHandlerUtilities_Aspen.cpp:385`
that forced the HomePod property does not appear in watch logs.

## What is established, and what is not

Established on a fresh restore of the current payload: the watch guest
initializes VirtualAudio with the native product, publishes the speaker port,
and the owner hears the charging chime and ringtones at the host; a control
restore with the payload blocked is silent. Earlier, broader-patched images
also published an AirPlay port and reached the host with ordinary playback; an
earlier paired test confirmed an AirPlay output, which is historical evidence,
not fresh AirPlay validation of this payload.

Not established here:

- The earlier audible image carried five VirtualAudio executable fixes and the
  graph-chain rewrite. The graph-only revision was tested separately as
  described above and still fails the speaker-protection gate; initialization
  and a published port do not prove route activation.
- `MediaExperience` has a separate problem on the local-speaker media path.
  `CMSUtility_DoesSessionNeedAudioBudget` has Apple's own virtual-device exit,
  but `CMSMDeviceState_UpdateDeviceClass` sets that flag from `MGGetProductType`
  comparisons against two legacy tokens and never asks MobileGestalt
  `IsVirtualDevice`, so a watch VM takes the physical path:
  `PowerManager_InitializePPM` finds no `ApplePPM` service (`ioreg -r -c
  ApplePPM -l` is empty, logs say `PPM Error:No matching driver found`), and
  `PowerManager_RequestBudgetForMediaPPM` returns -16982, which surfaces as
  `cmsSetIsPlaying: ... unable to take power budget` and AudioQueue 2003329396.
  This affects Playback-category media on the local speaker: music, text tones
  and notification tones. The 2026-10-30 Settings text-tone capture establishes
  that budget failure; direct AVAudioPlayer ringtone playback does not exercise
  it, and the system sounds that do work (the charging chime and ringtones)
  take a path that needs no media budget. No MediaExperience patch is currently
  included.
- Long-duration clock accuracy, every session category, watch microphone
  routing and AirPlay lifetime are untested.

## Comparison with audioOS

Here audioOS means the existing HomePod mini (`AudioAccessory5,1`) support,
validated on HomePod Software 27.0. The watch evidence is from `Watch7,18`
on watchOS 26.4; this is not a claim about every model or release.

| Area | audioOS / HomePod mini | watchOS addition |
| --- | --- | --- |
| Transport | Existing virtio-snd, guest PCM to the host output sink | Same driver, converter, ring, clock and host sink; no new transport |
| Installation | `system-virtiosound-cfw-hal_plugin`, applied after restore by `cfw install` / environment update | `filesystem-exp-watch_audio`, selected by `watchos`, installed before the system image is sealed |
| Changing selection | Added driver can be removed by the guest environment update | Requires another restore to add or remove |
| Platform | Shared iOS driver retargeted to tvOS; bundle metadata `AppleTVOS` | Same retargeting procedure to watchOS; bundle metadata `WatchOS` |
| Audio product | Override 4 selects native B520/B238 routing | Override 4017 selects the native watch HALSPP graph; the VM-derived 198 asks for a missing graph |
| Preference ordering | Plugin sets the override in process; vphoned persists it before subsequent audio-service launches | Same mechanism, including the explicit override and zero opt-out |
| Device identity | `PuffinOutput`; input retains a virtual UID | Same, restricted to the supported watch model |
| Processing mode | Driver implements the native `mode/glob/0` property required by B238 routing | No additional mode property; the watch route has not required it |
| Physical rate | Output restricted to 48 kHz to avoid native DSP buffer overruns; 44.1 kHz sources are converted | Keeps the existing alternate-rate support; the observed watch speaker route is 44.1 kHz, mono |
| Apple audio code | Native product route; iPhone VirtualAudio instruction/tuning fixes disabled | Native product route; generic DSP speaker chain and three VirtualAudio routing-gate bypasses; no MediaExperience patch |
| Global identity | Original VM MobileGestalt token retained | Same; only VirtualAudio's product preference changes |
| Playback evidence | Ordinary AVAudioPlayer playback of 48/44.1 kHz sources, repeated cold boots, nonzero host PCM and listening confirmation | Native-product initialization and audible system sounds/ringtones reported; local-speaker Playback sessions still fail the MediaExperience power-budget path |
| Coverage limits | Microphone, Siri, AirPlay and long-duration timing not validated | Microphone and long-duration timing not validated; an earlier AirPlay output was observed, but lifetime is untested; a 2026-10-31 fresh restore of the shipped payload produced audible system sounds (charging, ringtone) |

The watch addition reuses the HomePod approach to native routing and driver
compatibility. It needs a different installation stage and product ID, and does
not inherit HomePod's mode-property or physical-rate workarounds. Its current
playback coverage is narrower. The missing ApplePPM budget path is documented
above and remains outside this patch.

## Testing

Build validation (2026-10-27): the `VPhone` Debug bundle builds and passes
bundle admission. The catalogue, Mach-O platform and cryptex file-operation
suites pass 46 tests; the version, selection, declaration, plan and gate suites
pass another 32. The file-operation coverage verifies that even an unrestricted
gate does not record watch audio for an iPhone, Apple TV, unknown or missing
manifest. These checks do not replace the fresh, minimal-payload restore
validation described above.

```zsh
vphone-cli vm create WatchAudioTest --device Watch7,18 --preset watchos
```

Supply the same firmware inputs the watch normally takes. On an existing record
the preset can also be reached with
`fw set-patches <vm> --preset watchos --allow filesystem-exp-watch_audio`,
which still needs a restore to take effect.

Prepare a separate VM rather than changing a paired watch in place: the payload
cannot be added or removed without another restore, and restoring replaces the
pairing.

Then check, in order:

1. The kernel exposes `AppleVirtIOSound` and its user client opens.
2. audiomxd loads the watchOS-marked plugin with no symbol or selector failure.
3. VirtualAudio reports `VA Init Status: 0` and publishes `PuffinOutput` with a
   `pspk` port. Log the ProductID rather than guessing at an override.
4. Charging sounds and ringtones are audible at the host; test media and text
   tones separately and record any MediaExperience budget failure.
5. For a negative control, create a separate VM with
   `--preset watchos --block filesystem-exp-watch_audio` and confirm that its
   restored system omits the plugin. The standard `watchos` preset includes it.

### Negative control (2026-10-31)

A separate VM restored with `--preset watchos --block
filesystem-exp-watch_audio`, same Watch7,18 / watchOS 26.4 (23T240), produced
no audio. The live `/System/Library/Audio/Plug-Ins/HAL` directory held no
`VPhoneVirtIOSound.driver`, and `AVAudioSession.sharedInstance()` reported an
empty output-route list with zero sample rate and zero channels. AVAudioPlayer
of the built-in `NanoRingtone3.caf` returned false from both `prepareToPlay()`
and `play()`, and after 1.5 seconds `isPlaying()` was still false with
`currentTime()` 0. This tests removal of the whole payload, not the necessity
of each graph or instruction change, and pairs with the fresh-restore
confirmation above to attribute the speaker route to the payload.
