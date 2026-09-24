# PCC GPU component

`AppleParavirtGPUMetalIOGPUFamily.bundle` is Apple firmware content. There is
no source here to compile and no binary to package in `vphone-cli.app`.

`vphone-cli fw prepare` creates a temporary PV=3 VM, boots it into DFU, and
restores the selected cloudOS IPSW with the project's in-process idevicerestore
backend. The CLI mounts its sealed System volume read-only, stages the GPU
bundle inside the iPhone restore tree, and removes the temporary VM. An explicit
`--gpu-driver-bundle` reuses a validated bundle instead. JB installation copies
the staged bundle into the iPhone guest. The driver therefore comes from the
same PCC release used for the VM's kernel.

The cloudOS 26.4 `23E5207q` bundle recovered from its restored System volume
has `DTPlatformVersion=26.4`, `CFBundleVersion=64.4.4`, and no
`libAppleParavirtCompilerPluginIOGPUFamily.dylib`. The older 26.1 bundle has
that dylib. Neither is compiled by this project; the installer preserves the
files Apple actually provides for the selected release.
