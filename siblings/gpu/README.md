# PCC GPU component

`AppleParavirtGPUMetalIOGPUFamily.bundle` is Apple firmware content. There is
no source here to compile and no binary to package in `vphone-cli.app`.

`vphone-cli fw prepare` reads the vphone600 OS path from the selected PCC
`BuildManifest.plist`, decrypts and mounts that image with macOS system tools,
and stages the complete bundle inside the VM restore tree. JB installation
copies the staged bundle into the guest. The compiler-plugin dylib and driver
executable therefore always come from the same PCC release used for the VM's
kernel.
