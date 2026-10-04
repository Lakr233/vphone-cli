# VirtualAudio speaker-route throws — the patch that made audiomxd survive

`system-virtualaudio-cfw-speaker_route_throws` (declared in
`FirmwareGuestSystemPatchSet`, applied by `cfw install` and
`cfw update-environment` through `patchMachO`, verb `cfw patch-virtualaudio`).

## What the walker is

`VPhoneVirtIOSoundDriver`'s masquerade as `PuffinOutput` (§5 of
`virtio_sound.md`) publishes the guest's only `pspk` speaker port, which is
what makes the default route reach the virtio device at all. The price is
that VirtualAudio's speaker-route walker — the function that applies speaker
protection and the DSP chain when a property write touches the route, entered
from MediaExperience's VAD serialization listener on every launch and every
route change — meets a speaker whose protection metadata is not what a real
codec reports, and answers each surprise by killing the process:

| Site (iPadOS 26.6.2 / iOS 27) | Exception |
| --- | --- |
| 0x16ca74 / 0x172ffc | `runtime_error("No default VAD present")` |
| 0x16cf6c / 0x173580 | `runtime_error("Could not construct")` — behind the routing-mutex assertion |
| 0x16cfa8 / 0x1735bc | `runtime_error("Could not construct")` — the second one |
| 0x16d0b4 / 0x1736c4 | `runtime_error("Unexpected HAL speaker protection … *VP* speaker protection")` |
| 0x16d1d0 / — | `logic_error("Precondition failure.")` |
| 0x16d148 / 0x173828 | no exception — a direct `bl std::terminate` after the `Speaker Protection is not active on speaker route` fault log |

The five throws cross the AudioServerPlugIn C boundary, reach
`std::terminate`, and abort audiomxd; the saved serialization state replays
the same write into every launch, so one abort is a crash loop. The terminate
needs no exception at all. None of the six sites is reachable on real
hardware, where the built-in speaker is a codec this code grew up with.

## What the patch does

Every site's first instruction is replaced with a branch to the function's
own epilogue, so each fatal condition degrades to "apply nothing and
return". The diagnostic logs stay. Sites are found by shape, never by
offset:

* the walker is anchored on the `No default VAD present` string — exactly one
  adrp+add materialises the bare message (the exception constructor's x1);
  a second reference to a longer format string containing the message must
  corroborate it above the throw;
* the throw blocks are `mov w0, #<size>` + `bl ___cxa_allocate_exception` +
  a message load into x1 + a constructor call, closed by an unconditional
  branch or a `brk` (iOS 26 builds end with `bl ___cxa_throw` + branch, iOS
  27 tail-calls the throw and one block ends in `brk #1` — the scan takes
  both);
* the terminate is anchored on `Speaker Protection is not active on speaker
  route`: the fault logger's back-to-back `bl` run (the log, its releases)
  ends in the terminate, whose successor is never a call;
* the epilogue is the stack-guarded pop run after the anchor's throw (iOS
  26) or the plain frame restore (iOS 27 builds the walker without the
  protector) — shape-checked either way.

Idempotent: a re-run recognises its own branches (including the terminate
site, whose patched shape ends the `bl` run one call early) and writes
nothing. Verified against the real iPadOS 26.6.2 and iOS 27.0 binaries in
`~/.vphone/va-analysis/`: 6 sites and 5 sites respectively, byte-exact
re-runs.

## The bundle seal

`patchMachO` re-signs the Mach-O it replaces, but `VirtualAudio.plugin` is a
bundle: the outer `_CodeSignature/CodeResources` seals the directory, and a
guest with `codeSigningMonitor == 2` kills audiomxd on load when the seal
still names the old binary. The stage re-seals the bundle with
`codesign -f -s -` after the patch (`sealGuestBundle`); the same call covers
the restore-from-backup path.

## Verified in the guest

With the patch installed (`cfw update-environment`), ipad-pro-13 boots
through the serialization replay that used to be a crash loop, audiomxd
stays up, VirtualAudio initializes (`we have found the default VAD ID: 65`),
the pspk port publishes, and — reported by the user — **the boot charge
chime is audible on the Mac**. First boot may still see one audiomxd abort
before the state settles; the relaunch survives.

## The gap that followed, and the clock seed that closed it

With the walker silenced, playback still failed once the vdef's aggregate
owned the device: `HALS_IOContext_Legacy_Impl::IOWorkLoop: could not
establish a timeline after waiting 5000000 microseconds`, then
`AudioDeviceStart (err 'nope')` — the aggregate ran our device for three
seconds, never accepted its clock, and aborted the start. (The boot charge
chime had worked because it plays before the vdef takes the default device,
on a direct start.)

The cause was the plugin's zero-timestamp seed. `getZeroTimestampBlock`
advanced `(sampleTime, hostTime)` a whole period at a time but bumped the
seed only at re-anchor, so the HAL read every advancing pair as the same
frozen timestamp and never established the timeline. The seed now changes
whenever the reported pair does (`VPClockZeroTimestamp`). With that one
change, ringtone sessions play through the aggregate with no `nope`, no
timeline failure and no crash (`~/.vphone/va-analysis/clockfix.json`), and
the system route reads `PVMSetCurrentState [Audio/Video, Default, Speaker,
PuffinOutput]`.

