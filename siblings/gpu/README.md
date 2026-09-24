# PCC GPU component

`AppleParavirtGPUMetalIOGPUFamily.bundle` is Apple firmware content. There is
no source here to compile and no binary to package in `vphone-cli.app`.

`vphone-cli fw prepare` reads the vphone600 OS path from the selected PCC
`BuildManifest.plist`, decrypts and mounts that image when Apple serves its AEA
key, and stages the complete bundle inside the VM restore tree. If that key is
unavailable, `vphone-cli` creates its own temporary PV=3 VM, boots it into DFU,
and restores the selected cloudOS IPSW with the project's in-process
idevicerestore backend. The CLI mounts its sealed System volume read-only,
copies the bundle, and removes the temporary VM. JB installation copies the
staged bundle into the iPhone guest. The driver therefore comes from the same
PCC release used for the VM's kernel.

The cloudOS 26.4 `23E5207q` bundle recovered from its restored System volume
has `DTPlatformVersion=26.4`, `CFBundleVersion=64.4.4`, and no
`libAppleParavirtCompilerPluginIOGPUFamily.dylib`. The older 26.1 bundle has
that dylib. Neither is compiled by this project; the installer preserves the
files Apple actually provides for the selected release.
