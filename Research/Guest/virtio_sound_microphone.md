# Microphone input through virtio-snd

The speaker chain is in `virtio_sound.md`; this is the input side: what the
macOS plugin does to capture, what the guest plugin does, and what
VirtualAudio needed before a recording app's route would build. Sources, all
local:

* macOS `/System/Library/Audio/Plug-Ins/HAL/AppleVirtIOSound.driver`, arm64e
  slice, disassembled with `otool -tV` (offsets in §1 are that slice's).
  This is Apple's own virtio-snd HAL plugin, the reference the guest plugin
  was modeled on for output.
* The guest's own `AudioServerDriver`, dumped in the guest
  (`asd-guest-dump.txt`, `asdimp-out.txt` from the speaker work): it has
  `addInputStream:`, `setReadInputBlock:`, `setInputLatency:` and
  `setInputSafetyOffset:`, so the input API is there and
  `AudioServerDriver.tbd` needs nothing new (it binds whole classes).
* The guest's `VirtualAudio` binaries saved under `~/.vphone/va-analysis/`
  (iPadOS 26.6.2 and iOS 27.0), and audiomxd logs captured on a test guest
  (`mictest-ipad`, iPad16,1 / 26.6.2) while this was built.

## 0. Where the chain stands

| Layer | State |
| --- | --- |
| Host backend | Was already there: the VM's `VZVirtioSoundDeviceConfiguration` has a `VZHostAudioInputStreamSource`. What was missing is the microphone usage description macOS wants from the process that opens the microphone (§3). |
| Guest kernel | `AppleVirtIOSound` reports stream 0 as an input stream (`direction 1, formats 0xa0020, rates 0x480, channels 1-2`) and serves selector 9, the receive transfer the macOS plugin uses (§6). |
| Guest HAL plugin | Publishes a second device, the microphone, with the input stream (§5). |
| Guest routing | The microphone device must be named `Digital Mic`, the route handler for play-and-record needs its speaker-protection gate opened, and the streams must accept the format that route sets on them (§4). With the three, Voice Memos records on an iPad guest (iPadOS 26.6.2). On an iPhone guest (iOS 27.0) the route builds and Voice Memos fails before any I/O, in the capture stack (§6). |

## 1. The reference implementation: `AVIOStream` input in the macOS plugin

### 1.1 Device construction (`AVIOPlugin halInitializeWithPluginHost:`, 0xe08)

Per `AppleVirtIOSound` service: `IOServiceOpen` on the plugin's own task, then
three registry counts through a shared helper (`0x1ab8`) —
`AVIOSoundJackCountKey`, `AVIOSoundStreamCountKey`, `AVIOSoundChannelMapCountKey`
(strings at 0x6d57/0x6d6d/0x6d85). The **jack count drives the control set**
(§1.3); the stream count drives the enumeration loop.

Stream enumeration, one `PCM_INFO` (selector 1) per virtio stream ID, parsed
out of the 32-byte `virtio_snd_pcm_info`:

| Struct offset | Field | Use |
| --- | --- | --- |
| +0x08 (u64) | formats | preference ladder, §1.2 |
| +0x10 (u64) | rates | **gate: bit 7 (48000 Hz) must be set or the stream is skipped entirely** (`tbnz w9,#0x7` at 0x1234; the ASBD is built at a hardcoded 48000.0) |
| +0x18 (u8) | direction | 0 → scope `'outp'`, stream name "Output Stream"; 1 → scope `'inpt'`, stream name "Input Stream" (0x11a4-0x11d4) |
| +0x1a (u8) | channelsMax | ASBD `mChannelsPerFrame` |

Each accepted stream becomes one `AVIOStream`
(`initWithDirection:('inpt'/'outp') withPlugin:`, 0x13f4), with:

* a serial `dispatch_queue_create("com.apple.AVIOStream.data", NULL)`;
* an `IONotificationPort` whose dispatch queue is that same queue — async
  completions are delivered on it (this is why every handler begins with
  `dispatch_assert_queue$V2`);
* `_volume = 1.0f`, state machine `Initial → SetParameters → Prepared →
  Started → Stopped → Released`.

For each rate the device advertises, a copy of the 48 kHz
`ASDStreamFormat` is made with `setSampleRate:` + `setMinimumSampleRate:` +
`setMaximumSampleRate:` pinned to that rate, then all copies go to
`setPhysicalFormats:` and the 48 kHz one to `setPhysicalFormat:`.

Registration is by direction (0x1500-0x1550): `[device addInputStream:stream]`
for `'inpt'`, `[device addOutputStream:stream]` for `'outp'`. The macOS plugin creates and registers
input streams unconditionally, on the same device as the output streams.

Device-level properties the input path needs: `setCanBeDefaultInputDevice:` is
among the three `setCanBeDefault*:` calls (0x1080-0x109c),
`setInputSafetyOffset: 100` (0x10cc), and `setTimestampPeriod:
rate × 260 / 1000` (0x10f4) — the input side shares the device clock, exactly
as `virtio_sound.md` §6 already established for output.

### 1.2 Format selection (the formats bitmap, 0x11dc-0x1234)

First matching bit wins, in this order — the winner sets
`mBitsPerChannel` and the `'lpcm'` flags:

| bit (`VIRTIO_SND_PCM_FMT_*`) | format | bits | flags |
| --- | --- | --- | --- |
| 19 | float32 | 32 | 1 (float) |
| 20 | float64 | 64 | 1 (float) |
| 18/17 | S32 | 32 | 4 (signed int) |
| 12/11 | S24 packed / S24 | 24 | 4 |
| 6/5/4 | S18?/S16 variants | 16 | 4 |
| 3 | U8 | 8 | 0 |

`VZHostAudioInputStreamSource` offers float32/48 kHz like the sink, so the
guest plugin's existing `VPVirtIOSoundChooseFormat` preference already
matches Apple's ladder for the formats that matter.

### 1.3 The input control set (0x159c-0x177c)

After the stream loop, per direction (the guest plugin builds the same set
for each of its two devices; `virtio_sound.md`, validation item 5):

* Output, when `hasOutput`: `ASDSelectorValue` `'ispk'` named "Speakers" →
  `ASDSelectorControl` (`initWithIsSettable:YES element:0 scope:'outp' …
  andObjectClassID:'dsrc'`) → `addValue:` / `setSelectedValues:` →
  `[device addControl:]` → `_addMuteAndVolumeControlsInScope:'outp'`
  (0x1b48).
* Input, when `hasInput` (0x168c onwards): the identical shape with
  **`ASDSelectorValue` `'imic'` named "Microphone"**, scope `'inpt'`, then
  `_addMuteAndVolumeControlsInScope:'inpt'` — **mute and volume controls in
  the input scope too** (the assert at 0x6e4b names both scopes legal).

Same lifecycle constraints as the output controls apply on the guest
(`virtio_sound.md` item 5): build through the explicit-class initializers,
add after device activation, never `booleanValue`.

### 1.4 Stream start (`-[AVIOStream startStream]` block invoke, 0x40e0-0x4290)

On the stream queue, the state machine runs
`SET_PARAMS` (selector 3, 24-byte struct) → `PREPARE` (selector 4, scalar) →
**if `direction == 'inpt'`: submit the initial receive buffers — the loop at
0x41a8-0x41b8 calls `_readInputIntoRingBuffer` exactly four times
(`kInputInitialBuffers = 4`), after asserting the ring holds at least four
periods** → `START` (selector 5).

Those four periods in flight then keep themselves alive: every completion
submits one more (§1.6). There is **no timer on the input side** — unlike the
output side's 1/24 s flush timer, capture is completion-driven.

### 1.5 RX submission (`-[AVIOStream _readInputIntoRingBuffer]`, 0x4410)

Asserts on-queue, `direction == 'inpt'`, `isStreaming`, ring present. Ring
geometry (the C++ `AVIOStreamRingBuffer`, layout recovered from
`readInputFrames` and this function):

| offset | field |
| --- | --- |
| +0x00 | u32 direction (0 = Output, 1 = Input) |
| +0x08 | `uint8_t *_buffer` |
| +0x10 | u32 capacity, bytes (assert `capacity % period == 0`) |
| +0x14 | u32 period, bytes |
| +0x18 | u32 bytesPerFrame |
| +0x20 | u64 readPosition — advanced by the HAL pull |
| +0x28 | u64 writePosition — advanced by completions, a period at a time |
| +0x30 | u64 inFlightPosition — advanced at submission |
| +0x38 | u8 detached |

Submission gate: `capacity − (inFlight − read) ≥ period`, else return
(a full ring means the HAL is not keeping up; capture pauses, nothing is
overwritten or dropped). Then:

```
slot = _buffer + (inFlight % capacity);   // never straddles the end
inFlight += period;
```

and the transfer itself (0x45c0-0x45ec) — the exact RX counterpart of the
plugin's TX call:

```c
uint64_t references[8] = {0};              // kOSAsyncRef64Count, zeroed
references[1] = paciza(completion_trampoline);   // kIOAsyncCalloutFuncIndex
references[2] = retained_block;                  // kIOAsyncCalloutRefconIndex
uint64_t streamID = self->_virtioStreamId;   // 1 scalar in
size_t periodBytes = period;
IOConnectCallAsyncMethod(
    connection,
    9,                                       // kVPVirtIOSoundSelectorRead
    IONotificationPortGetMachPort(asyncPort),// wake port (queue-owned)
    references, 3,
    &streamID, 1,                            // input scalars
    NULL, 0,                                 // no input struct
    NULL, NULL,                              // no output scalars
    slot, &periodBytes);                     // output struct = the ring slot
```

Three async reference slots are passed (same `kAsyncReferenceCount` the guest
plugin already uses for TX), in IOKit's own layout: slot 0 is reserved for
the wake port, `references[1]` (stored at `sp+0x78`, 0x4584) is the C
trampoline signed `paciza` (0x4ec4), `references[2]` (`sp+0x80`, 0x4590) the
retained Objective-C completion block as the refcon. If the call fails
synchronously, the completion block is invoked immediately with
`(kern_return, 0)` (0x45f8-0x4620).

The completion block's type encoding is `v16@?0i8I12` —
`void (^)(kern_return_t result, UInt32 bytesTransferred)`.

### 1.6 RX completion (trampoline 0x4ec4 → block invoke 0x4fd0)

The trampoline receives the refcon (the block) from IOKit's async
machinery, invokes the block with whatever IOKit passed after it left in
place (`x1`, `x2`), and releases it. The block **reads neither**: the invoke
(0x4fd0) keeps only its own captures across `dispatch_assert_queue`. On the
stream queue:

1. `ring->didWriteInputInFlightBytes()` (0x54dc) — takes the ring alone and
   advances `writePosition` by **one period** (`+0x14`), whatever the kernel
   reported. A completion is a period; a failed or short one is counted the
   same.
2. Retirement bookkeeping (`0x496c`) for the submitted ring — a stream whose
   ring was replaced mid-flight (`_ringBuffersToDelete` /
   `_deleteRingBufferIfDone:` / `_isActiveStreamingRingBuffer:`) retires it
   without resubmitting.
3. **If the completing ring is still the stream's current ring → call
   `_readInputIntoRingBuffer` again.** This is the steady-state loop: four in
   flight, one resubmitted per completion.

### 1.7 The HAL pull (`readInputBlock` getter 0x32b4 → invoke 0x3350)

The getter **rebuilds and returns the block on every call** — it is a property
*getter override*, and this is Apple's own answer to the ASD
releases-blocks-on-stop behavior the vphone plugin works around with
`installIOBlocks` (`virtio_sound.md` §6): the macOS plugin never lets the
property read nil. (The device-level `getZeroTimestampBlock` /
`willDoReadInputBlock` / `willDoWriteMixBlock` getters, 0x2358/0x2434/0x24e0,
are the same pattern.)

The invoke is `AVIOStreamRingBuffer::readInputFrames` inlined — signature the
full IO-block shape `(int)(UInt32 frameCount, const
AudioServerPlugInIOCycleInfo *cycleInfo, void *mainBuffer, void
*secondaryBuffer, UInt32 clientID)`:

1. `byteCount = bytesPerFrame × frameCount`;
2. **if `byteCount > capacity` or `byteCount > (writePosition −
   readPosition)` → `bzero(mainBuffer, byteCount)`** — an underrun delivers
   silence, never stale audio and never an error;
3. else `memcpy` out of `_buffer + (readPosition % capacity)`, split in two
   when the range wraps the end of the buffer;
4. `readPosition += byteCount` (assert `readPosition <= writePosition`);
5. optional gain: `volumeProcessor->process(frameCount, mainBuffer,
   (float)*(double *)((char *)cycleInfo + 0x50))` — the scalar the macOS
   plugin reads out of the cycle info; skipping this (gain 1.0) is fine for a
   first implementation.

So the input data path is: kernel fills slot → completion advances
`writePosition` and resubmits → the HAL's IO cycle pulls
`readInputFrames` → CoreAudio. The ring absorbs the rate mismatch; overrun
pauses submission, underrun gives silence.

### 1.8 `willDo*` answers (block invokes 0x3e0 / 0x4b4)

The device's `willDoReadInputBlock` / `willDoWriteMixBlock` answers are built
by the getters from the device's direction presence: `*willDo = <has that
direction>`, `*willDoInPlace = true`; the only error path is NULL out-pointers
(`'unop'`). The guest plugin answers the same way, for each device's own direction.

## 2. The AudioServerDriver input API

Introspected from the host's shared cache with `class_copyMethodList`. The
`AudioServerDriver.tbd` the guest plugin links needs no additions: it binds
whole classes (`objc-classes:`), and selectors resolve at runtime.

`ASDAudioDevice`, input-relevant surface: `addInputStream:`,
`removeInputStream:`, `inputStreams`, `hasInput`, `canBeDefaultInputDevice`
(+ setter), `inputLatency`, `inputSafetyOffset`, `inputMaximumIOFrameSize`
(+ setters), `willDoReadInputBlock` (+ setter + `willDoReadInputBlockUnretainedPtr`),
`startIOForClient:` / `stopIOForClient:`, `beginIOOperationBlock` /
`endIOOperationBlock`.

`ASDStream`: `initWithDirection:withPlugin:` (direction is the scope
fourcc), `setDirection:`/`direction`, **`readInputBlock` (+ setter +
`readInputBlockUnretainedPtr`)**, `readIsolatedInputBlock`, `terminalType`
(+ setter), `startingChannel`, `latency`, `setIsActive:`,
`channelCategoryForChannelIndex:` / `channelNameForChannelIndex:` /
`channelNumberForChannelIndex:`, and a DSP-hook family
(`processInputBlock`, `convertInputBlock`, `mixOutputBlock`, …) the virtio
plugin leaves alone.


The guest's framework has the same input surface: its own method dump lists
`addInputStream:`, `removeInputStream:`, `inputStreams`, `hasInput`,
`setCanBeDefaultInputDevice:`, `setInputLatency:`, `setInputSafetyOffset:`,
`setWillDoReadInputBlock:` on `ASDAudioDevice` and `readInputBlock`,
`setReadInputBlock:`, `readInputBlockUnretainedPtr` on `ASDStream`. Every
block property has an `…UnretainedPtr` twin, the copy the I/O thread calls,
which `performStopIO` and `stopStream` clear (`virtio_sound.md` §6): the read
block, like the mix block, has to be set again before every start.

## 3. The host side

`VZHostAudioInputStreamSource` opens the Mac's microphone when the guest
starts its input stream, in the `vphone-vm` process. macOS asks the user on
behalf of the process responsible for that, and refuses a process whose
bundle has no `NSMicrophoneUsageDescription`. `VPhone.bundle` had none.

* `VPhone.bundle/Contents/Info.plist` now carries the description, and
  `InfoPlist.xcstrings` (the catalog that already translated the location
  prompt for `VPhoneLocation.app`) is compiled into the bundle's own
  `Resources` as well, so the prompt is in the user's language.
  `ValidateBundle.sh` checks both.
* Launchpad's `Info.plist` and catalog carry the same text. A VM that
  Launchpad starts is responsible for itself (`responsibility_spawnattrs_setdisclaim`),
  but when that call is unavailable the VM is attributed to Launchpad, the
  same arrangement as the location descriptions there.
* `vphone-vm` is signed ad hoc, so the permission macOS records is tied to
  that build's code hash: a new bundle version asks again.

The host captures at its own rate and Virtualization.framework hands the
guest the 48 kHz float frames the stream was set up for.

## 4. The routing side

### The device's name decides the port

VirtualAudio's device factory builds a physical device, and a port, only for
the UIDs in its table (`0xe1354`… in the 26.6.2 binary): `Speaker`,
`AppleSongbirdDSP`, `PuffinInput`, `PuffinOutput`, `Actuator`, `AOP Audio-1`,
`HP16Mic`, `Digital Mic`, `DigitalMic`, `Mic`, `Hawking`, `Flicker`,
`Penrose`, … One UID names one kind of port, so the speaker (`PuffinOutput`,
`pspk`) and the microphone cannot be one HAL device: the plugin publishes two
per `AppleVirtIOSound` service.

Three names were candidates for the microphone:

| UID | What VirtualAudio builds | Result |
| --- | --- | --- |
| `Hawking` | a `phki` port, "Hawking Input" (`Device_Hawking_Aspen.cpp`). The earlier experiment that found it ran with an output-only device. | Not the built-in microphone: record routes are written against `pmbi`. Not tried with an input stream. |
| `PuffinInput` | `Device_Puffin.cpp`'s input twin of the speaker (`0x28f24c`; it throws "Puffin audio device has no input streams" without one). Port type `pmbi` (`0x28f09c`). | The port is published, bare. Every record route asks it for the product's microphone sub-ports and throws: `Port.cpp:776 EXCEPTION (std::logic_error): "No match found for internal sub-port ID: vcrg"` for speech detection (`crec`/`vrom`), `… btm1` for a recording app (`cpar`/`imdf`), then `Route change failed: nort.` |
| **`Digital Mic`** | the codec microphone (`Device_DigitalMic_Aspen.cpp`), with the sub-ports the routing settings define for the product. | `Adding port [ type: pmbi; uid: Built-In Microphone … rout: 1 ]`, no sub-port exception, and the route source reads `'pmbi'; iPad Microphone; Built-In Microphone`. |

So the microphone device is `Digital Mic` unless
`VPhoneVirtIOSoundInputDeviceUID` names another. With it, at audiomxd launch
VirtualAudio reads the input volume control (`Device Digital Mic, hardware
volume range: -60.000000 0.000000 [inpt/0]`) and builds the speech-detection
aggregate on it (`VAD [vspd] AggDev`, master `Digital Mic`).

### The route a recording app asks for

Voice Memos records with category `cpar` (play and record), mode `imdf`.
`RoutingHandler_PlaybackAndRecord_GenericConfig1` builds that route in full:

```
…GenericConfig1.cpp:160   Activating route [ … { [ source: 'pap ' … / destination: 'pspk'; Speaker; PuffinOutput ],
                                               [ source: 'pmbi'; iPad Microphone; Built-In Microphone / destination: 'pap ' … ] } ]
AggregateDeviceUtilities.cpp:622   Creating HAL Aggregate … master = "Digital Mic"; subdevices = ( "Digital Mic", PuffinOutput ); uid = "VAD [vdef] AggDev 7"
StreamUtilities.cpp:376   Created virtual stream for [vdef] (cpar/imdf) port pmbi with DSP chain 'none' …
StreamUtilities.cpp:376   Created virtual stream for [vdef] (cpar/imdf) port pspk with DSP chain 'speaker_general' …
…GenericConfig1.cpp:368   HAL Speaker Protection is missing. Failing route …
RoutingManager.cpp:3524   Routing is not supported: attempt to activate the routes failed.
VirtualAudio_PlugIn.mm:2815  EXCEPTION (routeUpdateInfo.first): "Route change failed: nort."
```

and then declines it for the capability the playback handler declined the
ringtone route for (`virtualaudio_speaker_route_throws.md`): HAL Speaker
Protection, which only a physical codec reports. The gate has the same shape
in both handlers and on both builds:

| Build | Gate | Decline's log block | Fall-through |
| --- | --- | --- | --- |
| iPadOS 26.6.2 | `0xea274  tbz w9, #0x0, 0xea588` | `0xea588  mov w0, #0x14` (above it `b 0xea6d4`) | `0xea278`, which reloads what it reads from the stack |
| iOS 27.0 | `0x10e468 tbz w9, #0x0, 0x10e6f0` | `0x10e6f0 mov w0, #0x14` (above it `b 0x10e814`) | `0x10e46c`, the same |

`system-virtualaudio-cfw-speaker_protection_gate` therefore writes a second
site, record `….playback_and_record`: the log block's head becomes a branch
back to the gate's fall-through, exactly as in the playback handler, found by
this handler's own file name
(`RoutingHandler_PlaybackAndRecord_GenericConfig1.cpp`). The verb
`cfw patch-virtualaudio-sp-gate` patches both; `cfw install` and
`cfw update-environment` already run it.

This handler also masks a volume-mode lookup with the 33-bit packing mask
(`0xea3fc`), but branches on it between two ways of building the route. It
is not a precondition and nothing declines there.

### The format the route sets on the streams

With the gate opened the route reached its last step and failed there:

```
Stream_HAL_Common.cpp:408   Synchronously setting physical format to [ 32/48000/2; … ] on stream 44.
HALS_UCPlugIn.cpp:1190      HALS_UCPlugIn::ObjectSetPropertyData: failed: … Error: 2003329396
HALPropertySynchronizer.h:311  error 2003329396 (what) setting property data for property [pft /glob/0] on id 44.
AggregateDevice_Duplex.h:163   EXCEPTION (kAudioHardwareUnspecifiedError): "failed to set the new format on the aggregate device"
```

Stream 44 is the speaker's, left at 44100 by the last system sound. A
playback route moves the rate through the device (`nsrt`, which the plugin
already answers itself because `ASDAudioDevice` refuses it for a plugin
device; `virtio_sound.md`, validation item 6). The duplex aggregate sets the
stream's physical format instead, and `ASDStream` refuses that the same
way. The plugin's streams now take a refused `pft `/`sfmt` set whose rate
the device supports and make it the device's rate change, which reaches
every stream: `stream 1: format set to 48000 Hz through the device`.

Two messages in the same capture did not stop the route and are left alone:
`error 'what' setting property data for property [ssrc/inpt/0] on id 37`
(VirtualAudio selecting a data source on the device; the plugin's selector
control answers the control-level property, not this device-level one) and
`We expect this device to report a correct clock domain, but it is coming
back as NULL/zero`.

## 5. What the guest plugin does

`VPhoneGuestComponents/VirtIOSound`:

* **Two devices per service**, sharing one user-client connection
  (`VPVirtIOSoundConnection`). The macOS plugin has one device with both
  directions on one connection and a queue per stream; the guest keeps that
  and only splits the HAL device. A second `IOServiceOpen` was not tried.
* **Streams**: `VPVirtIOSoundStream` holds what both directions share (the
  virtio stream's identity and format, the serial queue, SET_PARAMS and
  PREPARE, the property inventory); `VPVirtIOSoundOutputStream` is the
  speaker path as it was; `VPVirtIOSoundInputStream` is new.
* **Input transfers** (`submitReads`): four periods of the input ring are
  with the kernel at a time (selector 9, the slot as the output structure),
  submitted between PREPARE and START as the macOS plugin does, and each
  completion submits the next. A completion counts as one period, as in the
  macOS plugin; a failed one is zeroed first, and is not replaced at once but
  a period later, so a kernel that refuses the selector costs four calls a
  period and no more.
* **The ring** (`VPVirtIOSoundInputRing`, `consumed <= filled <= submitted`)
  and **the reader** (`VPVirtIOSoundInputReader`) are in
  `VPVirtIOSoundRing.[ch]` and tested on the host
  (`make test-virtiosound`). The reader is where the guest departs from the
  macOS plugin, which copies out whatever is there and zero-fills a short
  read: captured frames arrive a period (85 ms) at a time and the HAL reads a
  few milliseconds at a time, so read straight through the ring runs empty
  just before every period lands. Reads are served once two periods are
  buffered, a read that finds too little waits for two again, and more than
  four periods buffered are trimmed back to two, which bounds the delay when
  the host captures faster than the guest's clock reads. The device reports
  the two periods as `inputLatency`.
* **Stop**: the reads still out come back as the host fills them, a period
  apart, and the device is released (STOP, RELEASE) after the last, so the
  host microphone closes about a third of a second after the guest stops
  recording. Releasing first would leave the kernel holding ring slots with
  nothing known about when it returns them; that is the fallback after one
  second, for a host that has stopped filling them, and the stream then
  waits for the slots before it can be set up again. A start that finds the
  stream still draining carries on with the device as it is.
* **A full ring** (the HAL not reading) leaves fewer than four reads out, and
  no completion would bring the count back; the stream looks again a period
  later.
* **Stream formats**: a format set that `ASDStream` refuses becomes the
  device's rate change when the device supports the rate (§4), on both
  kinds of stream.
* **Device**: `canBeDefaultInputDevice`, `inputSafetyOffset` 100, wire rate
  only (the 44100 twin is the speaker's; captured frames are not resampled),
  `willDoReadInputBlock` answering for the device's own direction, and the
  macOS plugin's input control set: data source `'imic'` "Microphone", mute
  and volume in the input scope, built the way the speaker's are.

## 6. Reveal and validation

Measured on `mictest-ipad` (iPad16,1, iPadOS 26.6.2), recording in Voice
Memos:

1. Plugin: `vpquery.log` after `=== plugin load ===` lists both streams'
   `PCM_INFO`, `stream 0: input, 48000 Hz, 2 channels, 32-bit float, period
   32768 bytes, lead 2 period(s)`, `device Digital Mic: 48000 Hz nominal …`,
   `microphone controls added: dsrc 'imic', mute, volume`, `published 2
   virtio sound device(s)`.
2. HAL: `HALS_Device::Activate: activating device 37: Digital Mic`, and the
   input-scope queries arrive (`'stm#'`, `'saft'`, `'ltnc'`, `'dflt'` on
   `'inpt'`).
3. VirtualAudio: `VA Init Status: 0`, `Adding port [ type: pmbi; uid:
   Built-In Microphone; … rout: 1 ]`, no `No match found for internal
   sub-port ID`.
4. Route: `cfw update-environment` logs `SP-gate playbackAndRecord handler
   0xe92c0 … 0xec370; log block 0xea588; gate 0xea274`; Record then leaves no
   `HAL Speaker Protection is missing` and no `Route change failed`, and
   `vpquery.log` reads `stream 1: format set to 48000 Hz through the device`.
5. The kernel serves selector 9: `stream 0: first read back: result 0x0,
   argument 0x0`. The completion carries no byte count, which is why the
   macOS plugin counts a period.
6. Sound arrives. A 41.7 s recording, decoded on the host: a noise floor
   near -47 dBFS and events up to -16 dBFS RMS, 0.19 s of zeros at its start
   (the lead). Its stop lines:

   ```
   stream 1: 41.88 s, 492 writes, 0 starved, 0 bytes dropped, in 2009280 frames (47980/s, hal 48000), out 2009280 frames (47980/s)
   stream 0: 41.88 s, 490 reads, in 2007040 frames (47926/s), out 2000320 frames (47765/s), 8960 silent, 0 bytes skipped
   ```

   `silent` is the lead (8192 frames) and the reads before the first
   period; nothing after.
7. A second recording, minutes later (the device set up again): `8.42 s, 98
   reads, in … (47665/s) … 8960 silent`.
8. A recording started 0.34 s after the last stopped, while its reads were
   still out: `6.22 s, 73 reads, in 299008 frames (48072/s) … 6720 silent`,
   and no `reads still out, releasing` line. audiomxd left no crash report.
9. Speaker unchanged: Safari playing for 47.47 s leaves `557 writes, 0
   starved, 0 bytes dropped, in … (44096/s, hal 44100)`. The same test while
   another VM on the host was using seven cores read `25 starved`; a busy
   host shows up there, on either side of this change.

The first recording after the VM starts is different, both times it was
measured. Its first run ended after 2.9 s (Voice Memos reconfigures once)
with the first read back 1.9 s and 2.8 s after the start, `16 reads, in
65536 frames (22427/s)` and `4 reads`, and on the speaker `394240` and
`752640 bytes dropped`: the host held both directions while it opened the
microphone. Later starts have no such pause.

Not done:

* Whether the Mac showed its microphone prompt for VPhone, with the usage
  description, was not observed (the recording had sound, so access was
  granted one way or the other).
* An iPhone guest (`mictest-iphone`, iPhone99,11 / iOS 27.0) gets as far as
  the route and no further. Both devices are published, `cfw install` opens
  the gate there (`0x10e468` → `0x10e6f0`), and Voice Memos' Record builds
  its route: `RoutingHandler_Record_N51.cpp:125 Activating route: [ …
  Category: 'cpar'; Mode: 'spcp' … Device Type: vdfi; { source: 'pmbi';
  iPhone Microphone; Built-In Microphone … } ]`, aggregate `VAD [vdfi]
  AggDev` on `Digital Mic`, DSP chain `flexible_video_recording`. No I/O
  starts, because the app gives up first. On iOS 27 Voice Memos records
  through an `AVCaptureSession`, and cameracaptured has no capture source to
  give it:

  ```
  cameracaptured: BWFigCaptureDeviceVendor _createDevice:…: Cannot create device without create function!
  cameracaptured: FigCaptureSourceBackingsProvider …: Error -12786 while creating FigCaptureDevice. Wiping com.apple.cameracapture.volatile …
  cameracaptured: cs_getBackingsForBuiltInCameras: 0 total in-memory backings
  VoiceMemos: -[VMAudioService _onQueueStartNewRecordingWithRecorder:uuid:completion:]_block_invoke -- Recording failed -- error: Error Domain=VoiceMemos.CaptureSessionRecorder.CaptureSessionRecorderError Code=1
  ```

  That is the capture stack's device discovery on a VM, not the sound
  plugin. No sound has been recorded on an iPhone guest: nothing run there
  records without `AVCaptureSession`.

## 7. Open

* Whether the kernel returns reads still out at RELEASE is not known. The
  plugin does not depend on it in the normal stop; the one-second fallback
  does, and was not reached.
* A session at 44100 that both plays and records sets each stream's format
  in the aggregate, and the microphone device answers 48000 only, so that
  set is refused and the route would fail as it did before §4's change.
  Voice Memos records at 48000. If an app needs it, the reader needs the
  speaker path's resampler, turned around.
* `ssrc` on the input device (§4) is refused. Nothing depended on it.
* The 1.9 s pause at the first capture (§6) is the host's. If it matters,
  the lead queued on the speaker side is what would cover it.
* Only the built-in microphone port is published. Speech detection (`vspd`)
  builds its aggregate on it at launch and does not start I/O; if something
  in the guest starts listening on its own, the host microphone opens with
  it, which the Mac's microphone indicator shows. Dictation asks for consent
  first and was not enabled here.
