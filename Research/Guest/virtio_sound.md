# Guest audio through virtio-snd

`vphone-vm` has always configured a `VZVirtioSoundDeviceConfiguration` with a
host output sink and a host input source
(`VPhoneExecutable/VPhoneVirtualization/UI/VirtualMachine/VPhoneVirtualMachine.swift`),
and the guest never played a sound through it. Two separate faults stood in the
way. Either one alone is enough to keep the guest silent.

## 1. Nothing in iOS drives the virtio sound device

The cloudOS kernelcache (`kernelcache.research.vphone600`) carries the kernel
half. `com.apple.driver.AppleVirtIO` has a personality matching virtio device
`0x19` (virtio-snd):

| Key | Value |
| --- | --- |
| `IOClass` | `AppleVirtIOSound` |
| `IOProviderClass` | `AppleVirtIOTransport` |
| `IOVirtIOPrimaryMatch` | `0x00191af4` |
| `IOUserClientClass` | `AppleVirtIOSoundUserClient` |

The userspace half is a CoreAudio HAL plugin, and only macOS has one:
`/System/Library/Audio/Plug-Ins/HAL/AppleVirtIOSound.driver` (factory
`AVIOPluginFactory`, classes `AVIOPlugin : ASDPlugin`, `AVIODevice :
ASDAudioDevice`, `AVIOStream : ASDStream`). The guest's
`/System/Library/Audio/Plug-Ins/HAL` holds `BuiltinAudioPlugin`, `AppleAOPAudioPlugin`,
Bluetooth, AirPlay and USB plugins and nothing for virtio. The cloudOS 26.4 system
image has no HAL plugins at all, and the iPhone 27.0 image has none for virtio
either (checked in each IPSW's `.dmg.aea.mtree`, which is plaintext once the
`pbze` chunks are decompressed).

### The user-client protocol

Read out of the macOS plugin's arm64e slice. Every selector forwards one
virtio-snd request, so the structures are the virtio specification's:

| Selector | Call | virtio-snd request |
| --- | --- | --- |
| 1 | `IOConnectCallMethod`: 1 scalar (stream ID) in, 32-byte struct out | `PCM_INFO` → `virtio_snd_pcm_info` |
| 3 | `IOConnectCallMethod`: 1 scalar in, 24-byte struct in | `PCM_SET_PARAMS` (`virtio_snd_pcm_set_params`; header left zero, the kernel fills it) |
| 4 | scalar | `PCM_PREPARE` |
| 5 | scalar | `PCM_START` |
| 6 | scalar | `PCM_STOP` |
| 7 | scalar | `PCM_RELEASE` |
| 8 | `IOConnectCallAsyncMethod`: 1 scalar in, the PCM bytes as the input struct | TX transfer |
| 9 | `IOConnectCallAsyncMethod`: 1 scalar in, the period buffer as the output struct | RX transfer |

The stream count is the `AVIOSoundStreamCountKey` property on the
`AppleVirtIOSound` service. Async references use three slots, with the callout
signed with the zero discriminator (`paciza`) as any C function pointer is on
arm64e. The macOS plugin sizes a period as a twelfth of a second rounded up to a
page, keeps twelve periods, flushes whole periods every 1/24 s on a dispatch
timer, and only lets the I/O thread reuse a region once its transfer has
completed. Its device clock is free running from `mach_absolute_time`, with a
timestamp period of `rate × 260 / 1000` frames and safety offsets of 100 frames.

### `VPhoneVirtIOSound.driver`

`VPhoneGuestComponents/VirtIOSound` is the iOS plugin built from that protocol.
It is written on AudioServerDriver, the private framework `BuiltinAudioPlugin`
itself uses on iOS (its log shows `ASD_Initialize`); the classes are declared in
`VPVirtIOSoundAudioServerDriver.h` and bound through `AudioServerDriver.tbd`.
It publishes two HAL devices per `AppleVirtIOSound` service, a speaker with one
output stream per virtio output stream and a microphone with one input stream
per virtio input stream, each at the format the device offers (32-bit float,
48 kHz from `VZHostAudioOutputStreamSink` and `VZHostAudioInputStreamSource`).
A virtio stream is released when CoreAudio stops and the last transfer has come
back, so an idle guest does not keep the host audio device running and the host
microphone is open only while the guest records.

The input side (the macOS plugin's receive path, why the microphone is a
second device named `Digital Mic`, what VirtualAudio needed, and what is
verified so far) is in `virtio_sound_microphone.md`.

`cfw install` and `cfw update-environment` install it at
`/System/Library/Audio/Plug-Ins/HAL/VPhoneVirtIOSound.driver`
(`system-virtiosound-cfw-hal_plugin`).

Optional values in the `com.apple.coreaudio` domain exist for routing work
and are read when audiomxd loads the plugin: `VPhoneVirtIOSoundTransportType`
(four characters, default `usb `), `VPhoneVirtIOSoundDeviceUID` and
`VPhoneVirtIOSoundInputDeviceUID`.

## 2. VirtualAudio never finished initializing (iPad guests)

Restarting `audiomxd` in an iPad guest (ipad-pro-13, iPad17,3 / J820, iPadOS
26.6.2) and reading its log shows the HAL loading `BuiltinAudioPlugin` fine and
then VirtualAudio, the routing layer in
`/Library/Audio/Plug-Ins/HAL/VirtualAudio.plugin`, abort:

```
audio_dsp_manager  Found device acousticID = 8018
audio_dsp_manager  Device tuning directory not found: /Library/Audio/Tunings/AID8018
RoutingSettings_J98.cpp:804   Creating subport config for spatial recording
RoutingSettings_J98.cpp:805   PRECONDITION FAILURE (std::logic_error).
VirtualAudio_PlugIn.mm:2135  VA Init Status: 1
-CMVAEndptMgr- vaemGetVirtualAudioDeviceIDs: No Audio Device Available.  This is a serious error.
```