**Corrected 2026-10-03 (night).** The seed was not the cause. AudioServerDriver
clears a device's I/O blocks at every stop, so the plugin's zero-timestamp
block existed for the first start only: the chime was that first start, the
ringtone the second. A seed that moves with every period is itself a fault —
the HAL re-anchors its timeline on each one. Both are fixed in the plugin; see
`virtio_sound.md` §6.

## Where the audio path stands after the seed fix (open work)

With the walker silenced and the clock seed advancing, ringtone sessions play
end to end **when their rate is 48000** — the vdef's aggregate then carries our
device (`AggDev 2: phys devs {PuffinOutput}`) and the Mac plays it; the boot
charge chime, a direct 48k start, was audible to the user. Two further facts,
both from `~/.vphone/va-analysis/vol4.json`:

1. **44100 sessions exclude the device.** A RingtonePreview session runs its
   AudioQueue at 44100; the vdef then builds its aggregate around the
   **Null_Device** (`AggDev 8, sr: 44100`) because our device advertises
   `samplingRates = @[@(48000)]` only, and the preview is silent. A dual-rate
   build (advertise 44100, resample in `writeMixBlock`, rate-aware clock) was
   written and built but not yet validated: the volume-control experiment it
   shipped with (below) removed the boot chime, so the plugin was rolled back
   to the last confirmed-audible state (the seed fix alone) pending a clean
   test. The dual-rate and resampler code exists in the session notes, not in
   the tree.
2. **The pspk route runs in HardwareOnly volume mode.** VirtualAudio fails
   `OutputVolumeControl_HAL_Common.cpp:1390 "Volume Mode is HardwareOnly but
   physical device does not support HW volume"` and every volume set on the
   vdef errors. Adding `ASDLevelControl`/`ASDBooleanControl` (the macOS
   AppleVirtIOSound plugin's own volume API, confirmed present in the iOS
   AudioServerDriver framework) is the right shape — but the first attempt
   also broke the boot chime, so it needs re-introducing on its own, with the
   element/scope choices checked against what the pspk volume queries expect.

## Handoff state (2026-10-03, session 3 — the mute dispatch)

**Machine**: ipad-pro-13 on the v5 build (controls via explicit-class
initializers, everything else as before); VirtualAudio carries the 6-site
`speaker_route_throws` patch; `ProductIDOverride=198` and
`VPhoneVirtIOSoundDeviceUID=PuffinOutput` prefs set. audiomxd stable, no
crashes. **The boot charge chime is still silent** — the regression this
session chased to ground.

**Regression history (fix 1 of the previous handoff, in three acts):**

