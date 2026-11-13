# iPad pointer missing from the host view in landscape

Investigated 2026-11-13 on `ipad-mini` (iPad16,1, iPadOS 27.0.1 `24A446`,
bundle 2.16.1, cloudOS 26.4). Static evidence is the `24A446__iPad16,1_2`
dyld shared cache extraction; live evidence comes from host lldb attached to
the guest's `backboardd`, `pointeruid` and `SpringBoard` through the CFW
debugserver (`Research/Guest/Evidence/duo-sim-baseline/tools/vm-probe.zsh`).
Addresses are cache VM addresses; the guest maps the cache at slide 0, so they
match the running processes.

## Symptom

With a mouse attached through the VM window, the iPad pointer is visible in the
host `VZVirtualMachineView` in portrait and invisible in landscape (90° and
270°). The guest's own snapshot (`screen.screenshot`, i.e.
`CARenderServerRenderDisplay`) shows the pointer in both orientations. Taps,
hover effects and the pointer's position are all correct; only the arrow is
missing from the scanout. A respring or a pointeruid restart does not help;
rotating to portrait does.

## The pointer's layer chain

- `pointeruid` owns two non-displayable, secure `CAContext`s:
  `PUIDSystemPointerWindow` (a portal plus luma backdrop) and
  `PUIDPointerRenderingWindow` (a hidden root holding `PUIDPointerShapeView`).
- Under `PUIDPointerShapeView`: a zero-size container (opacity 0.85), then
  `PUIDPointerView`, a `CABackdropLayer` with a colour-matrix filter and
  `allowsInPlaceFiltering`, masked by a `CAShapeLayer` whose path is the arrow.
  While the pointer is idle the shape view carries a gaussian blur.
- SpringBoard hosts both scenes through `CALayerHost` in two
  `SBFSecureTouchPassThroughWindow` windows owned by `SBMousePointerManager`.
  These windows do not rotate with the interface: they stay portrait
  (744×1133 points).
- The pointer model position is in panel-native coordinates, and
  `BKMousePointerController` keeps its region in landscape logical coordinates
  (1133×744). Both are correct.

## What it was not

Each of these was changed live and the host view compared with the guest
snapshot:

- Not the screen-capture clone display (wireless0): it was the first suspect,
  but the symptom follows orientation, not cloning.
- Not dirty regions: forcing full redraws at 120 Hz changed nothing.
- Not the portal: `matchesTransform`, `crossDisplay` and
  `allowedInContextTransform` in every combination.
- Not in-place filtering, group opacity, the blur filter, cross-context
  portals or backdrop groups.
- Not `BKMousePointerDisplayRenderer`: it is unused on this path.
- Not positioning: a solid layer added under `PUIDPointerShapeView` renders at
  the pointer's spot in landscape.

The decisive observations:

- Any `CAShapeLayer` with a non-rectangular path, fill or mask, is missing from
  the scanout when its window is not rotated with the interface. This holds in
  pointeruid's tree, in pointeruid's top window and in SpringBoard's
  portrait-fixed `SSScreenshotsWindow`. A rect path renders. The same shape in
  SpringBoard's rotated status-bar window renders.
- A shape rendered offscreen (for example while the idle blur is on) appears.
- Setting the CA display orientation to portrait makes every shape render (and
  desynchronises the pointer's position, so it is not a fix).

## Root cause: a rotated framebuffer without compression

The render path reads the display orientation in exactly one place that
matters, `CA::OGL::MetalContext::get_surface(CA::WindowServer::Surface*, bool)`
(QuartzCore, local symbol
`__ZN2CA3OGL12MetalContext11get_surfaceEPNS_12WindowServer7SurfaceEb`):

```
0x184463b14  bl    _CADeviceUseFramebufferCompression
0x184463b18  mov   x26, x0
0x184463b1c  ldr   x0, [x21, #0x280]            ; the context's display
0x184463b20  cbz   x0, normal
             …   vtable call, compression folded in
0x184463b4c  tbnz  w8, #0, normal               ; compression, or no display
0x184463b50  ldrb  w8, [x24, #0x110]            ; WindowServer surface flags
0x184463b54  tbnz  w8, #2, rotated              ; ← patched to nop
0x184463b58  normal: mov w19, #0 ; mov w26, #0  ; panel-native surface
…
0x184463d64  rotated:
             ldrh  w8, [x0, #0x2c8]             ; display orientation
             mov   w9, #0xfd
             and   w8, w8, w9
             cmp   w8, #1                        ; landscape (1 or 3)
             cset  w19, eq
```

On the rotated path, when the surface's rotation flag (MetalSurface `+0x13c`
bit 10) disagrees with the orientation, CA finalizes the surface textures,
swaps width and height, and creates the framebuffer texture with
`-[MTLTextureDescriptor setRotation:3]` (`0x184463c54`), `setFramebufferOnly:`,
`setUsage:` and `newTextureWithDescriptor:iosurface:plane:`.