and every later session request logs `VirtualAudio PlugIn is not initialized yet`.
With no VirtualAudio device there is no audio route at all, which is also why
YouTube and bilibili in Safari would not start playing.

### What the routing code expects

The J98 routing settings (`sub_47420c` in the 26.6.2 `VirtualAudio`) build one
microphone sub-port configuration per recording mode the device advertises, and
each builder (`0x4988c0` spatial, `0x498ae0` multicam, `0x498d00` webcam) throws
when its mode is advertised but the configuration was not built:

| Mode | Advertised by |
| --- | --- |
| Spatial (stereo) recording | `MGGetBoolAnswer("DeviceSupportsStereoAudioRecording")` (`0x477698`), which libMobileGestalt answers from the *presence* of `IODeviceTree:/product/audio/stereo-sound-recording` (a copy-property call tested for non-NULL; `0x186ff4ee8` → `0x186fcfb20` in the host's copy) |
| Webcam recording | `AVGestaltGetBoolAnswer(AVGQ3J3FEVOOCNOKKTK3XQPUQ47DYY)` (`0x4776bc`), byte `0x11` of AVFCapture's per-board capability table, set for `J817-J818-J820-J821` |

For these boards (product IDs 195 and 196) the routing code skips its own
input-processing path ("Input processing disabled", `RoutingSettings_J98.cpp:400`)
and builds the configurations from the tuning directory named by the device
tree's acoustic ID (`0x491738` onwards: `AU`, `VAD`, `…_mic_peripheral_sender_all_mics`).
A real J820 has `acoustic-id = 2029`, and the iPad image ships
`/Library/Audio/Tunings/AID2029` (and `AID2028`).

For these boards (product IDs 195 and 196) the routing code skips its own
input-processing path ("Input processing disabled", `RoutingSettings_J98.cpp:400`)
and builds the configurations from the tuning directory named by the device
tree's acoustic ID (`0x491738` onwards: `AU`, `VAD`, `…_mic_peripheral_sender_all_mics`).
A real J820 has `acoustic-id = 2029`, and the iPad image ships
`/Library/Audio/Tunings/AID2029` (and `AID2028`).

### Why the guest had the wrong acoustic ID

`devicetree-cfw-product_audio_node` adds the D47 iPhone's `/product/audio`,
whose `acoustic-id` is 8018. That is right for an iPhone guest — the iPhone image
ships `AID8018` and `D47` tunings — but the iPad identity patches copy `/product`
properties from the iPad's own tree and never touched this child node, so an iPad
guest advertised J820's recording modes over tunings it does not have.

The first attempt here removed `stereo-sound-recording`. That cleared the first
failure, and the webcam builder failed next (`RoutingSettings_J98.cpp:855/856`).
The webcam answer comes from the board name itself, so the flags were never the
fault; the tuning directory was. That attempt is not in the tree.

### The fix

- `devicetree-cfw-ipad_audio`: for an iPad guest's installed tree, `fw patch`
  replaces `/product/audio` with the board tree's node
  (`DeviceTreePatcher.presentBoardAudio`): every property as the board has it,
  placeholders included, except the board's `AAPL,phandle`.
- `fw patch` now reads the board tree through the `FirmwareOriginals` stash, so a
  copy of `DeviceTree.<board>.im4p` stays in the VM folder after the restore tree
  is deleted.
- `preboot-cfw-devicetree_board_audio`: `cfw install` and `cfw update-environment`
  apply the same replacement to the restored Preboot `devicetree.img4`
  (`vphone-cli cfw patch-dt-board-audio <devicetree.img4> <board.im4p>`), taking
  the board tree from `FirmwareOriginals`. An iPad VM patched before this has no
  copy there; put the board's `DeviceTree.<board>.im4p` from its IPSW into
  `FirmwareOriginals/<restore tree>/Firmware/all_flash/` and run the environment
  update. An iPhone guest has no board tree there and is left alone.

## 3. Inside the precondition failure (follow-up session, 2026-10-02)

The acoustic-ID fix (§2) holds — a fresh `audiomxd` restart on ipad-pro-13 logs
`Found device acousticID = 2029` and loads the AID2029 configuration — but
`RoutingSettings_J98.cpp:805` still throws. ipad-mini-01 (J410, also iOS 26.6.2,
its own AID8018 present) fails at the same line, and pcc-research-01 (iPhone17,3,
iOS 27) fails at the analogous `RoutingSettings_N71.cpp:1167`. In all three:

```
PlatformUtilities_Aspen.mm:154   ProductID to int is: 195|196
RoutingSettings_{N71:1073|J98:400}   Input processing disabled
RoutingSettings_{N71:1166|J98:804}   Creating subport config for spatial recording
RoutingSettings_{N71:1167|J98:805}   PRECONDITION FAILURE (std::logic_error).
VirtualAudio_PlugIn.mm  PlugIn initialized ? 1 / VA Init Status: 1
```

`PlatformUtilities` ProductID 195 selects the N71 (iPhone) routing settings,
196 the J98 (iPad) ones — every current iPhone and iPad guest walks the
"input processing disabled" path, and on that path the spatial sub-port
configuration is never built while the mode is advertised, so the builder
throws and VirtualAudio never initializes. Since real hardware takes the same
ProductID branch, something the VM lacks — not the branch itself — keeps the
configuration from being built there.

### Disassembled mechanics (iPadOS 26.6.2 plugin, offsets in the file)

`/Library/Audio/Plug-Ins/HAL/VirtualAudio.plugin/VirtualAudio` is a standalone
arm64e Mach-O with its local symbol table intact — pulled from the running
guest with `files.read` (7,356,608 B; saved with the iOS 27 copy in
`~/.vphone/va-analysis/`). `otool -tV` on it gives:

* The three builders (`0x4988c0` spatial, `0x498ae0` multicam, `0x498d00`
  webcam) all follow one shape: if the mode is not advertised (`tbz w0,#0`)
  return NULL quietly; if it is advertised but `*(this->subportConfig)` is
  NULL (`ldr x8,[x19]; cbz x8`), log at J98.cpp:805 and throw
  `std::logic_error("Precondition failure.")`.
* The subport-config slots are constructor locals at `sp+0x1a70/0x1a78/0x1a80`
  (webcam/multicam/spatial), zeroed at `0x47452c-0x474548`.
* Advertisement inputs: `x24 = MGGetBoolAnswer(DeviceSupportsStereoAudioRecording)`
  captured at `0x47769c`, webcam answer stored `[sp+0xf8]` at `0x4776c0`;
  both feed the guard-dispatcher at `0x477c80…` (one-shot flags
  `0x6fc468…0x6fc4b8`) which calls the three builders at `0x4938c8`,
  `0x493914`, `0x493960`.
* Config-building blocks for the three modes do exist in the constructor
  (`0x48ee24` spatial → stores the slot at `0x48ef94`, `0x48f04c` multicam,
  web-cam variant near `0x48f378`, second multicam/webcam variants at
  `0x4916b0`/`0x491a78`). They look the configuration names up in the
  `graph_configurations.plist` database through `0x4d8be0` (misses log
  `DSPGraphConfig_Utilities.cpp:437 Graph collection missing expected key`
  and zero the output — that message never appears in any guest log).
* What was **not** found statically: the branch chain on the
  "input processing disabled" path that is supposed to fill the three slots
  before the guard-dispatcher runs. The obvious build blocks are reached from
  `0x4776f8 b.ne 0x48e8c4` — the branch for devices whose webcam is *not*
  advertised and whose ProductID is *not* 195/196. Manual tracing of the
  180 KB constructor did not close the gap; instrumenting a patched copy of
  the plugin (below) is the fast way to see which path runs.

### What VirtualAudio does with our HAL device

Nothing, so far. Its `HALDeviceManager` processed only `Null_Device`
(`DeviceFactory.cpp:144 Unhandled UID "Null_Device"`); device 37
(`VPhoneVirtIOSound:0`) is activated by the HAL but never "[Added]" to
VirtualAudio. Setting `VPhoneVirtIOSoundTransportType` to `vrtc`
(kAudioDeviceTransportTypeVirtual) changed nothing. Physical devices reach
the factory through a creator registry (`unordered_map` at `0x6da2f8`,
lookup `0x1cf0f0`, dispatch `0xe0c8c-0xe0dcc`) that the routing settings
populate (the N71 mic builder at `0x2be594` registers per-mic creators, e.g.
`bottom_mic2`), so until init completes there is no built-in device for a
speaker route either — fixing playback needs both the throw fixed *and* the
virtio device registered in that registry.

### Ruled out

* **Tuning-directory naming.** The AID2029 directory is used where it should
  be; `graph_configurations.plist` (`CommonData`: `tuningPath =
  /Library/Audio/Tunings/AID2029/VAD`, `tuningFilePrefix = ""`) maps every
  mic mode to graphs that exist (`stereo_recording` → `stereo_recording_no_tap`,
  `spatial_video_recording`, `multicam` → `multicam`). The
  `/Library/Audio/Tunings/J820/VAD/v201_speaker_*.dspg` lookups that fail
  (`RoutingSettings_Aspen.cpp:3287/1870/1889`, loader `0x4283d4`, called from
  `0x4310dc` with chainType `'clhs'`) are non-fatal, and no image ships a
  `J820` directory, so real hardware fails them too — they are not the blocker.
* **Stale MobileGestalt cache.** The cache directory is empty (the previous
  session's deletion stuck); answers are computed live. Writing
  `com.apple.MobileGestalt.plist` (the file libMobileGestalt actually opens —
  it logs `Could not open …/com.apple.MobileGestalt.plist` when absent) with
  `CacheExtra {DeviceSupportsStereoAudioRecording: 0,
  AVGQ3J3FEVOOCNOKKTK3XQPUQ47DYY: 0}` did not change the outcome: the
  device-tree-backed answer bypasses `CacheExtra` (or the full
  `CacheData`/`CacheUUID`/`CacheVersion` schema is required — those key
  strings are in libMobileGestalt).
* **Our device's transport type.** `usb ` → `vrtc` made no difference (above).

## 4. Root cause found and fixed: `ProductIDOverride` (same session, evening)

The missing input was the **ProductID**. `PlatformUtilities_Aspen.mm` derives
it in this order (`0x2fa638` in the 26.6.2 plugin):

1. A defaults key, read by `RunTimeDefaults.mm`: **`ProductIDOverride` in the
   `com.apple.audio.virtualaudio` domain** (its own debug knob —
   `Defaults key ProductIDOverride was defined to %u`, `0x2fa638`).
2. A table lookup over a MobileGestalt class answer — table at `0x50cfd0` =
   `[195, 0, 196, 199, 0, 198]`. These five values are **simulator/research
   classes**: every one of them makes the routing constructor take its
   "input processing disabled" path (§3: `pid ∈ {195,196}` or the
   `DisableInputProcessing` default — *another* `RunTimeDefaults` key,
   `0x2735d8` — forces it), which never builds the spatial/multicam/webcam
   sub-port configurations, so the builders throw.
3. Real hardware never reaches that table: `MGGetProductType` (`0x9135c`)
   maps the actual model to a real ProductID, and for acoustic-id devices
   the id *is* the acoustic id (`Product with AcousticID '%d' is handled`,
   chip range 2025–2035 → the J-boards).

The vphone600 research platform lands on **196** ("iPad simulator"), which is
in the skip-set — hence every iPad guest threw at `RoutingSettings_J98.cpp:805`
and every iPhone guest at `RoutingSettings_N71.cpp:1167`, while real devices
never do.

### The fix

> **Superseded (2026-10-03).** Do not store this value. The plugin now
> supplies `ProductIDOverride = 8010` in-process on an iPad guest when nothing
> is stored (§6, "Nothing left to set by hand"), and a stored value wins over
> it. 198 has no ringtone-preview category, so with it tones stay silent. A
> guest that still carries a stored 198 should have it deleted:
> `settings.delete` with domain `com.apple.audio.virtualaudio`, key
> `ProductIDOverride`. What follows is how the override was found.

```
vphone-launchpad-cli guest rpc <machine> settings.set \
  '{"domain":"com.apple.audio.virtualaudio","key":"ProductIDOverride","value":198,"type":"int"}'
```

198 (`0xc6`) is one of Apple's own class values (the table's sixth entry) and
the only one that satisfies both gates found:

* not 195/196 → the J98 constructor builds the mode configurations
  (`Creating subport config for …` at :804/:816/:855 all run, no throw);
* accepted by `ActuatorSettingsFactory_Aspen.cpp:172`'s ProductID switch
  (`0x36d4f0`) — overriding to the acoustic id 2029 fixes routing but throws
  `Invalid Product Type` there, killing init a few lines later.

Verified live on both iPad guests (audiomxd restart): `PlugIn initialized ? 2`,
**`VA Init Status: 0`**, no exceptions, and the route comes up — `VirtualAudio_Device: type vdef; id 65 … agg dev "VAD [vdef] AggDev 1"`, the
`ap:ha:nd:of:fd:ev-screen`/AP ports publish, and a ringtone preview in
Settings ▸ 声效与触感反馈 ▸ 电话铃声 produces real `AQMEIO_HAL` output
activity. One benign exception remains (`noct`/`crng` category lookup in the
routing database — 198's route set is a simulator's).

## 5. The route to the virtio device exists — it is called `PuffinOutput`

With init fixed (§4), `VirtualAudio_PlugIn.mm` processes every HAL device and
its `DeviceFactory` creates a `PhysicalDevice` only for UIDs it knows. Two
tables in the 26.6.2 binary decide:

* a device filter allow-list at `0x6b4668` — `Null_Device`, `Actuator`,
  `Halogen`, `Hawking`, `Flicker`, `Penrose` (the "AllowOnlyNull" filter mode
  in `HALDeviceManager`);
* a per-UID handler table built in the `0xe002c` device-state handler —
  `PuffinOutput`, `Actuator`, `AOP Audio-1`, `HP16Mic`, `Digital Mic`,
  `DigitalMic`, `Mic`, `Hawking`, `Flicker`, `Penrose`, `Halogen`, …

`VPhoneVirtIOSoundDeviceUID` (the plugin's existing knob) renames our device,
so each family was tried live by restarting `audiomxd`:

| UID | Result |
| --- | --- |
| `VPhoneVirtIOSound:0` (default) | `Unhandled UID` — claimed by nothing |
| `Halogen` | PhysicalDevice created, publishes `plqi`/`plqo` (LDCM) ports |
| `Hawking` | publishes `phki` input port only (mic family) |
| `AOP Audio-1` | ASD binds dependencies (`IOPAudioLPMicDevice`, `IOPAudioIOBufferDevice`), rtaid Detector node, no output port |
| **`PuffinOutput`** | **`pspk` speaker port published, routable, and the VAD aggregate is built with `master = PuffinOutput`; the vdef's stream then binds `actual strm: id 38` — our virtio stream — with `associated ports: { pspk; PuffinOutput }`** |

"Puffin" is the Apple-silicon host-audio codec family, and the research
platform is exactly a virtual Apple-silicon Mac — which is why its built-in
output device name slots straight into the iOS routing tables.

### The remaining crash

Playing a ringtone with the `pspk` route deadlocks `audiomxd` within seconds:
CoreMedia's `MXInitialize → FigVAEndpointManagerCreate →
vaemCurrentRouteHasVolumeControlListenerGuts →
CMSMUtility_GetCurrentOutputPortAtIndex` blocks on a mutex held across the
`ASDTDeviceManager` background thread (`AudioServerDriver`'s device manager,
the same layer whose `ASDTDeviceManager: Started background thread.` line
appears in every boot), then abort()s — and the poisoned state makes every
subsequent `audiomxd` launch die the same way (17 crash reports,
`~/.vphone/va-analysis/crash2.json`). Deleting the UID preference alone does
not stop the loop; a **guest reboot clears it** (verified: `audiomxd` back,
`VA Init Status: 0`, no new crashes).

Likely cause, to confirm next session: a `pspk` speaker promises CoreMedia a
volume-capable output port (`VolumeControl.cpp: Device PuffinOutput does not
support hardware volume range property` is logged and tolerated, but the
listener then blocks). Our ASD device must answer the volume/port property
queries a Puffin output answers — implementable in the plugin with the same
`AudioServerDriver` API. One instrumented build of `VPhoneVirtIOSound.driver`
logging entry/exit of its property callbacks while the `pspk` route is up
will pinpoint the call that never returns.

The direction suggested earlier in §4 — publishing through the
AudioServerDriver layer like `BuiltinAudioPlugin` — is already what
`VPhoneVirtIOSound.driver` does; the masquerade-by-UID experiments above are
the cheap form of it, and implementing the missing volume/port property
callbacks is the completion of that path. The iOS 27 binary
(`VirtualAudio-ios27`) is saved for the N71-side port of the same fix.

## 6. Playing past the first stop, at the right rate, without gaps (2026-10-03, night)

Three faults in the plugin itself survived everything above. Each was found on
a new iPad16,1 / 26.6.2 guest (`audiotest-ipad`) with counters the plugin now
writes to `/var/mobile/vpquery.log` each time the stream stops:

```
stream 1: 9.08 s, 108 writes, 0 starved, 0 bytes dropped, in 400384 frames (44079/s, hal 44100), out 435792 frames (47977/s); start 2.54, lead 1.46, in flight 2.00-3.00 periods; host 48000.2/s (+5 ppm), returns <= 86 ms apart
```

`writes` are periods handed to the kernel, `starved` the ones that found the
device with nothing left in flight (a gap on the host), `in` what the HAL
handed the mix block and `out` what went to the ring. After the semicolon:
`start` is what the device still held, in periods, when this run began (0 for
a fresh start), `lead` the silence queued ahead of its first write, `in
flight` the range seen at each submission, `host` the rate the device
returned bytes at once the run was five seconds old, with its distance from
the wire rate, and the longest gap between two returns. A stream that keeps
running writes a shorter line every minute. The counters start again at every
start.

### Every start after the first failed

Symptom: the first playback after audiomxd launches works; after any stop —
the screen turning off, the next ringtone, pausing in Safari — every start
ends five seconds later in

```
HALS_IOContext_Legacy_Impl::IsTimeRunning_Helper: Device PuffinOutput is not running.
HALS_IOContext_Legacy_Impl::IOWorkLoop: could not establish a timeline after waiting 5000000 microseconds
```

and the plugin's `getZeroTimestampBlock` is never called during those five
seconds. AudioServerDriver does that itself (guest framework, image base
`0x249eae000`; offsets in the image):

* `-[ASDAudioDevice performStartIO]` (`0x5b2c`) copies each I/O block from its
  property — whose getter (`0x5fd4` for `getZeroTimestampBlock`) returns the
  very ivar being assigned — into that ivar and its unretained twin, starts
  the streams, sets `_running` and posts `'goin'`.
* `-[ASDAudioDevice performStopIO]` (`0x7ae8`) stops the streams, clears
  `_running`, then **releases every one of those blocks and stores nil in both
  ivars** (`0x7bc4`…`0x7d40`), and posts `'goin'`.
* `-[ASDStream stopStream]` (`0x7fb8`) does the same to the stream's blocks,
  `writeMixBlock` among them.

So a block set once at init survives exactly one start. The plugin now sets
them before every start: `installIOBlocks` at the top of the device's
`performStartIO`, `installMixBlock` before `[super startStream]`.

This is also what the "frozen seed" reading in
`virtualaudio_speaker_route_throws.md` had actually seen. The boot chime was
the first start and played; the ringtone after it was the second and timed
out. Moving the seed with every period did not fix that — a later run happened
to make its first start the tested one.

### The timestamp period must not change with the rate

Symptom, once starts worked: choppy playback, the HAL handing over about
45,700–46,000 frames a second on a 44100 device, and four times a second

```
HALS_IORawClock::Update: Re-anchoring IO timeline. Sample time is not consecutive,
HostTime is increasing, Ring buffer size: 12480.
```

12480 is the period the device published at init (48000 × 0.26 s). The rate
change to 44100 (`set nsrt`, answered by the device itself, see item 6
of the validation list below) had also moved `timestampPeriod` to 11466, but nothing makes the HAL
read that property again, so it kept checking that every zero timestamp
advanced by 12480 frames, found 11466, and re-anchored. The clock now keeps
the period's frame count for the life of the device and changes only how long
a period lasts (`VPClockSetRate`): 12480 frames take 0.26 s at 48000 and
0.283 s at 44100. Measured after: 44,086–44,094 frames/s in, zero re-anchors.

The seed follows the same rule the HAL states in that log family: it names the
timeline and moves only at an anchor (`performStartIO`, a rate change). Moved
with every period it produced `Re-anchoring IO timeline. Zero timestamp seed
changed` every 0.26 s.

### Nothing was queued ahead of the host

The virtio device plays what it is handed as it arrives, and the mix arrives
in real time: a period (4096 frames, 85 ms) is submitted when it fills, by a
timer that runs every 42 ms. With nothing queued ahead, any period later than
the one before it finished is a gap. Measured with the clock already fixed:
89 of 513 writes starved in one 44 s tone, 138 of 203 in the next.

The stream now queues `VPhoneVirtIOSoundLeadPeriods` periods of silence
(default 2, 171 ms) ahead of each run, and the device reports the lead plus
one period as `outputLatency` so video is presented against when the sound is
heard. Measured: 0 of 499 and 0 of 237 writes starved.

**Restarts lost the lead.** A tone switch restarts the stream while the device
is still draining the last one. Queued at `startStream`, the lead was rounded
down to whole periods in flight, counted a nearly played buffer as whole, and
the host went on playing until the HAL's first cycle: such restarts starved
25–28 of about 60 writes, and one slow fresh start 18 of 144. The I/O thread
now queues the lead itself, before its first write of a run
(`VPMixQueueLead`): it tops what is queued up to the lead, counting what the
draining run still holds except the oldest period in flight. `startStream`
only leaves the request, so the ring's `written` keeps the single writer its
contract names. Measured after, on `audiotest-ipad`: 21 restarts while
draining and 7 fresh starts, none starved; on the final build the same on an
iPhone guest and on an upgraded guest. A restart queues at most one period
(85 ms) more than a fresh start, and that does not build up.

**Drift needs nothing.** The guest's clock and the host's audio clock are
different clocks, so the cushion could in principle erode or grow over a long
stream. Measured over a 13 minute Safari stream: the host returned 48000.0 to
48000.1 frames a second, 1–2 ppm, about 0.08 periods an hour. (Short runs
print tens to a few hundred ppm; that is the five-second window, not the
clocks.) Not measured: other host output devices — USB, Bluetooth — whose
clocks are their own. Two things in those runs that drift does not explain,
seen once each and not reproduced: a 13 minute run on an earlier build that
sat one period low and starved about 5%, and a single 205 ms stall on the
host. The first return after a start comes 2–80 ms after the write, so the
host keeps a small buffer of its own, and a `starved` write is not always an
audible gap.

### Nothing left to set by hand

Both settings §4 and §5 asked for are now what the plugin does unasked, on an
iPad or an iPhone guest (`hw.machine` starting "iPad" or "iPhone"; any other
guest gets neither, so it has the whole speaker route or none of it):

* the device UID is `PuffinOutput` unless `VPhoneVirtIOSoundDeviceUID` names
  another. Elsewhere the default stays `VPhoneVirtIOSound:0`, which
  VirtualAudio leaves unclaimed;
* `ProductIDOverride` is set to 8010 in the `com.apple.audio.virtualaudio`
  domain from `halInitializeWithPluginHost:` when nothing stored names one.
  The plugin loads before VirtualAudio reads its defaults, and both are in
  audiomxd, so the in-process value is the one it reads; audiomxd's sandbox
  keeps the write off disk (`settings.get` still shows the domain empty),
  which is why it is repeated every launch. Each launch logs one line after
  `=== plugin load ===` saying what was done and whether VirtualAudio was
  already mapped: `ProductIDOverride on 'iPhone99,11': unset, set to 8010 for
  this launch; VirtualAudio not loaded yet`. 8010 rather than §4's 198
  because 198's category map has no ringtone-preview entry
  (`virtualaudio_speaker_route_throws.md`, layer 1).

Verified on an iPad16,1 / 26.6.2 guest with all the keys deleted and rebooted:
VirtualAudio initializes, the boot chime and a ringtone preview start I/O on
`PuffinOutput (VAD [vdef] AggDev N)`, no `not initialized yet`.

### iPhone guests (2026-10-04)

An iPhone guest had been left out on the assumption that no ProductID
initializes there. Measured on a new iPhone99,11 / iOS 27.0 guest
(`audiotest-iphone`, cloudOS 26.4):

| State | VirtualAudio | Safari (mp3, 91 s) | Ringtone preview |
| --- | --- | --- | --- |
| nothing set | `ProductID to int is: 195`, `RoutingSettings_N71.cpp:1167 PRECONDITION FAILURE`, `VA Init Status: 1` | silent (`not initialized yet`) | silent |
| `ProductIDOverride` 8018, 8010 or 198 | `VA Init Status: 0`, `pspk` port on `PuffinOutput` | plays: 1067 writes, 0 starved, 44099 frames/s in (8018) | — |
| 8018, haptics node removed | as above | plays | silent: `The routing mutex was left held after handling a route change`, mediaplaybackd `No audio output is available` |
| 8010, haptics node removed | as above | plays | plays: 14.03 s, 165 writes, 0 starved |

audiomxd did not crash in any of them, including with `PuffinOutput` and no
override. 8018 is the acoustic ID of the D47 audio node the guest's tree
carries, and it fails a tone the way 198 does on an iPad, so both families
use 8010. The four VirtualAudio binary patches found their sites in the
iOS 27 binary (5 walker sites, the others one each) and the plugin's load
order held there too (`VirtualAudio not loaded yet`).

A long continuous stream for measurements, without a person: `apps.open_url`
with `https://www.soundhelix.com/examples/mp3/SoundHelix-Song-1.mp3`; Safari
plays it on load, and `ui.tap_element {"text":"Pause"}` stops it.

### The clock under a rate change

A rate change is answered by the device's own `setProperty` and can arrive
while I/O runs. The clock (`VPVirtIOSoundClock.c`) stores no period count —
it is the whole periods since the anchor at the reader's `now` — and
publishes each anchor as one snapshot versioned by the seed, so the I/O
thread never combines an old count with a new anchor. `make -C
VPhoneGuestComponents test-virtiosound` runs a writer re-anchoring against a
reader.

## 7. Tones stayed silent: the guest claimed a Taptic Engine (2026-10-03, night)

With routing and the plugin both working, Safari played and a ringtone preview
still did not. audiomxd shows the tone's route built and its AudioQueue
created (`AudioQueueObject: New output; format 2 ch, 44100 Hz, aac`) and
deleted six seconds later without ever starting. The reason is in
mediaplaybackd, which plays tones for the client:

```
itemfig_postReadyForInspectionPayload…: Track ID 1 soun … Track ID 2 hapt … Track ID 3 hapt
FigHapticEngineCreate: called, AudioSession:… Locality:…
activating connection: mach=true … name=com.apple.audio.hapticd
XPC timeout
AVHapticClient.mm:1160  Initial XPC call to server timed out. Invalidating connection to prevent hang
   (six times, one second apart)
CHHapticEngine.mm:649   createHapticPlayerWithOptions: ERROR: Server failure: … Code=4099
<<< FigHapticEngine >>> signalled err=4099
playerfig_prepareWorkingItem2: itemfig_rebuildRenderPipelinesAndBoss() failed with err=4099
playerfig_prepareWorkingItem: current item … failed to prepare (4099), advancing to next item
```

A system tone carries haptic tracks beside its audio. In MediaToolbox
(26.6.2 cache), `itemfig_rebuildRenderPipelinesAndBossGuts` calls
`FigHapticEngineCreate` when the item's `PlayHapticTracks` is set, and any
error from it leaves through the function's failure exit (`cbnz w27` at
`0x197832dd4`): the item fails as a whole, audio included.
`com.apple.audio.hapticd` is a Mach service of audiomxd
(`com.apple.audiomxd.plist`), and on a VM nothing behind it answers.

`PlayHapticTracks` comes from the client. ToneLibrary sets
`[playerItem setPlayHapticTracks:YES]` when
`-hasSynchronizedVibrationsCapability` is true, and logs how it decided:
"MobileGestalt returned %{BOOL}u for the deviceSupportsHaptics capability, and
%{BOOL}u for the deviceSupportsClosedLoopHaptics capability". Those answers
come from the device tree:

| Tree | `/product` children | `/product/haptics` |
| --- | --- | --- |
| vphone600 (guest) | vphone600-gestalt-variants, maps, haptics, usb-device, util | `closed-loop = 1`, `supports-3rd-party-haptics = 1` |
| `DeviceTree.j410ap` (iPad16,1) | camera, facetime, maps, audio | none |
| `DeviceTree.j820ap` (iPad17,3) | camera, facetime, maps, audio | none |

So the guest says it has a Taptic Engine and the iPad it presents does not.
The first fix made the node follow the board, which removed it on an iPad.

**An iPhone guest fails the same way.** On an iPhone99,11 guest running iOS
27.0, a tone preview logged the same six hapticd timeouts, the same
`FigHapticEngineCreate` 4099, and the item failed and was dropped. That guest
boots the shared vphone600 tree, has no board tree of its own to follow, and a
real iPhone's tree does have `/product/haptics`; following the board can never
remove it there. What decides it is not the device the guest presents but the
hardware behind it: no VM has a haptic actuator, and nothing serves
`com.apple.audio.hapticd`. So the removal is now unconditional.
`devicetree-cfw-product_haptics_node` takes the node out of every tree
`fw patch` writes — an iPhone guest's one tree, an iPad guest's installed tree,
and its `RestoreDeviceTree`, which is patched exactly as an iPhone guest's
tree is and from which restore reads nothing of the node — and
`preboot-cfw-devicetree_haptics` (`vphone-cli cfw patch-dt-haptics <dt>`)
does the same to a guest that is already installed, with no board tree
needed. `cfw install` and `cfw update-environment` run it for every guest.

**The answers are cached.** libMobileGestalt writes
`/private/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobilegestaltcache/Library/Caches/com.apple.MobileGestalt.plist`
at first boot. On the test guest the node was gone from `IODeviceTree` after
`cfw update-environment`, and Settings still showed the Haptics row and
mediaplaybackd still timed out on hapticd, until that file was removed and the
guest rebooted:

```
vphone-launchpad-cli guest rpc <machine> files.remove \
  '{"path":"/private/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobilegestaltcache/Library/Caches/com.apple.MobileGestalt.plist"}'
vphone-launchpad-cli guest rpc <machine> system.reboot '{"force":true}'
```

A guest created with the patch never caches the wrong answers: its tree is
written before its first boot. An existing one needs the file removed, and
the host cannot do it. The guest's container holds s1 System, s2 Data, s3
xART, s4 Hardware, s5 Preboot and s7 User; Data and User are FileVault
volumes whose keys are in the guest's SEP, and `diskutil mount` on the host
answers "This is an encrypted and locked APFS Volume". The volume the
installer mounts beside System is xART, where the gigalocker lives. An
earlier installer change that removed the cache from that volume could never
find it: after a live `cfw update-environment` the cache still had its
first-boot modification time.

So vphoned does what the two commands above do, less the reboot, at startup
(`VPhoneDaemon/Daemon/GuestMobileGestaltCache.swift`). The rule is the age of
the cache against the tree the guest booted,
`/private/preboot/<hash>/usr/standalone/firmware/devicetree.img4`, the file
the installer patches. The host changes that tree only with the VM stopped,
and the installer writes a guest file only when its verb changed it, so a
cache older than the tree was worked out from an older tree and is removed:

```
vphoned: MobileGestalt cache predates the device tree, removed it; a restart makes the new answers take effect
```

A cache written after the tree was written by a boot of that tree, and is
left alone without a line. That covers every Preboot tree repair (the haptics
removal, the board audio node) and needs no state, so it works the first
time a new vphoned runs on an old guest. Processes that read the cache keep
their answers until they exit, so the removal takes full effect at the next
boot; vphoned does not restart the guest itself. Until then `/v1/health`
reports `mobilegestalt_restart_pending: true`.

For an existing guest that is `cfw update-environment`, one boot (vphoned
drops the cache), and one restart. A new guest, and every later boot of an
updated one, does nothing: its cache is newer than its tree.

**Verified** (`audiotest-ipad`): after the cache was rebuilt the Ringtone page
has no Haptics row, mediaplaybackd makes no hapticd connection, and a tone
preview plays on the Mac — heard, and in `vpquery.log` a 20 s stream with 237
writes and none starved.

**Verified on an iPhone guest** (`audiotest-iphone`, iPhone99,11 / iOS 27.0):
with the node removed and the cache rebuilt the Ringtone page has no Haptics
row, mediaplaybackd makes no hapticd connection, and with ProductID 8010 a
tone preview plays (§6, "iPhone guests").

**Verified as an upgrade** (`mgtest-ipad`, iPad16,1 / 26.6.2, created with a
bundle from before the removal, so it booted with the node and cached the
old answers, Haptics row showing): after `cfw update-environment` from this
build the node is gone from `IODeviceTree`; on the first boot vphoned leaves
its marker for that boot session in
`/var/root/Library/Caches/com.vphone.vphoned.mobilegestalt-dropped` and the
cache file is new; after one restart the Haptics row is gone, the cache keeps
its modification time (nothing removed again), and a tone plays — 16.12 s,
190 writes, none starved. `/v1/health` was not read in that run; the marker
file is what its field reports.

## 8. The volume moved a number and nothing else (2026-10-04)

On an iPhone guest (iOS 27.0) the volume keys moved the guest's volume
(`active_volume` 0.5 → 0.625) and the Mac played at the same level
throughout. Every route activation and every volume change logged

```
OutputVolumeControl_HAL_Common.cpp:1314  Setting hardware volume to -29.000000 dB
Device_HAL_Common.mm:317   Set decibel volume value of -29.000000 on HAL device 43 (selector: kAudioDevicePropertyVolumeDecibels; scope: 'outp'; element: 0).
HALS_UCPlugIn.cpp:1191     HALS_UCPlugIn::ObjectSetPropertyData: failed: … Error: 2003329396
Device_HAL_Common.mm:330   FAIL with status 2003329396 ("what"): mDeviceID 43 (uid "PuffinOutput"); selector "vold"; scope 'outp'; element 0
```

The pspk route runs in HardwareOnly volume mode: VirtualAudio leaves the
loudness to the device and sets `vold` (and `mute`) on it. The HAL turns a
device-level `vold` or `mute` into a set on the device's volume or mute
control, and the set reaches the control: `ASDLevelControl`'s
`setProperty:` (`0x41f50` in the guest's AudioServerDriver) clamps the value
and tail-calls `changeDecibelValue:` or `changeScalarValue:`, and
`ASDBooleanControl`'s calls `changeValue:`. The framework's own are

```
42a20: mov w0, #0x0 ; ret        -[ASDLevelControl changeDecibelValue:]
42a28: mov w0, #0x0 ; ret        -[ASDLevelControl changeScalarValue:]
3b680: mov w0, #0x0 ; ret        -[ASDBooleanControl changeValue:]
```

— a driver is expected to subclass them, and until it does every change is
refused with 'what'. That is also the mute set `mute_set_throw` quiets: the
selector was never withheld from the plugin, it arrived at the mute control
and was refused there.

The plugin's controls are now subclasses whose hooks take the change, and
the device turns them into a gain its streams apply: silence when muted,
otherwise the control's decibels as a factor, ramped across one I/O block,
on the mix as the I/O thread hands it over. The microphone device takes mute
only.

The speaker's control ranges from -36 dB to 0 dB, not the macOS plugin's -60:
VirtualAudio maps the guest's volume onto the range in a straight line
(`VolumeProperties for Port: pspk is [ Min: …; Max: 0 ]`), so the bottom
decides how loud half volume is, and -30 dB through a Mac's speakers is
close to nothing.

Measured on the iPhone guest, Safari playing: three volume-up and five
volume-down presses log `device speaker: unmuted, -15.8 dB, gain 0.163` →
`-9.0 dB, gain 0.355` → `-20.2 dB, gain 0.097`; audiomxd logs `Setting
hardware volume to -13.500000 dB` with no `FAIL` for `vold` or `mute`; the
stream runs 240 s with 0 starved.

Not this: Control Center's volume slider on an iOS 27 guest stays full and
does not move. SpringBoard cannot reach the volume service at all —

```
kernel: Protobox: SpringBoard(36) deny(1) mach-lookup com.apple.mediaexperience.avvolumeclient.xpc
SpringBoard: -AVVolumeClient- -[AVVolumeClient initInternalWithType:]: Failed to create FigVolumeController for type 1: -16155
SpringBoard: [MRAVVolumeClientEndpoint] VolumeController unavailable; will retry on next activation
```

audiomxd registers the service and SpringBoard holds
`com.apple.private.mediaexperience.controlcentervolumeclient.allow`; the
lookup is refused by the kernel's sandbox. The likely reason, not traced
further: the sandbox profile for SpringBoard comes with the cloudOS 26.4
kernel and predates a service iOS 27's SpringBoard asks for, the kind of
mismatch `kernel-boot-sandbox_ext` opens `proc_check_syscall_unix` for. It
needs its own kernel-side change. The volume keys do not go through that
service.

## Reveal and validation

1. Kernel side present: `strings` on the decompressed kernelcache shows the
   `AppleVirtIOSound` personality above.
2. Plugin loaded: `logs.syslog` for `audiomxd` shows
   `com.vphone.audio/virtiosound` lines `stream 0: 48000 Hz, 2 channels…` and
   `published 1 virtio sound device(s)`.
3. VirtualAudio initialized: `audiomxd` logs `Defaults key ProductIDOverride
   was defined to 8010`, `PlugIn initialized ? 2` / `VA Init Status: 0`, no
   `PRECONDITION FAILURE`, and no `VirtualAudio PlugIn is not initialized yet`
   when an app opens a session. The plugin supplies the override on an iPad
   guest (§6); `vpquery.log` says so when it had to.
4. Sound on the host: audible, and still audible after a stop. Beyond the
   plugin's own defaults (§6) the speaker route needs the VirtualAudio patches
   (`virtualaudio_speaker_route_throws.md`). In `vpquery.log`, every stop —
   the second and later ones included — leaves a counter line with `writes` in
   proportion to the seconds played, `0 starved`, and `in` at the nominal
   rate; `logs.syslog` for audiomxd shows no `Re-anchoring IO timeline` and no
   `could not establish a timeline`.
5. Hardware volume: the plugin answers the pspk route's volume queries with a
   real control set — dsrc selector ('ispk' "Speakers"), mute, volume — added
   from `halInitializeWithPluginHost:` after device init, before
   `addAudioDevice:`. Init-time `addControl:` fails the whole device
   activation (`HALS_PlugIn.cpp:162`); this lifecycle moment does not.
   Validated by staged isolation on ipad-pro-13 (2026-10-03): with
   `endpointTypeInfo` deleted, audiomxd restart, RingtonePreview playback,
   and a tone tap preview all left it absent — no more `Unspecified` rewrite
   — and `[volm/outp/0]` writes on the VAD succeed. Two constraints the
   controls themselves carry on iOS: construct them through the
   explicit-class initializers (`initWithValue:…andObjectClassID:` and the
   decibel twin), never the factories — the factories are state-dependent and
   returned the raw FourCharCode 'togl' as an `id`, crash-looping audiomxd —
   and never call `booleanValue` on the result (the getter is `value`;
   the selector does not exist and faults inside audiomxd). And the controls
   alone still do not give the device a mute property: iOS ASDAudioDevice's
   device-level dispatch has no 'mute' case at all, so
   `VPVirtIOSoundDevice` overrides the five ASD property methods and answers
   `kAudioDevicePropertyMute` from a shadow ivar, forwarding sets to the
   registered mute control (see the handoff in
   `virtualaudio_speaker_route_throws.md` for the disassembly).
6. Dual-rate (44100 ringtone previews): the device advertises
   `@[@44100, @48000]` and the 48 kHz stream carries a 44100 physical format;
   `setSamplingRate:`/`deviceChangedToSamplingRate:` move an atomic HAL rate
   under the mix block, which linearly resamples 44100→48000 onto the wire
   while the clock re-derives how long its period lasts (§6). Verified
   booting and answering at both nominal rates — and disproven as the ringtone gate: a 44100-nominal
   boot fails the tone tap exactly like a 48000 one. The gate is the
   RingtonePreview category itself; see the session-5 section of
   `virtualaudio_speaker_route_throws.md`.