1. *Factory initializers are poison on the guest ASD.* The
   `muteControlWithValue:…` / `volumeControlWithDecibelValue:…` factories are
   state-dependent: runs where they returned real controls still failed the
   route unmute with 'what', and later runs returned the raw FourCharCode
   `'togl'` (0x746f676c) as an `id`, which release-faulted in the caller's
   epilogue and crash-looped audiomxd (`audiomxd-*.ips`). The explicit-class
   initializers — `initWithValue:isSettable:forElement:inScope:withPlugin:
   andObjectClassID:` and the decibel twin — construct deterministically;
   a guest-side reflection probe confirmed both return real ASD controls
   that register under exactly the class ID passed ('mute' 0x6d757465,
   'vlme', 'dsrc' — read back through `objectClass` and
   `isKindOfAudioClass:` in v5's init log). v4 (this construction) is the
   first controls build audiomxd survives cleanly: runs=1, pspk port
   published, endpoint typed Speaker, volume range answers.
2. *Controls registering correctly is still not enough.* v5 proved the
   registration and still: `selector "mute"` fails 'what' at (outp, 0),
   ProcessRoute throws its CAException, the aggregate lands on Null_Device,
   no `PVMSetCurrentState`, no chime.
3. *Root cause, by disassembly.* AudioServerDriver's resident `__TEXT`
   (535968 bytes) was paged out of a guest process that dlopens it
   (`asdtext-guest.m`), turned into a self-contained MH_OBJECT host-side
   (`patch-macho.c`: `__TEXT` fileoff→0, vmaddrs rebased by the same delta,
   header trimmed to the one segment), and disassembled with
   `llvm-objdump` (`asd.dis`, 104362 lines) after a guest reflection probe
   (`asdimp-guest.m`) reported the PAC-masked IMP offsets of every method of
   interest relative to `dli_fbase`. Finding: the FourCharCode `'mute'`
   occurs in exactly two comparisons in the whole image (0x3b8f0, 0x3bc10),
   both inside ASDBooleanControl's control-level code; ASDAudioDevice's
   device-level dispatch — the binary-search selector trees behind its
   `hasProperty:` (0x3528) / `getProperty:` (0x1cf4) — has no 'mute' case
   at all. (Eight other `#0x6d75` materializations are `'muid'`, ModelUID —
   low half 0x6964.) macOS's ASD dispatches device-level mute; iOS's
   doesn't, so no plugin device can inherit it, and VirtualAudio's
   Device_HAL_Common unmute-then-read-back on the device object gets 'what'.

**v6 fix (built this session, install pending): `VPVirtIOSoundDevice` answers
device-level mute itself.** The ASD property plumbing the driver's C ops call
into is declared on ASDObject in our header and overridden on the device:
`hasProperty:`, `isPropertySettable:`,
`dataSizeForProperty:withQualifierSize:andQualifierData:`,
`getProperty:withQualifierSize:qualifierData:dataSize:andData:forClient:`,
`setProperty:…` (signatures from the arm64e argument layout of
ASDAudioDevice's own implementations: x2 = address, x3/x4 = qualifier,
x5 = in/out `UInt32 *dataSize`, x6 = data, x7 = client). A
`VPIsDeviceMuteAddress` predicate (selector 'mute' — the iPhoneOS SDK headers
omit `kAudioDevicePropertyMute`, so it is `0x6d757465` beside the 'ispk'
constant — scope glob or outp, element 0/main) routes to a shadow
`UInt32 _muteState`; sets forward to the registered `ASDBooleanControl`
through `setValue:` only — `booleanValue` does not exist on the class (the
getter is `value`), and calling it would be an unrecognized selector inside
audiomxd. Everything else passes to `super`.

**Verification for v6 — run, and the override did not change the outcome.**
v6 deployed (guest plugin sha byte-identical to the build), audiomxd stable,
device 37 `PuffinOutput` activates — but `Device_HAL_Common.mm:290 Set mute
value of 0 … (selector kAudioDevicePropertyMute; 'outp'; 0)` still fails
`'what'` (:307), `RoutingManager.cpp:3515 CAException … ProcessRoute: 'what'`
still throws, and the aggregate is still built `master = "Null_Device"`. Two
new facts from the same capture (`v6-restart3.json`, pid-filtered — note
vphoned's `logs.syslog` `process` filter silently drops the plugin's
`com.vphone.audio` lines; only the unfiltered query returns them, and its
4000-line default truncates mid-restart, so use unfiltered + `max_lines`
5000):

1. The rejection is server-side and logged:
   `HALS_UCPlugIn.cpp:1190 HALS_UCPlugIn::ObjectSetPropertyData: failed:
   [<private>/<private>/0], Error: 2003329396` — the HAL *server's*
   plugin-bridge rejects the device-level mute before (or while) consulting
   the driver ops.
2. Immediately after, the **control** path succeeds:
   `HALS_PlugInControl::SetPropertyData: control id 40, property address
   ['bcvl', 'glob', 0], owning device UID PuffinOutput, control type external
   driver, control scope 'outp', control element 0, mute: 0.000000`. The
   server knows our ASDBooleanControl is a mute control (it labels the value
   "mute:"), sets its 'bcvl' fine — only the device-level selector dies.

So the open question is whether the driver ops ever reach the overridden ObjC
methods for a device-level selector. The follow-up build (in flight) adds
`prop-probe` logging: the first 40 `hasProperty:` selectors seen, a log on
every mute-address hit in each of the five overrides, and an init-time
`class_getInstanceMethod` presence check. Outcomes and what they mean:

* probes fire with 'mute' → the 'what' is generated above the driver (HALS
  pre-validation); the plugin cannot fix it from ObjC, and the fix moves to
  patching VirtualAudio's mute handling (a new site in the existing
  `speaker_route_throws` patch family).
* probes fire but 'mute' never arrives → same conclusion: the server never
  forwards the selector.
* no probes at all → the ASD C-op layer answers device-level properties
  without calling these ObjC methods; the subclass-override approach is
  wrong on iOS and the candidate becomes swizzling ASDAudioDevice's methods
  at plugin init (before any device registers) or the VirtualAudio patch.

Guest probe leftovers to sweep: `/var/mobile/asdimp*`, `asdtext*`,
`asd-text.bin`.

Probe-infrastructure notes for whoever extends this: vphoned's
`files.read` with `binary:true` truncates at 524288 bytes (the needed
functions all sit below 0x80000); `processes.kill` refuses without
`{"pid":N,"force":true}`; an unentitled launchd daemon sees zero HAL
devices, so client-side probing is a dead end — the reflection/memory-dump
probe running *inside* a process that has the framework loaded is the
working shape. Artifacts in `/tmp/va-analysis/` (asd-patched.bin, asd.dis,
the three probe sources, patch-macho.c) and captures `v4-restart2.json`,
`v5-restart.json`.

## The probe settled it: the server never forwards 'mute' (2026-10-03, session 4)

The probe build (v6+probe) appended a `VPProbeLog` sink to
`/var/mobile/vpprobe.log` — vphoned's syslog capture is a live tail that
swallows early-restart lines and its `process` filter drops the plugin's
subsystem outright, so a file was the only reliable channel. The result
(`probe.b64`, pulled before the sweep): **60 `hasProperty:` calls reached the
override, not one of them 'mute'** — the overrides dispatch for every other
selector, so the third outcome above is ruled out and the first is the
answer: `HALS_UCPlugIn.cpp:1190` pre-validates the device-level set against
the plugin's driver-op table, finds no 'mute' entry, and answers 'what'
(2003329396) without ever consulting the driver. No plugin-side fix exists on
iOS; the fix is the VirtualAudio binary below. The overrides stay in the
plugin as macOS-parity dispatch (the doc comment in
`VPVirtIOSoundPlugin.m` says so); the probe sink itself is gone.

