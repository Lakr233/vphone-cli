# Paravirtual video decoding under output backpressure

`system-videocodecd-cfw-pv_decoder_flow` is a default-on compatibility repair
for compatible arm64e iOS/iPadOS VideoToolbox caches. It keeps pixel-buffer
requests moving while an application delays an output callback, protects the
decoder during that callback, and excludes callback time from the existing
decode-reply budget. The application, SDK, compressed input and hardware
decoder selection are unchanged. The `standard` and `experimental` presets
enable it; the platform-specific and minimal presets leave it off.

## Applicability and evidence

Selection has no OS-release or device-family whitelist. Installation requires
successful discovery against the guest's **actual final
cache**. The framework must use the arm64e iOS binary platform (also used by
iPadOS; arm64e-X1 is admitted), expose the required runtime symbols, and satisfy
the private code contracts below. The runtime then verifies the framework
UUID and original instruction prefixes before activation.

The original 27.0/27.1 selection gate excluded compatible caches: stock iOS
26.6.1 (`23G83`), 26.6.2 (`23G90`) and 27.2 (`24B119`) also pass discovery.
They have the same storage-lock, UUID and message-capture offsets (16, 32 and
40), while entry addresses are recovered independently from each cache.
All five inspected builds expose the three runtime helpers and have supported
detour prologues. These are offline compatibility checks, not playback results
for the three additional releases.

The library is built with an iOS 16 deployment target, rather than inheriting
the general guest build's iOS 26 minimum. This keeps older compatible guests
eligible without claiming they were tested. Other Mach-O platforms and plain
arm64 caches are skipped before installation; changing a platform tag would
not establish ABI compatibility. No additional host macOS version or SoC gate
is imposed by this patch; the project's host requirements still apply.

The implementation has no VM-name, device-identifier, application or media
allowlist. It targets the shared PV decoder path in `videocodecd`; offsets
come from the selected cache. HEVC and H.264 are the measured codecs.

| Platform | Evidence | Coverage |
| --- | --- | --- |
| iOS 27.0 iPhone guest | Finite-hold failure and isolated on/off/on control | Eligible with matching metadata |
| iOS 27.1 iPhone guest | Inspected layout and successful repaired runs; no isolated stock on/off/on control | Eligible with matching metadata |
| iOS 26.6.1, 26.6.2 and 27.2 iPhone caches | Stock-cache discovery, runtime exports and prologues inspected | Eligible with matching final-cache metadata; playback unmeasured |
| Other iOS releases and iPadOS guests | Not measured | Eligible for discovery; matching ABI and code contracts required |
| tvOS, visionOS, watchOS and HomePod guests; plain arm64 caches | No matching runtime build | Not enabled by their presets; binary ABI check rejects them |
| Native macOS | Same finite-hold control succeeds on the measured host | No host patch |
| Physical iPhone | Not measured | Outside this guest repair |

These results establish a bounded guest compatibility repair. They do not
establish that every OS has the defect, that every build of an eligible release
is affected, or that discovery proves behavior on unmeasured guests, hosts or
codecs. Explicit selection permits evaluation; it is not a support claim.

## Reproduction and attribution

The investigation used an Apple silicon host running macOS 26.6.2 (`25G83`),
an iOS 27.0 (`24A437`) guest and an iOS 27.1 (`24A94425`) guest. The 27.0 guest repeatedly
froze near the beginning of some HEVC videos while its UI remained responsive;
the 27.1 guest was less reproducible, including at loop and seek boundaries.
The initial freezes occurred before attaching Frida. Queued compressed input,
normal memory pressure and blocked decoder stacks ruled out a simple download
or UI stall.

A bounded frame pool whose consumer depends on future decode submissions can
also stall **native macOS**. That deliberately cyclic test does not establish
that this Mac cannot decode the input, or reproduce the complete application
scheduler. `kVTDecodeFrame_EnableAsynchronousDecompression` permits an early
return; it does not guarantee one.

