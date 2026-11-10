# GLES signed depth clipping

OpenGL ES accepts vertex depth in clip space from `-w` to `w`; Metal normally
accepts `0` to `w`. Apple's GLES renderer requests an OpenGL render-pass mode
to bridge those conventions, but the paravirtual GPU transport loses that
request. Valid negative-z geometry is clipped before depth testing, making
objects disappear and allowing farther objects to show through.

This fix converts GLES vertex depth to Metal's range and adjusts the renderer
viewport so `glDepthRange` still produces the same window depth. It builds on
the native GLES pipeline repairs in `03aa06a4623f8c54e4ef40ec973eacf175c3f29b`.
The conversion is independent of OS release; deployment requires matching
renderer and cache code, as described below.

## Reproduction and evidence

Measured on iOS 26.6.2 (23G90), cloudOS 26.4 (23E5207q), iPhone99,11,
with macOS 26.6.2 (25G83) on an M5 Max and Xcode 27.2.

An unchanged external GLES harness reproduced the failures in ES1, ES2 and ES3.
A triangle at z=-.5, w=1 disappeared even with depth testing disabled;
the same triangle also failed to occlude a farther positive-z triangle.
GL_NEVER and positive-z depth comparisons passed with no GL errors.

### External test App and minimal reproduction

`VPhoneGLESHarness` ("GLES Driver Test") is a separate UIKit diagnostic App;
its source, IPA and runner are not part of this repository or its test targets.
It creates a separate `EAGLContext` for ES1, ES2 and ES3 without version
fallback, runs on launch or on an explicit rerun, and writes named checks,
raw RGBA samples, GL errors and driver strings to `Documents/gles-results.json`.
The same App binary was used throughout the on/off comparison
(IPA SHA-256: `0e9b0dc6b6e9375882ef3b23a6e7a0cecb1d7ca929fdd5f9efd655c3ac6f2853`).
The rendering recipe below is sufficient to reproduce the two failures
without that App or its installation tooling.

1. Create a 64x64 FBO with an RGBA/UNSIGNED_BYTE color texture and a
   `GL_DEPTH_COMPONENT16` renderbuffer; require `GL_FRAMEBUFFER_COMPLETE`.
   Set `glViewport(0, 0, 64, 64)`, disable blending and dithering, and use
   `glDepthRangef(0, 1)`, `glDepthMask(GL_TRUE)`, `glClearDepthf(1)`.
2. Draw `GL_TRIANGLES` from XY vertices `(-.8,-.8), (.8,-.8), (0,.8)`.
   ES2's GLSL 100 vertex shader writes
   `gl_Position = vec4(aPosition, uDepth, 1.0)`; its fragment shader writes
   a uniform RGBA color. ES3 uses the same equations in GLSL 300 ES with
   `in`/`out` variables and a bound core VAO. For ES1, use OES FBO calls,
   identity projection, `glVertexPointer(2, GL_FLOAT, ...)`, and identity
   modelview followed by `glTranslatef(0, 0, depth)` with `glColor4f`.
   Disable ES1 texturing. All three paths therefore produce the same
   clip-space vertices with w=1.
3. Before each row below, clear color to `[16,32,64,255]` and depth to 1.
   Read `(32,32)` using `glReadPixels(..., GL_RGBA, GL_UNSIGNED_BYTE, ...)`.
   Require `GL_NO_ERROR` and compare all four channels within 3/255.

| Check | Draw/state | Expected center RGBA | Before fix |
| --- | --- | --- | --- |
| `depth_never` | Enable depth, `GL_NEVER`, red at z=.5 | `[16,32,64,255]` | Pass |
| `clip_negative_z` | Disable depth, green at z=-.5 | `[0,255,0,255]` | Clear color |
| `depth_rejection` | Enable depth, `GL_LESS`, green at z=-.5 then red at z=.5 | `[0,255,0,255]` | Red |
| `depth_positive_range` | `GL_LESS`, green at z=.2 then red at z=.8 | `[0,255,0,255]` | Pass |