Real iPads report framebuffer compression and always take the normal path:
they render into a panel-native framebuffer and rotate the content in the
layer render. `CADeviceUseFramebufferCompression` comes from
`CADeviceUseCompression` and the `CAEnableFramebufferCompression` preference
(which only applies with CIF10), and it is false on the paravirtual GPU. So a
landscape iPad guest scans out of a rotated texture, and in that texture the
paravirtual GPU drops shape-layer path coverage from every layer that is not
itself rotated with the interface. The pointer's arrow is exactly such a layer.

Turning compression on instead would change far more of the render path on a
GPU that has never run it, and setting the display orientation to portrait
breaks backboardd's hit testing (`-[CAWindowServerDisplay hitTestAtPosition:]`
is the other reader of `+0x2c8`).

## The patch

`dyld-cfw-quartzcore_unrotated_framebuffer` (Guest Display set, iOS 27 bases,
default on; blocked in the tvOS, HomeView, HomePod and visionOS presets, which
have no validated port) replaces the `tbnz w8, #2, rotated` with a `nop`.
The fall-through is the compression path. A surface that was already rotated
is finalized and recreated by that path on its next frame, because it checks
the same `+0x13c` bit 10 and clears it. The display orientation is untouched.

Implementation: `DyldSharedCacheQuartzCoreUnrotatedFramebufferPatcher`, verb
`vphone-cli cfw patch-quartzcore-unrotated-framebuffer`.

### Reveal procedure

1. Resolve `get_surface` (local symbol; the `.symbols` side file is required)
   and `_CADeviceUseFramebufferCompression` in
   `/System/Library/Frameworks/QuartzCore.framework/QuartzCore`.
2. Disassemble `get_surface` up to the next symbol (at most 8 KiB).
3. After each direct `bl` to the compression query, within 24 instructions and
   before any return, find `ldrb wN, [xS, #imm]` immediately followed by
   `tbnz wN, #2, target`.
4. Require `target` to be the orientation test: `ldrh wA, [x0, #imm]`,
   `mov wB, #0xfd`, `and wA, wA, wB`, `cmp wA, #1`.
5. Require exactly one site. A `nop` in the branch slot is the patched form,
   accepted only while the orientation test is still in the function and no
   branch reaches it.
6. Write `ARM64.nop`, then re-attest the one code page.

### Validation

- Real-cache test (`VPHONE_IPAD27_CACHE_FIXTURE` pointing at the `24A446`
  iPad16,1 cache): discovery lands on `0x184463b54` (`88 10 10 37` →
  `1f 20 03 d5`), the page re-attests, a second run is a no-op and the undo log
  restores the original bytes.
- Live, before the installer patch existed: the same nop was written into the
  running `backboardd` (the render server) with lldb. On the next frames the
  landscape scanout showed the pointer and every test shape that had been
  invisible, and the rest of the landscape interface rendered unchanged.
- Pending: a guest installed with the patch through `cfw install`, checked in
  all four orientations, including an app that rotates itself.

## Open questions

- Whether iPadOS 26 iPad guests have the same symptom. The gate is the same
  idea, but no 26 cache was checked, so the patch is gated to 27.
- Why the paravirtual GPU loses only shape coverage in a rotated texture. The
  patch avoids the rotated texture rather than fixing that path.