The discriminating control instead holds one successful output callback for
two seconds, with an independent deadline that needs no further submission to
expire. Both platforms decode the same 7,213-frame HEVC input, unpaced, using
asynchronous submissions. Each run checks
`kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder`.

| Platform / callback hold | Images returned | Error callbacks |
| --- | ---: | ---: |
| Native macOS, no hold | 7,213 | 0 |
| Native macOS, 2 s hold | 7,213 | 0 |
| Unmodified 27.0 guest, no hold | 7,213 | 0 |
| Unmodified 27.0 guest, 2 s hold | 7,011 | 202 |
| Repaired 27.0 guest, 2 s hold | 7,213 | 0 |
| Repair removed, same guest and hold | 7,011 | 202 |
| Repair re-enabled, same guest and hold | 7,213 | 0 |

The unmodified guest returns `-19092` for the first timed-out submission,
followed by 201 `-12909` bad-data callbacks. Native macOS recovers completely
from the same finite pause. This locates an additional failure in the
virtualization path; it does not prove all host virtualization code fault-free.
Physical iPhones, other host OS versions and other SoCs were not measured.

## The guest dependency

VideoToolbox's per-decoder UUID queue serializes two host messages:

- `Demt` delivers a decoded frame. The PV decoder holds its storage unfair
  lock while calling `VTDecoderSessionEmitDecodedFrame`. The XPC server's
  output callback waits for the client's callback acknowledgment.
- `Dbuf` asks the guest to allocate a pixel buffer. It uses the same queue
  and storage lock before calling `VTDecoderSessionCreatePixelBufferWithOptions`.

The application's next compressed-frame submission (`dfrm`) can need that
buffer allocation to finish. Its reply clerk has a roughly 1.1-second budget.
A transport trace with a 1.25-second callback hold found the following:

| Time from output-handler entry | Guest event |
| --- | --- |
| 0 ms | `Demt` enters; the next `dfrm` starts |
| 1 ms | Raw send returns; `Dbuf` has already reached the guest receiver |
| 1,106 ms | The decode reply wait times out with `-19092` |
| 1,259 ms | Client callback returns; only now can the queued `Dbuf` enter |
| 1,260–1,261 ms | Buffer response and late decode reply are rejected (`-19093`) |

The measured delay is between guest receive and handler entry. Moving `Dbuf`
to another queue alone leaves the storage lock blocked. Extending a timeout
alone leaves the buffer request blocked. A prototype combining queue/lock
separation and a longer deadline completed the finite-hold test and restored
playback in the unmodified application. Removing it restored the freeze.
The native repair replaces that experimental fixed deadline with callback
accounting; it does not ship the prototype's arbitrary 3.5-second timeout.

## Runtime design and boundaries

`SystemHook-vphone` loads `libvphonevideodecode.dylib` only into
`/usr/libexec/videocodecd`. The library makes seven process-private detours
using the existing `MISFixDetour` implementation. It changes no on-disk
VideoToolbox instructions and needs no runtime interpreter or Frida agent.

1. Recognize the PV decoder's exact handler block and track a state per UUID.
   Only matching `Dbuf` dispatches use that state's new serial buffer queue.
   Frame delivery and all other messages keep Apple's original queue.
2. Pin the decoder obtained from its weak holder while handling admitted
   output. During the selected XPC callback, verify unfair-lock ownership,
   release the storage lock and reacquire it before returning to Apple.
   Buffer allocation still uses Apple's lock. An ownership mismatch keeps
   the original locked behavior and increments a diagnostic counter.
3. Close output admission during invalidation and wait for already admitted
   outputs before Apple clears the session pointers. New outputs use Apple's
   original locked path, so they cannot wait behind an invalidation whose
   host reply needs that output queue. The final decoder release occurs
   after leaving the admission gate.
