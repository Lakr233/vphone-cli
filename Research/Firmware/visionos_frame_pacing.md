# visionOS V201 frame pacing

Reviewed target: visionOS 26.4 (23O247), RealityDevice14,1, native V201
virtual-display path on the PCC 26.4 research kernel. The source baseline is
main `8c5aa439` (2.15.2). All lab artifacts are under
`/Volumes/ZHITAI/Data/VPhone/Builds/visionos-framerate`.

## Observed limit and native control flow

The host counts actual Virtualization framebuffer callbacks. The screen recorder's
separate 30 Hz timer does not pace this window. Native WakeBoard status reports
60 Hz for both compositor and display, yet its completed-frame counter advanced
302 frames in 10.064469 seconds (30.0066 fps). The HMD remained in Run with no
missed frames. This is a pacing discrepancy rather than a 30 Hz display mode.

The original `/usr/libexec/wakeboardd` is byte-identical to the restore image:
SHA-256 `44e96dbda3c51af29fb1209211778f820b23727e1d362e864cdfc0455df734a5`.
REA native Mach-O inspection retained target identity in
`ev_3705501951fc28df637ed6cd088241d341b30c71585577a6e8663d69f0a7c4f8`;
its export is `evidence/wakeboard-metadata.json`. No deep REA provider was
available; control flow was checked with Xcode's native disassembler against
the same original bytes, and live process stacks supplied runtime correlation.

1. `_rt_v201_display_init` sets a 60 Hz period (16.666625 ms on this guest).
2. `_rt_v201_display_vsync_dequeue` advances the tick by one period. If the
   tick is already late, it computes `ceil(lateness / period)` with
   `fcvtps x10, d0`, advancing both timestamps and both counters again.
3. `_rt_thread_main` predicts presentation one tick beyond the dequeued tick.
4. `_rt_v201_hmd_composite` passes that predicted timestamp to
   `_rt_v201_display_submit_surface`, which waits until it before presenting.
5. On return, the next dequeue is a little later than its next tick. Ceiling
   rounds even that sub-period tail up to another whole period. The ordinary
   frame therefore occupies two ticks, explaining the measured 30 fps.

A live compositor-thread stack stopped in `mach_wait_until`, with its return
address resolving to this exact submission wait. A separate host-clock model
using real `mach_wait_until` measured 29.973 fps with ceiling and 59.593 fps
when only whole missed periods were counted. The model supports the mechanism;
it is not itself a guest-performance measurement.

## Patch and reversal

`system-wakeboard-exp-visionos_frame_pacing` changes the late-period conversion
to `fcvtzs x10, d0`. The positive-lateness branch guarantees a nonnegative
input, so truncation counts complete missed periods. Sub-period lateness keeps
the current tick and the compositor still predicts the next one. All native
display clocks, prediction, rendering, submission and presentation waits stay
in place. This targets the existing 60 Hz clock; it does not advertise 90/120 Hz.

The selection is independent, off in every shipped preset, and pinned to the
26.4/26.4 pair. The installer runs it only for a visionOS guest. Opt-in uses the
normal pristine `.bak` mechanism; deselection restores the original executable.
No rollback backup is silently replaced, and a recorded patch without a backup
fails rather than claiming successful restoration.

The patcher resolves the unique in-image dequeue and adjacent status symbols,
then validates the typed Capstone data flow, branch target and imported
`mach_wait_until` call. No file offset or virtual address selects a patch site.
It accepts only the original or its own patched instruction shape. The encoder
was independently checked against Keystone 0.9.2's native C API and clang/as.
The code page is re-attested in the original SHA-256 CodeDirectory; signing
identifier, entitlements and profile blobs are preserved. A stale already-patched
signature, missing symbol, changed flow or unsupported signature is rejected
without mutating the caller's bytes. Dry-run and repeat execution do not write.

The reviewed candidate changes one instruction byte and the 32-byte code-page
hash, 33 bytes in total. Its SHA-256 is
`08929ba699ef14db5f4d24b4be381a75f89aeedd737446953843b18aeb900123`.

## Runtime validation

The lab first captured the live original and an independent backup readback.
An initial reboot happened before System metadata was flushed, so both the
candidate and its backup disappeared. `evidence/fps-floor-home.json` belongs to
that unchanged-original boot and is not a valid test of the candidate.
Subsequent deployment explicitly synchronized the guest filesystem and checked
the candidate hash again after cold boot before collecting new measurements.

| Scene | Native completed frames | Sample duration | Measured rate | Native missed frames |
| --- | --- | --- | --- | --- |
| Original Home | 302 | 10.064469 s | 30.0066 fps | 0 |
| Patched Chinese Home | 902 | 15.049898 s | 59.9340 fps | 0 |
| Patched White Sands, full immersion | 904 | 15.057288 s | 60.0374 fps | 0 |

The short samples include status-request latency, so the slight deviation from
60 is measurement noise, not a newly advertised display frequency. Independent
inspection of the actual host window showed 60 fps with native Chinese Home and
with White Sands. The native immersion readback was 1 for the latter. Frame
pixels were captured through the unchanged intent-0 WBDisplayTap composite.

Evidence: `evidence/fps-before.json`, `evidence/fps-floor-persisted-home.json`,
`evidence/fps-floor-white-sands.json`, `evidence/wakeboardd-persisted-afterboot`,
and `evidence/white-sands-60fps-frame.json`. Reproducible sampling helper:
`measure-fps.rb`; raw native-code and host-model findings:
`native-investigation/findings.md`.

Validation includes native fixture/candidate equivalence, relocated-symbol and
dry-run behavior, exact byte scope, idempotence, changed-control-flow and duplicate
refusal, malformed/stale signature refusal, the complete pacing model, and
independently assembled encoder operands. The catalogue and selection suite
also verifies shipped-preset parity, opt-in behavior and release gates.
The Xcode selection/catalogue/encoder/patch run passed 74 tests in four suites;
its optional environment-selected real-file test was skipped by that runner.
The separate native-fixture run passed all six tests, and the finished bundle's
actual CLI independently produced the exact candidate hash from the original,
preserved dry-run bytes, and was byte-identical on repeat execution. The full
VPhone bundle build and host preflight passed; the VM executable's admitted
cdhash remained unchanged.

The existing VM's desired selection now explicitly allows the pacing patch
while preserving its earlier overrides. Its installed receipt was not rewritten
to certify this manual deployment. The live binary hash, cold-boot readback and
pristine `.bak` establish the tested state; a future environment update can
manage the same independent patch and restore that backup when deselected.

## Language-switch recovery

Changing the running guest to Simplified Chinese restarted backboardd and
SurfBoard. SurfBoard's main thread then blocked in
`MuseBuddyServices -> DMGetUserDataDisposition -> synchronous XPC reply`.
The separate `com.apple.datamigrator` service repeatedly trapped while creating
its `PUIProgressWindow` because `re::mtl::makeDefaultDevice()` returned nil.
The native HMD still ran; this was not a stopped framebuffer or evidence that
the Chinese localization itself was corrupt.

A complete VM restart restored native Home with Chinese app labels and retained
the chosen language (`zh-Hans-US,en`). This is a verified recovery, not a fix
for datamigrator's Metal failure during a future language respring. No migration
completion state, account data or language preference was forged. Relevant
records are `evidence/surfboard-language-stacks.txt`,
`evidence/datamigrator-language.ips`, `evidence/datamigrator-job.json`, and
`evidence/chinese-home.png`.
