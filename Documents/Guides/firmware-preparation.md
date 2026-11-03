# Firmware preparation

[Documentation](../README.md) · [Create and Run](create-and-run.md) · [Compatibility](compatibility.md)

What `vm create` and `fw prepare` do with the two IPSWs before the firmware is patched.

`fw prepare` creates a temporary vphone VM with no network device, starts it in DFU, and restores the selected cloudOS IPSW using this project's restore backend. It mounts the restored System volume read-only, extracts the GPU bundle, then removes the temporary VM. This first restore supplies the GPU driver for the second, hybrid iPhone restore. The extracted bundle is cached per cloudOS build in `~/.vphone/gpu-drivers/`, so later machines on the same cloudOS skip the temporary restore. `vm create` and `fw prepare` also accept `--gpu-driver-bundle /path/to/AppleParavirtGPUMetalIOGPUFamily.bundle` to reuse a previously extracted bundle without the temporary restore. The CLI checks its iPhoneOS platform version against the selected cloudOS version. Each restore obtains its own ticket online.

A cloudOS after the 26.4 beta has no vphone600 components, and the research board stands in ([Compatibility](compatibility.md)). Its kernelcache is rebuilt with the vphone600 virtualization kexts. KDK extraction runs natively; only the kmutil link needs root. After `fw prepare`, stage the mix as yourself with `vphone-cli fw kernelcache <vm>`, link it with `sudo vphone-cli fw kernelcache <vm> --link-only`, and continue with `fw patch` as usual. The old `--ipsw` argument is still accepted but ignored.

A kernel only boots in the layout Apple linked it with, and kmutil takes the layout from the Mac it runs on: macOS 26.4 and later link the iOS 26.4+ kernelcaches (kernel-last), macOS 15 and 26.0–26.3 the older ones (kernel-first). When this Mac has the other layout, another Mac or a macOS VM links the mix over ssh: set `VPHONE_KMUTIL_SSH=<user>@<host>` (and `VPHONE_KMUTIL_SSH_PASSWORD=<password>` without ssh keys and passwordless sudo there) for `fw kernelcache` or the creation. The staged volume is uploaded to that Mac's `/private/var/tmp`, linked there as root and removed; nothing on this Mac needs root for it. Remote Login must be on, and the user must be allowed to use sudo.

The build also ships an arm64e GPU compiler plugin in the bundle. `fw prepare` copies it into the staged GPU bundle before firmware patching and installation.