4. For the matching UUID's `dfrm` reply wait, retain the original request
   budget but exclude the union of its output-callback intervals. Other
   sessions, requests and semaphore callers retain their original deadline.
   Cancellation or handler removal stops further callback accounting.
   A 100 ms polling slice bounds observation of that change; it is not a
   replacement timeout and creates no reply or semaphore signal.

Thread-local scopes are saved and restored, and unrelated nested requests
clear the outer scope. Queued Apple blocks retain the wrapped handler and its
state until execution finishes. Removing the dictionary entry does not drain
or synchronously wait on the current output queue.

The two global libdispatch detours are particularly sensitive: their C
arguments are `__unsafe_unretained`. Libdispatch's private worker semaphores
may have zero external references; even a seemingly harmless ARC retain in a
pass-through wrapper can abort with `API MISUSE: Resurrection of an object`.
The sentinel-object regression test protects this ABI requirement.

This is not a watchdog that repairs arbitrary application deadlocks. A client
that never returns or cancels its callback can still hold output. The patch
does not drop frames, invent acknowledgments, grant extra output credits,
force software decoding or increase the normal host-response budget.
Diagnostics use the system log, without an unbounded per-session log file.

## Discovery, installation and opt-out

`DyldSharedCacheVideoDecodeMetadata` examines the **selected guest cache**.
It first verifies the Mach-O architecture/platform, UUID and required runtime
exports. It resolves local symbols and exact `LC_FUNCTION_STARTS` extents, follows
direct and authenticated import stubs, and checks decoded ARM64 operands for:

- the unique storage lock around session-pointer invalidation and the UUID
  argument derived from that same storage;
- the lock, frame-emission and unlock sequence in the output handler;
- the buffer-dispatch block's message/holder captures and its dispatch caller;
- the reply semaphore call site and the XPC output callback distinguished
  from same-named file-local functions by its send/wait calls;
- client invalidation's semaphore and event-link release calls and supported
  detour prologues.

Discovery fails when these contracts cannot be established. Addresses and
private field offsets are derived from this cache, not copied from a build
table or research symbol dump. Register aliases stop being trusted when
overwritten or clobbered by a call.

The 304-byte, versioned metadata at `/usr/lib/vphone-video-decoder` contains
the VideoToolbox UUID, three field offsets and eleven header-relative entries
with their original 16-byte prefixes. The library verifies the metadata ABI,
UUID, executable ranges and every prefix before installing any detour. All
wrappers remain pass-through until every detour is installed. A mismatched
image or unsupported entry leaves the repair inactive and emits a diagnostic.

Shared-cache images can have nonzero `__TEXT.fileoff`; admission derives the
slide from the unique readable `__TEXT.vmaddr`. Treating them as standalone
Mach-O files incorrectly disables the repair. A regression covers both
cache-relative and standalone file offsets, modified code and UUIDs.

The installer generates metadata **after** other shared-cache patches,
including arm64e-X1 lowering, then installs the library and metadata. It uses
the existing private APFS disk-clone transaction for the pair. An unknown ABI,
missing discovery symbols or unsupported code layout skips the repair with a
diagnostic and a `NotApplicable` receipt, and removes any obsolete pair from
the clone. Corrupt cache data, I/O, copy and removal failures still abort;
these errors are not treated as unsupported layouts. Discovery runs in process
so the installer can distinguish typed errors without parsing tool output.

Without a private clone, a first installation skips this repair with a warning
and leaves it pending in the receipt comparison, so a later update can retry.
An existing library or metadata file requires a clone before any volume writes,
even if its receipt is missing. This preserves the original non-cloning
installation fallback without publishing a partial pair.

