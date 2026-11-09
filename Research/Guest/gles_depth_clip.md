# GLES signed depth clipping

Follow-up to `03aa06a4623f8c54e4ef40ec973eacf175c3f29b`, which restored native
GLES metadata, orientation, builtin IDs, primitive restart and point semantics.
This correction addresses the remaining signed clip-z convention.

## Reproduction and evidence

Measured on iOS 26.6.2 (23G90), cloudOS 26.4 (23E5207q), iPhone99,11,
with macOS 26.6.2 (25G83) on an M5 Max and Xcode 27.2.

An unchanged external GLES harness reported 13/15 for each ES version.
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

The declaration is gated to iOS base 26.6 and cloudOS 26.4.

1. Resolve local symbols for `GLDContextRec::updateRenderViewport`,
   `GLDContextRec::setRenderViewport` and `_objc_msgSend$setViewport:`.
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
Both selection transitions require GPU bundle refresh and compiler-cache
versioning. Cross-boot reuse must retain its existing cache-key validation.
The operations share the installer's mandatory private APFS clone; a failed
half or cache update rejects the transaction.

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
shapes, malformed compiler configuration, encoders, gates and dependencies.
Real-cache dry-run/apply/repeat/undo restored the affected chunk byte-identically.

The retained host tests do not require the external App:

```zsh
make -C VPhoneGuestComponents test-gles-air
xcodebuild -workspace VPhone.xcworkspace -scheme FirmwarePatcherTests \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/XcodeCommand \
  -only-testing:FirmwarePatcherTests/DyldSharedCacheGLESDepthClipTests \
  -only-testing:FirmwarePatcherTests/CustomFirmwareGLESDepthConfigurationTests \
  -only-testing:FirmwarePatcherTests/ARM64ViewportEncoderTests \
  -only-testing:FirmwarePatcherTests/FirmwarePatchSetCatalogTests \
  -only-testing:FirmwarePatcherTests/FirmwareGuestPatchResolutionTests test
```

Guest A/B used the same stopped test VM state and offline deployment of the
patchers and configured compiler. Keep Disk, NVRAM and SEPStorage together
when taking VM snapshots; disk-only rewind is not a complete-state rollback.
The privileged `cfw update-environment` transaction has not been exercised
end to end in this validation. The guest runs preceded the rebase onto current
upstream main. No additional OS, application-compatibility or performance
coverage is claimed.