The reported 45 checks are 15 per context: context creation, FBO completeness,
clear readback, pipeline setup, VBO triangle, texture sampling (immutable
storage in ES3), alpha blending, depth state, the four draw checks above,
drawable completeness, drawable pixels and renderbuffer presentation.
Thus 39/45 means exactly `clip_negative_z` and `depth_rejection` failed in
each API; 45/45 is this smoke suite, not a GLES conformance score. Pixel
assertions contribute to each named check rather than adding to that count;
the run contains 42 raw pixel samples, also checked independently.

### Pass-state evidence

The renderer sets pipeline and pass `openGLModeEnabled`. Its viewport reaches
`PGSerializerRenderCommandEncoder` with `znear=(near+far)/2`, `zfar=far`.
An independent native Metal probe separates shader compilation from pass state:

| State, with z=-.5 and w=1 | Host Metal | Guest PV |
| --- | --- | --- |
| Pass OpenGL flag off | Clipped | Clipped |
| Pass OpenGL flag on | Visible, depth .25 | Clipped |
| Pipeline OpenGL flag alone | No change | No change |

The guest pass serializer's command 26 does not carry the OpenGL flag.
Its private `setDepthClipModeSPI:` returns immediately; the public setter sends
command 109. No OpenGL pass setter was found in host replay. The evidence
locates the behavioral gap at pass-state transport; it does not establish a
compatible extension of that private protocol.

## Paired compensation

`dyld-cfw-gles_depth_clip` selects both halves:

- Lower metadata-identified GLES `air.position.z` to `.5*z + .5*w`.
- Change the renderer viewport near endpoint from midpoint to `2*midpoint-far`.

For u=z/w, OpenGL's window depth is
`(near+far)/2 + u*(far-near)/2`. Metal receives u'=(u+1)/2 and the original
viewport endpoints, giving the same depth and signed clip volume.
Scale z and w separately to avoid overflowing their sum.

The compiler supports float4 position returns and aggregate fields across
return blocks, preserves other fields, and marks modules to prevent repeated
lowering. Native Metal is unchanged. The compensation must be revisited if
PV gains native support for the OpenGL pass flag.

Independent shader/state controls demonstrate why the halves must stay paired:

| Guest compensation | Correct samples / 112 |
| --- | ---: |
| Neither | 88 |
| Shader only | 76 |
| Viewport only | 70 |
| Both | 112 |

## Discovery and installation

There is no iOS-base or cloudOS version gate on `dyld-cfw-gles_depth_clip`
or its cache dependencies, `system-paravirt_gpu-cfw-compiler_cache` and
`dyld-cfw-metal_cache_reuse_key`. Presets select them normally even when
version metadata is unknown. Existing device-family exclusions remain.
Availability is determined by the binary checks below, not an OS allowlist;
this does not mean that every OS release has been tested.

1. Resolve local symbols for `GLDContextRec::updateRenderViewport` and
   `GLDContextRec::setRenderViewport`. Resolve its actual `setViewport:`
   call through a direct named symbol or a verified shared selector stub.
2. Decode complete symbol spans through Capstone. Derive the context field
   from the setter's three 16-byte loads; verify its saved context, receiver,
   complete stack argument and named callee.
3. Find the adjacent double-precision near/far stores and the scalar
   midpoint/half-range loads feeding `fadd` and `fcvt`. Reject intervening SIMD
   alias writes, context changes, bypasses and ambiguous matches.
4. Redirect only the near conversion to a 16-byte trampoline in verified unused
   executable Mach-O header padding. Emit through ARM64Encoder, capture undo
   and re-attest modified cache pages. Reject orphaned or unexpected code.

The installed compiler carries `VPHONE_GLES_DEPTH_CLIP_V1:0/1` in
`__DATA,__vphone_gles`. After a successful DSC update or rollback, the installer
configures and signs that plugin, then derives the driver cache identity from
its installed bytes using the mechanism introduced in `03aa06a4`.
Before any GPU or cache write, the installer runs the renderer and cache-key
patchers in dry-run mode and resolves the driver's compiler identity inputs
from the actual restore payload (or installed pristine backup). Discovery
misses, missing symbols and absent images are unsupported capabilities, not
installation failures. Invalid data, I/O failures and verification errors
still abort. This classification applies only to these read-only probes.