Selection uses the existing patch-set/preset mechanism, with unrestricted
release applicability. `standard` and `experimental` enable it by default;
a per-VM block still turns it off. Existing selection, plan and receipt records
using `system-videocodecd-exp-pv_decoder_flow` migrate through the catalogue's
rename map, including saved opt-outs. There is no additional public mode or
force flag to bypass discovery. Keep unrelated per-VM overrides when changing
this identifier; see
[changing installed patches](../Firmware/post_creation_patch_changes.md).
Opt-out removes both added files. Native behavior returns at the next daemon
launch. Live environment synchronization can refresh an installed library but
cannot reinstall a deselected one. A metadata ABI change requires a new magic
version and regeneration.

## Validation and limits

The native implementation was installed through a packaged development release.
Standalone acceptance runs had no Frida connection; application observation
was read-only, and fresh launches were also checked with it detached.
The latest packaged runs refreshed existing installations through environment
synchronization; they did not exercise the offline disk-clone transaction on
a device.

| Case | 27.0 guest | 27.1 guest |
| --- | --- | --- |
| HEVC, 2 s finite hold | 7,213 / 7,213, no errors | 7,213 / 7,213, no errors |
| HEVC, synchronous calls, 2 s hold | 7,213 / 7,213, no errors | Not measured |
| HEVC, 4.5 s finite hold | 7,213 / 7,213, no errors | Not measured |
| H.264 fixture | 240 / 240, no errors | 240 / 240, no errors |
| Original player, complete loops | 23 × 610 successful frames | 22 × 610 successful frames |
| Forward/backward seek and background/resume | Playback resumed | Playback resumed |

Each guest had one **interrupted** background/resume session with a `-12903`
decode return and one fewer output than submissions. Subsequent sessions
advanced normally. Complete-loop results do not imply zero statuses across
all interruptions. On 27.0, opt-out also restored the original player's
67 ms freeze; re-enabling restored playback.

On 27.0, cooperative cancellation and client termination during a held
callback completed without restarting `videocodecd`; a fresh client then
decoded the whole file. Both guests' state dictionaries returned to zero,
observed lock-owner mismatches were zero and idle service footprint was under
5 MiB. These observations are not a long-duration leak certification.
The 27.1 full environment update also installed an unrelated, previously
missing standard GLES patch. The isolated 27.0 on/off/on control changed only
the video repair.

The contribution keeps fixture-independent tests for metadata rejection,
default selection and old opt-outs across releases, unsupported-layout versus
I/O failure handling, binary ABI admission, shared-cache image
admission, borrowed dispatch
arguments, handler lifetime, lock restoration, nested scopes, callback-budget
accounting and concurrent teardown. Temporary UI demos, media and verbose
instrumentation captures are deliberately outside the shipping source tree.

The contribution adds ten Swift metadata/admission tests; the 82-test validation
also includes the existing patch model/catalogue suites. Both native test
executables (including 100 concurrent teardown cycles) and the complete signed
`VPhone` bundle build passed under Xcode 27.2. Host tests exercise the ownership
contracts with test peers; the guest observations above remain the behavioral
evidence.

```zsh
make -C VPhoneGuestComponents test-video-decode-flow test-video-decode-hooks
xcodebuild -workspace VPhone.xcworkspace -scheme FirmwarePatcherTests \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/XcodeBundle \
  -only-testing:FirmwarePatcherTests/VideoDecodeMetadataTests \
  -only-testing:FirmwarePatcherTests/FirmwarePatchSetCatalogTests test
xcodebuild -workspace VPhone.xcworkspace -scheme VPhone -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/XcodeBundle build
```

For another guest build, first generate metadata against its actual final
cache and inspect the discovered control flow. Do not treat a successful
discovery or matching UUID/prologue as behavioral validation. Re-run native-host/guest finite-hold
controls, synchronous and asynchronous decoding, seek/loop transitions,
held-callback cancellation and client death, and an on/off/on comparison in
the unmodified player. Use unique source-frame identifiers to count returned
images and completed callbacks separately; a submission count alone cannot
prove output delivery. Admission checks cannot replace those behavioral tests.