## `system-virtualaudio-cfw-mute_set_throw` — the mute-set throw

With the 'what' unavoidable, the remaining lever is what VirtualAudio does
with it. `Device_HAL_Common`'s set wrapper logs FAIL (`:307`) and EXCEPTION
(`:308`) then **throws `CAException("Unable to set property data.")`** out of
the property callback; `RoutingManager.cpp:3515` catches it and abandons the
route — the aggregate's master stays `Null_Device`, no
`PVMSetCurrentState`, no chime. Every caller of the wrapper ignores its
return value, so turning the throw into a quiet return through the wrapper's
epilogue is safe: the diagnostics still log, the route proceeds as if the
mute had held (and the control-level 'bcvl' set the server already performed
stands).

The patch (`patchMuteSet` in the same `CustomFirmwareVirtualAudio.swift`,
verb `cfw patch-virtualaudio-mute`, both install paths riding one
`patchMachO` call with `patch-virtualaudio` — staging restarts from the
pristine `.bak`, so two calls would not compose):

* **Anchor**: the log format `Set mute value of %u on HAL device`
  (stable prefix across both builds), found as a cstring in a real string
  section and referenced by exactly one adrp+add in `__text` — inside the
  wrapper's selector dispatch. The wrapper is the enclosing
  pacibsp-to-pacibsp function.
* **Site**: within the wrapper, the CAException throw block. A CAException
  carries no message string, so the walker patch's `isThrowBlock` shape
  (x1 message load + constructor call) does not match it; the CAException
  shape is: the `___cxa_allocate_exception` call, then `str xN, [x0]`
  (vtable) and `str wN, [x0, #imm]` (status) stored into the allocated
  object, then a call after the store (`___cxa_throw`), closed by the `brk`
  the compiler plants after a call it knows never returns. On both builds
  that block is **17 instructions from the allocation call to the `brk`** —
  the scan budget (`isCAExceptionThrowBlock`) is 32 for exactly this reason;
  16 (the runtime_error budget) exits one instruction before the terminator
  and reports the block absent.
* **Discriminator**: iOS 27's wrapper holds a *second* CAException — the
  deactivated-device throw (`'!obj'`, log "Device has been deactivated.").
  What tells them apart is the EXCEPTION log window: the target throw has an
  adrp+add forming a cstring **containing** `Unable to set property data.`
  within 0x40 bytes above the site (the actual gap is 7 instructions on both
  builds); the deactivated throw's window references its own string. On
  26.6.2 the deactivated throw does not exist, and exactly one candidate
  survives on each build.
* **Epilogue**: the wrapper's single `retab`, walked back to its entry by the
  same guarded-canary chain logic as the walker patch (`epilogueEntry` is
  shared) — except the retab cannot be searched forwards from the throw,
  because the mute-set throw sits *below* the epilogue (the wrapper's
  success path returns before the failure paths); it is enumerated within the
  function's own bounds instead.
* **Write**: `ARM64Encoder.encodeB` from the throw site (the `mov w0, #0x10`
  sizing the exception) to the epilogue entry. Backwards branches, −0x558
  (26.6.2) and −0x32c (iOS 27).

Verified against the real binaries (`/tmp/va-analysis/mute-verify/`):
exactly one site and one epilogue each (26.6.2: throw 0xee224 → epilogue
0xedfcc, wrapper 0xeda04–0xee2e4; iOS 27: throw 0x111ac8 → 0x11179c,
wrapper 0x111168–0x111b8c), dry-run writes nothing, second apply is
byte-identical (`cmp`), and both verbs compose on one copy (`patch-virtualaudio`
then `patch-virtualaudio-mute`, re-run idempotent).

The mute-set wrapper is a different function from the walker: the two
patches are siblings over the same binary, not one site list — the walker's
six sites (table above) all live in the speaker-protection walk, the
mute-set throw in Device_HAL_Common's set wrapper, reached after them on the
same route establishment.

## The gate is the category: RingtonePreview drops the device from discovery (2026-10-03, session 5)

The v7 build (dual-rate stream, speaker controls, device-level mute/nsrt
dispatch) is audible for one flow and silent for another, and the difference
is not the device, the rate, or the mute/nsrt noise — it is the **audio
category** the session runs under.

**The failing flow** (tone tap in Settings ▸ Ringtone; captures
`nr1-tone2.json`, `nr2-tone.json` in `/tmp/va-analysis/`):

1. mediaserverd logs the session going active, `[NonMixable]`, with
   category **'crnp'** (RingtonePreview) in the Parsed RouteConfiguration.
2. Within a second every discovery client *removes* the device:
   `Output devices changed - PuffinOutput` from chronod, duetexpertd,
   SpringBoard and mediaremoted (each tagged `(Audio - Disabled)`).
3. The Audio discoverer answers `no available routes for clientName=…,
   discovererType=Audio`.
4. mediaplaybackd fails `Get SelectableOutputs` three times, then
   `itemfig_createRenderTriplesForAudio: No audio device is available` —
   no render pipeline, silence.
5. On session end (`going inactive` / `stopping playing`),
   `Output devices changed + PuffinOutput` — the device returns.