| State | Result |
| --- | --- |
| New depth pair, matching binaries and selected prerequisites | Apply viewport, configure compiler, sign it with an explicit stable identifier, then version the driver from the signed bytes |
| New depth pair, unsupported renderer or GPU/cache prerequisite deselected | Skip both depth halves; keep the compiler's unconverted convention |
| Fresh GPU, unsupported compiler identity or cache key needed for reuse | Skip depth, compiler identity and cross-boot reuse; install the base GPU payload |
| Installed GPU, unavailable compiler identity or required reuse key | Preserve the installed GPU/compiler, dependent renderer patches and cache settings |
| Installed depth pair, unavailable transition prerequisite or unsupported renderer | Preserve the entire installed group and its receipt; report why it remains pending |
| Depth deselected, transition prerequisites available | Undo viewport and turn off compiler conversion, then version its cache identity |

Preservation skips the GPU bundle replacement and plugin refresh as well as
driver/DSC mutation; a receipt alone is not used to justify refreshing one
half. Other guest updates, including vphoned, continue. A default depth
selection no longer makes a GPU/cache opt-out fail selection validation.
Selection remains the user's intent; the receipt records only applied or
preserved patches, so skipped new features stay visibly pending.

Cross-boot reuse must retain its cache-key validation whenever the compiler
identity is updated. After successful preflight, actual writes, signing,
readback, re-attestation and undo remain fail-closed on the mandatory private
APFS clone. A late failure never commits only one half. Replacement bytes for
the measured OS pair are unchanged. Adjacent primitive-restart, point-draw,
vertex-ID and orientation repairs no longer gate on iOS userland version;
they retain the cloudOS 26.4 driver-transport boundary.

New installs resolve the declaration through the normal preset. Existing
guests need `cfw update-environment` while powered off; changing the selected
patch alone does not change the guest. `fw patches <name> --json` reports
pending changes. These are existing public operations, with no new CLI flag.

## Verification and limits

| Real guest check | Before | Enabled | Disabled again |
| --- | ---: | ---: | ---: |
| Unchanged ES1/2/3 harness | 39/45 | 45/45 | 39/45, same six failures |
| Independent ES1/2/3 clip probe | Negative z clipped | 63/63 | — |
| ES2/3 GLSL depth/clip matrix | — | 224/224 | 176/224 |
| Warm shader cache | — | 224/224 | — |
| Full restart | — | 224/224; harness 45/45 | — |
| Native Metal control | 28 reference pixels | All 28 identical | — |

The matrix checks `gl_FragCoord.z` and draw/clear pixels over four depth ranges
([0,1], [.1,.7], [.8,.2], [.3,.3]), four w values (.5, 1, 2, -1), and seven
NDC z values (-1.2, -1, -.5, 0, .5, 1, 1.2). This is 112 cases per GLSL
version, 224 across ES2 and ES3, independent of the App's 45 checks.
Visible samples must encode `near + (ndcZ+1)*(far-near)/2`; clipped samples
must retain the clear color. No GL or command-buffer errors.
The serializer receives default near=0/far=1 after correction, instead of .5/1.

The host AIR tests include GLSL and ES1 Program metadata, multiple return
blocks, aggregate positions, idempotence, native bypass, and 112 pixel cases
per language. Swift tests cover semantic discovery, bad setter/data-flow
shapes, malformed compiler configuration, encoders, cache identity/validation
and dependencies. Catalogue tests cover older, newer and unknown OS versions,
updates from old plans, opt-out/revert selection and device-family exclusions.
Real-cache dry-run/apply/repeat/undo restored the affected chunk byte-identically.

The retained host tests do not require the external App:

```zsh
make -C VPhoneGuestComponents test-gles-air
xcodebuild -workspace VPhone.xcworkspace -scheme FirmwarePatcherTests \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/XcodeCommand \
  -only-testing:FirmwarePatcherTests/DyldSharedCacheGLESDepthClipTests \
  -only-testing:FirmwarePatcherTests/CustomFirmwareGLESDepthConfigurationTests \
  -only-testing:FirmwarePatcherTests/CustomFirmwareParavirtGPUCompilerCacheTests \
  -only-testing:FirmwarePatcherTests/DyldSharedCacheMetalCacheReuseTests \
  -only-testing:FirmwarePatcherTests/ARM64ViewportEncoderTests \
  -only-testing:FirmwarePatcherTests/FirmwarePatchSetCatalogTests \
  -only-testing:FirmwarePatcherTests/FirmwareGuestPatchResolutionTests test
```

Guest A/B used the same stopped test VM state and offline deployment of the
patchers and configured compiler. Keep Disk, NVRAM and SEPStorage together
when taking VM snapshots; disk-only rewind is not a complete-state rollback.
The rendering runs above preceded the rebase onto current upstream main.
They do not establish rendering, application-compatibility or performance
coverage on other releases.

### iOS 27 discovery (2026-11-10)

The iOS 27.1 (24A94425) cache retains image-local `_objc_msgSend$...`
symbols whose addresses are no longer the actual selector stubs. The real
calls target shared stubs that materialize the selector in x1 and branch to
an exported `_objc_msgSend` in a cache-local `libobjcMsgSend*.dylib`.
Resolve the observed BL targets, exact NUL-terminated selector and named
dispatch export. Keep the existing direct-symbol path for caches such as
23G90. Do not infer a selector from a stale symbol address or an island offset.

This reveals the existing viewport setter and depth arithmetic without
changing the compensation. The same resolver exposes Metal's format getter,
the renderer's pipeline setter, `methodForSelector:` and point draw calls.
The restart updater uses ADD followed by a byte access instead of an indexed
byte access; both forms must prove the same state-pointer, normalization and
context-store dataflow. `populateConfigData` still reads
`AGX_GL_VIEWPORT_INVERT_CONFIG` and compares `UPPER_LEFT`.

Read-only probes of the depth, vertex-ID, restart and four point sites pass
on 24A94425; the installed 23G90 corrections remain recognizable. Newly
unsupported vertex-ID layouts also skip their dependent primitive expansion.
An unavailable already-installed renderer repair preserves its GPU/compiler
group. The iOS 27 cache passes dry-run/apply/repeat/undo with page
re-attestation: all 80 cache files return byte-identically; only `.07` and
`.44` change while enabled. All 92 selected matcher/catalogue/policy tests
pass on the local base; the public port passes 99 with newer upstream tests.

### iOS 27 runtime validation (2026-11-10)

Privileged `cfw update-environment` deployed the port into stopped iOS 27.1
(24A94425, iPhone19,4) and iOS 26.6.2 (23G90) guests using cloudOS 26.4
(23E5207q). Both completed successfully, with rows 31–36 and 39 applied and zero
pending patches. The iOS 27 cache records writes to the viewport, four point
guards, restart entry and serialized ID-format site. The compiler's paired
depth configuration and content-derived cache identity are updated in the
same transaction. No rendering hooks or shader-cache deletion were used.

| Independent guest check | iOS 27 before port | iOS 27 after update | iOS 26 after update |
| --- | ---: | ---: | ---: |
| ES2/3 depth/clip matrix above | 176/224 | 224/224 | 224/224 |
| ES1 point footprints | 0/5 | 5/5 | 5/5 |
| ES2/3 point-coordinate and outside samples | 6/30 | 30/30 | 30/30 |
| Indexed restart vs explicit nonindexed reference | 10/12 | 12/12 | 12/12 |
| Nonzero first/indexed vertex IDs and instance IDs | 24/24 | 24/24 | 24/24 |
| Native Metal depth/clip control | 28/28 | 28/28 | 28/28 |
| Scene-compatible ES1/2/3 App | 39/45 | 45/45 | 45/45 |

