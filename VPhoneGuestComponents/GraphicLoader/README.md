# PCC GPU component

`AppleParavirtGPUMetalIOGPUFamily.bundle` is Apple firmware content. Its
compiler plugin is built from source in this directory.

`vphone-cli fw prepare` creates a temporary PV=3 VM, boots it into DFU, and
restores the selected cloudOS IPSW with the project's in-process idevicerestore
backend. The CLI mounts its sealed System volume read-only, stages the GPU
bundle inside the iPhone restore tree, and removes the temporary VM. An explicit
`--gpu-driver-bundle` reuses a validated bundle instead. JB installation copies
the staged bundle into the iPhone guest. The driver therefore comes from the
same PCC release used for the VM's kernel.

The cloudOS 26.4 `23E5207q` bundle recovered from its restored System volume
has `DTPlatformVersion=26.4`, `CFBundleVersion=64.4.4`, and no
`libAppleParavirtCompilerPluginIOGPUFamily.dylib`. Without it,
`MTLCompilerService` repeatedly aborts and `backboardd` reports interrupted
Metal compilation, leaving the host VM window black even while vphoned connects.

`main.mm` is the compiler-plugin reimplementation from
[0xjohnnydev's metal-patch](https://github.com/0xjohnnydev/0xjohnnydev.github.io/blob/main/blog/assets/metal-patch/main.mm).
`make -C VPhoneGuestComponents gpu` builds and ad-hoc signs it for iPhoneOS arm64e.
The Xcode bundle build stages it in `Contents/Resources/guest-resources`.
`fw prepare` copies that dylib alongside the
firmware-sourced GPU driver before exposing the complete restore tree.
An installed guest without a restore tree gets a changed plugin from
`cfw update-environment`, which replaces it when the bundle's differs.

`GLESAIR.mm` completes the argument metadata of AIR modules AppleMetalGLRenderer
builds for OpenGL ES, and `main.mm` supplies missing `air.version` metadata
before GPUCompiler consumes them. The original missing fields caused GLES
shader compilation to crash `MTLCompilerService`. This includes ES1 generated
programs, identified by `OpenGL ES Program`, as well as `OpenGL ES GLSL`.

The compiler also converts GLES fragment `air.point_coord` Y to `1-y` because
the supported PV render-pass path does not honor the private Y-flip flag that
AppleMetalGLRenderer requests. It accepts half2 and float2 inputs, preserves X,
and records a module marker to avoid repeated conversion. This compensation
must be revisited if PV gains native support for the render-pass flag.

`make -C VPhoneGuestComponents test-gles-air` runs captured modules through the
plugin and into host Metal, checking pixels, scope and idempotence. The retained
[AIR tests](../Tests/GLESAIRTests.mm) record fixture origins and the coordinate
oracle. See [OpenGL ES research](../../Research/Guest/gpu_acceleration.md#opengl-es)
for the native guest results and limits of these host checks.