**The working flow** (`stut1.json`, WebKit mp3 in Safari): the session is
`[MediaPlayback/Default] [NonMixable] [System Music]` — category **'csav'**
— and the same discoverer line reads `Available routes for
clientName=mediaremoted, discovererType=Audio: [0].扬声器`; no
SelectableOutputs failures; StartIO runs and the Mac plays it. (stut1's
StartIO was this WebKit session — that capture never proved a ringtone
worked.) A real iPhone (`iphone-live.json`) also logs transient no-routes
discoverer lines but never removes a device and never fails
SelectableOutputs.

The route pick itself succeeds even in the failing flow
(`FigRoutingManagerCopySelectedBufferedEndpoint: pickedEndpointName=扬声器 …
routingContextType= System Audio`). What fails is the route-configuration
computation for the RingtonePreview category, and its failure mode is to
retract the pspk port from discovery wholesale.

**Hypotheses killed this session:**

* *'noct' GET errors* (`HALS_AHPPlugIn.cpp:119`, error 1852793716 =
  `kVirtualAudioObjectRoutingNotSupportedError`). The literal source string
  is VirtualAudio's `"Routing is not supported: attempt to activate the
  routes failed."` — and the same errors appear in the **working** stut1
  capture. Tolerated noise, as are the nsrt/mute 'what' failures (which did
  not even recur in these captures).
* *Boot-time nominal rate.* A verified 44100-nominal boot (see below) fails
  the tone tap identically to the 48000 boot. The `Device Hints vdef nsrt
  44100` lines during sessions come from VirtualAudio's negotiation cache,
  not the boot preference. The dual-rate device code stays — a 44100
  aggregate needs it — but it is not the gate.

**Where the ringtone route diverges in the binary** (26.6.2): the
route-subtype family `_speaker_ringtone` (beside `_speaker_general`,
`_speaker_movie`, `_speaker_alarm`, `_speaker_latenight_*`), a subtype
named "Local System Sound For Ringtone Category", a routing database whose
misses log `Category %s does not exist in the database`, and the
`kVirtualAudioPlugInPropertyActiveNonQuiesceablePortsForCategory` /
`…ForRouteConfiguration` property sites — the plugin-side exception sources
for 'noct' / `kVirtualAudioObjectCategoryNotSupportedError` / 'unspec'.
None of the route-activation failure strings appear in any capture, so the
failing branch logs nothing we currently match.

**cfprefsd clobbers direct plist writes.** Writing
`/var/mobile/Library/Preferences/com.apple.coreaudio.plist` through
`files.write` gets rewritten by cfprefsd as a bplist that drops both
`VPhoneVirtIOSound*` keys (the device then boots as `VPhoneVirtIOSound:0`,
the default UID, and nothing routes). The durable write is the
`settings.set` RPC
(`{"domain":"com.apple.coreaudio","key":…,"value":…,"type":"float"|"string"}`),
which goes through CFPreferences.

**The abort signature (found across every failing capture):** the 'crnp'
route-change handler does not complete. It logs

```
VirtualAudio_PlugIn.mm:4270  Parsed RouteConfiguration: [ [ Category: 'crnp'; Mode: 'imdf' ]; … ]
VirtualAudio_PlugIn.mm:2766  The routing mutex was left held after handling a route change. Unlocked it.
HALS_AHPPlugIn.cpp:126       ObjectSetPropertyData: got an error from the plug-in routine, Error: 1852793716 ('noct')
```

in immediate succession — the handler bails between parsing the
configuration and finishing (an exception unwinds past the unlock; the
watchdog at :2766 catches it), and the property **SET** that drove the
route change fails `'noct'` ("attempt to activate the routes failed",
`kVirtualAudioObjectRoutingNotSupportedError`) on the now-inconsistent
state. Line **126** is the SET path; the `:119` GET errors seen in
*working* captures are a different, tolerated site. Cross-capture
provenance (all captures in `/tmp/va-analysis/`):

| Capture | Flow | :2766 mutex-left-held | :126 SET error | Session outcome |
| --- | --- | --- | --- | --- |
| nr1-tone2 | RingtonePreview 'crnp' | **4×** (idx 302/684/774/901) | **4× 'noct'** right after each | silent (session retried 4×) |
| nr2-tone | RingtonePreview 'crnp' | 1× | 'noct' | silent |
| v8-ring | RingtonePreview 'crnp' (2026-10-03, current guest) | 1× (idx 3501) | 'noct' (idx 3502) | silent |
| stut1 | WebKit 'csav' (working) | **0** | 1× — but error **2003329396 ('what')**, plus 10× :119 GET 'noct' | audible |
| iphone-live | real iPhone, ringtone + playback | 0 | 0 | audible |

So the divergence is exactly two lines: the 'crnp' computation dies inside
the handler, leaves the mutex behind, and the SET fails 'noct'; the 'csav'
computation never aborts. CoreMedia reads that failure as "no available
routes" and discovery drops the device (the `- PuffinOutput` cascade
above). The 'what' SET failure in the working capture is the familiar
mute/nsrt rejection — tolerated.