The rebuilt standalone native probe checks five ES1 point sizes (2–32), and
ES2/3 sizes 8, 16 and 32 with four interior `gl_PointCoord` samples and one
outside sample each. The expected Y coordinate is measured from the point's
upper edge. The restart corpus crosses line/triangle strips, UInt8/16/32
indices and enabled/disabled restart, comparing every channel of a 64×64
image to explicit nonindexed segments. UInt8/16 use their maximum index;
UInt32 uses 65535 as a high-index control. In this iOS 27 baseline only the
two UInt16 disabled cases fail. The ID corpus crosses first/indexed vertices
0, 3, 6 and 9 with one to three instances; it already passes before the port,
so it is a regression control rather than proof of the ID-format fix alone.
All enabled runs exit 0, with no GL errors or signals. Native Metal's 28
samples remain byte-identical. Warm repeats retain the depth, point and
restart results on both releases.

On iOS 27, selecting only a depth opt-out and applying another stopped-guest
update returns the matrix to 176/224 while points remain 35/35, restart
12/12 and native Metal 28/28. Restoring depth while selecting only a point
opt-out restores 224/224 depth and returns points to 6/35, with restart
still 12/12. Restoring points while opting out of primitive expansion returns
restart to 10/12, with depth 224/224 and points 35/35. Restoring the original
selection returns all checks to full pass, including after another full
shutdown and restart. Each opt-out receipt records the disabled patch as
unapplied with no pending patches; the final receipt has every repair applied.
iOS 26 also retains all standalone results after a full VM shutdown and restart.

The public port passes 99 matcher/catalogue/policy tests plus 32 patch-model
tests. Retained compiler AIR tests and both local integration and public
`VPhone` bundle builds pass, including bundle admission and signature checks.

The original external App cannot launch on this iOS 27 runtime:
`___UIApplicationEvaluateRuntimeIssueForNoSceneLifecycleAdoption_block_invoke`
traps before drawing. A separate build adds a UIScene entry point while
keeping its original 45 rendering checks; that same binary is used before
and after the update. Its three depth pairs account for 39→45, and
native-resolution screenshots show its downward triangles becoming upright.
This verifies sampled drawable orientation, not general application
compatibility or performance. Neither this corpus nor binary capability
discovery establishes support for every iOS or cloudOS release.

### Initial installation rollout checks (2026-11-10, before the iOS 27 port)

A packaged integration build containing the capability policy was used for
fresh firmware preparation, patching, restore and `cfw install`; template
reuse was disabled. Both installation transactions completed:

| Guest / cloudOS | Depth correction receipt | Cache identity / key receipts |
| --- | --- | --- |
| iOS 26.6.2 (23G90) / cloudOS 26.4 (23E5207q) | Applied | Both applied |
| iOS 27.1 (24A94425) / cloudOS 26.4 (23E5207q) | Skipped; selected but pending | Both applied |

On iOS 27 the read-only probe reports
`GLES depth clip viewport unsupported viewport setter`, then skips both
depth halves and continues installation. The receipt has exactly one pending
patch, `dyld-cfw-gles_depth_clip`; iOS 26 has none. Thus the unsupported
renderer no longer aborts installation, without claiming the depth correction
works on iOS 27.

Both guests subsequently completed the full downstream provisioning command:
first boot, Irisin/Frida configuration and normal shutdown. Both returned
`ok: true` with `state: stopped`, and neither had a pending tool transaction.

The same published bundle then ran privileged `cfw update-environment` on
both stopped guests, without their deleted restore trees. Both transactions
completed with exit status 0. iOS 26 refreshed and configured its compiler
while retaining the applied depth pair and zero pending patches. iOS 27
again reported the unsupported setter, skipped both depth halves and retained
exactly that one pending patch; its cache identity and key remained applied.
Both updated guests then started successfully, restored their configured
Frida service with `frida_ready: true`, and shut down normally.
