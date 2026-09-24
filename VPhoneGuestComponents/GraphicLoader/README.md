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
The Xcode app build stages it in `Contents/MacOS`.
`fw prepare` copies that dylib alongside the
firmware-sourced GPU driver before exposing the complete restore tree.