**Deploy note (same session):** the v8 build installed as `2.3.2-local`
(the bundle version bumped), but the deploy chain ran `bundle accept
2.3.1-local` — accept marks trust, **`bundle use <version>` is what
activates** — so the guest kept booting the old plugin (zero
`com.vphone` lines in the captures; the signature above reproduced on v7).
Activation fix: `bundle use 2.3.2-local` → `cfw update-environment` →
`vm start`. Symptom to check first in any future capture: the plugin's
boot line (`device PuffinOutput: … Hz nominal`) must appear before
trusting the rest.

**The v9 selector inventory (file sink) — and what it rules out (2026-10-03,
afternoon).** Two infrastructure facts first:

* The 2.3.x guest bundles' `vphoned` syslog tail **no longer delivers
  `com.vphone.audio` lines at all** — under the 2.2.5-era bundle they flowed
  (seven boot lines per audiomxd restart, plus session-time rate-probes);
  with 2.3.x they are absent from every capture, unfiltered query included,
  while the plugin binary in the guest is byte-identical to the build. The
  inventory therefore also lands in `/var/mobile/vpquery.log` (v9:
  `VPLogToFile` in `VPVirtIOSoundPlugin.m`, UTC-stamped, 4 MB cap,
  `=== plugin load ===` segment marker — the channel the session-4
  reflection probe already proved writable). Pull it with `files.read
  binary:true`.
* `logs.syslog` returns the last `max_lines` **buffered** lines and returns
  early once it has them — on a guest flooded by mDNSResponder noise
  (≈5000 lines/s) a capture started before the event it wants closes within
  a second or two and misses it entirely. Drain first (`seconds:1,
  max_lines:5000`), then start the real window.

The inventory's verdict: **during the failing 'crnp' attempts the plugin's
objects are asked nothing new at all.** The full init vocabulary (~40
tuples: `clas uid stm# pfta ctrl siso nsrt ring saft ltnc clok cstb tran
schn pft term clkd accs hidn exsm box# clk# drte dflt sflt auto muid lnam
aerE cfsz sact evAd evAS dsHS dsOr srnd …`) is asked in the first second
after respawn; the only flow-time additions in both the ring and Safari
legs are `size nsrt` → `set nsrt 44100` (the device-level rate set works —
it reaches the override, answers YES, `setSamplingRate` runs) — and then
the ring leg goes silent while the handler aborts. The divergence is
entirely inside VirtualAudio; no missing plugin property is involved.

**The abort site, found statically.** The route-change handler is
`0xa203c–0xa46dc` in the 26.6.2 plugin (anchored by the
`Parsed RouteConfiguration` string at `0xa2bc8`; the mutex watchdog that
logs "was left held … Unlocked it." is at `0x3a2720`). The handler builds a
`std::map<UInt32, …>` from its argument's VAD list (entries with flag
`+0x131 == 1`, key = the FourCC at `+0x20`), then walks the parsed
configuration's session list and does `map::at(sessionCategory)` with the
category FourCC from `+0x60` — the descent loops at `0xa238c`/`0xa23a8`
fall through to the throw at `0xa3e7c`, which loads
`"map::at:  key not found"` into a noreturn throw helper. A libc++
`logic_error` has no VirtualAudio EXCEPTION template, which is exactly why
the captures show no exception line: **the RingtonePreview category has no
entry in the category→VAD map, `map::at` throws, the handler unwinds past
the routing-mutex unlock, the watchdog at :2766 catches it, and the driving
property SET fails 'noct'.** The handler holds nine throw blocks in all
(`map::at` at `0xa3e7c`, `runtime_error("Could not convert")` at
`0xa3e8c`, five `logic_error("Precondition failure.")`/`"Could not
construct"` pairs at `0xa3f6c`–`0xa419c`, and a merged
construct/find/convert block at `0xa4230`–`0xa42cc`).

The map's population comes from the routing settings for the effective
ProductID — `ProductIDOverride=198` is a simulator class whose route set
evidently lacks the RingtonePreview entry, while 'csav' is present. The
ActuatorSettingsFactory gate (`0x36d4f0`) accepts ProductIDs
{146–169, a bitmask set ≤ 46, 197, 198, 4013–4018, 8010–8025}; only
195/196 force the "input processing disabled" path, so 197 / 4013–4018 /
8010–8025 are untried real-path candidates (a live matrix is in flight).

**Disassembly convenience for whoever continues here:** `otool -tV`
annotates string references inline — `add x3, x3, #0x5d5 ; literal pool
for: "…"` — so anchor hunts in this binary are greps over the annotation
text (`/tmp/va-analysis/va.dis`), not adrp+add address math.
**Layer 2 — the SpeakerProtection chain throw (2026-10-03, decoded).** With
`ProductIDOverride=8010` — the only accepted ProductID whose category→VAD map
covers `'crnp'` — the ringtone route change runs its full pipeline (route
list built, aggregate master `PuffinOutput`) and dies building the route's
DSP chain. `graph_configurations.plist`, loaded from
`/Library/Audio/Tunings/<acoustic ID>/VAD/` (`AID2029` on the iPad Pro 13;
the loader at 0x2fb36c joins the CommonData tuning path with `VAD` and the
filename — a filename literal referenced at 13 code sites), gives every
`speaker_*` configuration `chainType "clhs"`. The DSP chain factory (F2,
0x117628) switches on that fourCC: `clhs` (b.eq at 0x117ac8) takes the HAL
SpeakerProtection branch 0x117c30, whose config constructor (0x3dcccc, a
0xd0-byte object, exactly two callers) first calls `findDevice("Speaker")`
(0x3dc460: registry singleton → find → `LockWeakPtrOrThrow` at 0x3dc4a8,
line 60) — and a VM's device registry has no physical Speaker, so it throws
`Could not lock weak ptr (:60)`. The chain is destroyed, RoutingManager.cpp:1774
logs `Failed to activate a route list`, the route change fails `nort`
(1852797556), and the guest stays silent with no fallback. PID matrix
rounds 1–2: 197/4013–4018/8011–8020 all abort at layer 1 (`map::at` on
`'crnp'`); 195/196 die at VirtualAudio init (timeout, degenerate); only 8010
reaches layer 2. The mute `'what'` failure is benign (server-side
pre-validation).

**Why the fix is a plist, not a binary patch.** `dflt` — the chainType every
`beam_mic_*`/`omni_mic_*` configuration already ships — takes the generic
graph chain instead (0x117a38: 0x4c0 object, F1 ctor 0x117088, no
`findDevice`, wraps a shared control block). Every speaker configuration's
`graph`/`austrip` tuning files exist in the same VAD directory, so flipping
`chainType` alone moves the speaker routes onto the proven mic path. The
plist sits on the sealed system volume, so runtime `files.write` fails
EROFS; the change ships as `system-virtualaudio-cfw-speaker_graph_chains`
(see `Research/0_binary_patch_comparison.md`), which stages the plist
offline like `patch-build-version` does. Null-tolerant `findDevice` patches
are structurally dead: `buildParams` (0x3dc518) dereferences the returned
`Device*` at its first virtual call (0x3dc550), reached from both
0x3dcda4 (config ctor) and 0x1182a4 (F2's reconfigure) — a null return
crashes instead of degrading; the `LockWeakPtrOrThrow` helper 0x53a08 has
40+ callers; skipping `buildParams` leaves an uninitialized output map the
destructor crashes on. Candidate D (NOP the `clhs` b.eq at 0x117ac8 so the
factory returns a null chain via the Unsupported path) stays as the
fallback if the plist route fails empirically — downstream null-chain
tolerance is unverified.

**Empirical validation (2026-10-03, iPad Pro 13 / 26.6.2).** The plist
route works; Candidate D stays retired. With the patch applied through
`cfw update-environment` (all 8 `speaker_*` chains `clhs` → `dflt` in
`AID2029/VAD/graph_configurations.plist`) and `ProductIDOverride=8010`
persisted in `com.apple.audio.virtualaudio`, a Ringtone-preview tap on a
pristine boot — no manual audiomxd restart — shows the complete chain in
syslog: `AggregateDeviceUtilities` builds the VAD with `master =
PuffinOutput`, the generic `dflt` graph chains are created, and
`HALS_IOEngine2::_StartIO … State: Running` follows
`cmsSetIsPlaying … [RingtonePreview/Default] [System Audio] starting
playing to output VAD`. All four abort signatures are absent:
`map::at` 0, `Could not lock weak ptr` 0, `mutex was left held` 0,
`DSPGraphChain_HAL_SpeakerProtection` 0. Re-running the environment
update is idempotent (`8 speaker chains already 'dflt'`, no write).
One reading in that capture was later corrected — see the next
paragraph: the StartIO evidence was checked against the wrong device
identity.

The `:223` residue is **fatal**, not benign — the "non-fatal" reading
above was a false positive, corrected 2026-10-03 when the user reported
complete silence with the volume dead. The StartIO "Running" lines sat
on `Null_Device (VAD [vdef] AggDev 8)`, not the PuffinOutput aggregate
the audible era starts (`stut1.json`: `StartIOProcID: 78 PuffinOutput
(VAD [vdef] AggDev 2)`). Device identity, not the Running state, is the
evidence that matters: the decline at
`RoutingHandler_Playback_GenericConfig1.cpp:223` — "HAL Speaker
Protection is missing. Failing route", on the `Category: 'crnp'`
reconfiguration — drops the vdef's output stream onto Null_Device, every
"playing" signature is genuine, and nothing is audible. The capability
query the handler gates on never leaves VirtualAudio (0 hits in the ASD
plugin's file logs), so no plugin can supply it; the fix is the third
binary patch, `system-virtualaudio-cfw-speaker_protection_gate` (see
`Research/0_binary_patch_comparison.md`), which rewrites the decline's
own log block into a branch back to the gate's fall-through. The `nort`
failures from `VirtualAudio_PlugIn.mm:2815` remain, four per tap, and
are expected to be benign once the route survives.

A deployment hazard worth knowing: the first environment update after a
`bundle install-local` ran while the store swap was still settling, so
the helper exec'd the pre-swap binary against post-swap resources and
the plist step silently never ran (that build had no plist call site).
Symptom: every other guest change landed, Tunings untouched. Rule:
never run `install-local` concurrently with a helper-driven CFW
operation; re-run the environment update after the store settles.

## Layer 4 — the volume-mode precondition at :252 (2026-10-03, decoded)

The SP-gate patch landed and the capture after it
(`/tmp/va-analysis/spgate-ring.json`) proved `:223` gone — and exposed
the next decline one step down the same handler:
`RoutingHandler_Playback_GenericConfig1.cpp:252`, logging as a bare
`Precondition failure.` on 26.6.2, with StartIO still landing on
`Null_Device`. Same finished route, same teardown; one gate deeper.

**What the precondition is.** iOS 27's build kept the assert text that
26.6.2 strips to the bare string:

```
softwareVolumeModeForPerDefaultScope.has_value() &&
softwareVolumeModeForPerDefaultScope.value() ==
    VolumeControl::SoftwareVolumeMode::kHardwareOnlyReadOnly
```

The route's per-default-scope software-volume mode must be present and
be `kHardwareOnlyReadOnly` (enum 3). The virtio plugin's device reports
`SoftwareHardwareMix`, so the test fails on every VM device — same shape
as the SP gate: a hardware assumption no virtual device can satisfy.
Unlike the SP gate's quiet decline, this one *throws* a
`std::logic_error` (libc++: no VirtualAudio EXCEPTION template, so the
capture shows only the OS log's `Precondition failure.` line), which
unwinds past the route's own teardown into `RoutingManager.cpp:3520`'s
catch: route change failed `nort`, session torn down onto `Null_Device`,
silent with the volume dead. This — not the SP gate alone — is the layer
the "no sound and the volume won't move" report names.

**The guard chain** (identical instruction-for-instruction on both
builds; addresses are 26.6.2, iOS 27 in parens):

1. `bl` a wrapper (0x1450e0 / 0x14ed4c-equivalent): checks
   ActivationParams — a miss logs `Aspen.cpp:1428` "Missing
   ActivationParams for connection %u" and returns 0 — else calls the
   map getter and returns its low 40 bits.
2. The getter (0x143f34): map lookup; a miss logs `Aspen.cpp:1451`
   "Extended Volume description … absent", returns 0; a hit logs
   `Aspen.cpp:1445` "PerVAD Volume description … present" and returns
   the packed 64-bit map entry verbatim.
3. `and xN, xRet, #0x1ffffffff` — the 33-bit packing mask: present-flag
   bit 32 over the mode's low 32 bits.
4. `add x9, xBase, #1` — the expected pair `0x1_00000003`
   (`(1<<32)|kHardwareOnlyReadOnly`), built as base+1 because the
   compiler materialized `0x1_00000002` for a sibling compare.
5. `cmp` / `b.ne` to the decline (guard at 0x1369c4 / 0x1464e0; decline
   block head 0x138124 / 0x1475d0; comparison fall-through 0x1369c8 /
   0x1464e4).

The fall-through reloads its inputs from memory (`ldr x8,[sp,#…]`;
`ldr xN,[x8,#0x48]`) and never re-reads the tested value, so landing on
it after a failed compare is safe. The decline block's layout matches
the SP gate's: PRECONDITION format adrp+add 0x58 above the head, file
name 0x2c above, sole entry the guard's branch, pre-head an
unconditional branch — checked before any write.

**The fix** is the fourth binary patch,
`system-virtualaudio-cfw-volume_mode_precondition` (verb
`cfw patch-virtualaudio-volume-gate`, see
`Research/0_binary_patch_comparison.md`): the comparison and its `b.ne`
are left intact; the decline's log-block head — the `mov w0, #0xe`
sizing the os_log — becomes a `b` back to the comparison's own
fall-through, so the failed precondition lands on the continuation the
handler already built. The handler is the same one
`locatePlaybackHandler` resolves for the SP gate (SP format + file name;
exactly one function holds both), and among that handler's three
PRECONDITION declines (`:142` guard `tbz`@0x135fe0, `:252` ours, `:270`
guard `cbnz`@0x1367dc) plus `Aspen.cpp:729`, ours is the only one whose
guard sits within six instructions of a `cmp` and an `and` with
immediate `0x1ffffffff` whose preceding word is a call — the mask
window is the discriminator. Verified offline on both pristine builds:
exact sites, real writes (`29 fa ff 17` @0x138124; `c5 fb ff 17`
@0x1475d0), byte-identical idempotent re-runs, and all four VirtualAudio
verbs composing on one staged copy with a clean second pass.

**Open risk, accepted per playbook:** downstream, the route now proceeds
in `SoftwareHardwareMix` with whatever volume description the map holds
(a degenerate 0..0 dB range is plausible). Sound returning is the
expectation; volume-adjust behavior after it is the next thing to
re-check, and the earlier HardwareOnly volume-mode suspicion is related
but separate. In-guest proof standard unchanged: `:252` = 0 and StartIO
on the `PuffinOutput` aggregate (`VAD [vdef] AggDev 2`), not Null_Device.
**Verified in the guest (2026-10-03, night).** On a new iPad16,1 / 26.6.2
guest with all four VirtualAudio patches applied by `cfw install`, a ringtone
preview logs `PerVAD Volume description of scope 1 present for route
[ Category: 'crnp'; Mode: 'imdf' ]`, no `Precondition failure`, no `nort`, and
its I/O context is `PuffinOutput (VAD [vdef] AggDev N)`. Volume adjusts
(`Setting hardware volume to -11.97 dB` on device `PuffinOutput`). What still
kept the tone silent after that was not routing: see `virtio_sound.md` §6 for
the plugin faults and §7 for the haptic track.
