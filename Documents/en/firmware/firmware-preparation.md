# Firmware preparation

What `vm create` and `fw prepare` do with the two IPSWs before the firmware is patched, and the extra steps a cloudOS without vphone600 components needs. Read it when you run the stages by hand, reuse a GPU driver, or create a machine on a research-board pairing.

## The GPU driver

`fw prepare` needs the paravirtual GPU driver from the cloudOS before it can build the hybrid iPhone restore. It gets it like this:

1. It creates a temporary vphone VM with no network device and starts it in DFU.
2. It restores the selected cloudOS IPSW into it with vphone's own restore backend.
3. It mounts the restored System volume read-only and extracts the GPU bundle.
4. It removes the temporary VM.

The extracted bundle is cached per cloudOS build in `~/.vphone/gpu-drivers/`, so later machines on the same cloudOS skip the temporary restore.

To reuse a bundle you extracted earlier, pass it to `vm create` or `fw prepare`:

```sh
vphone-cli fw prepare myphone \
  --gpu-driver-bundle /path/to/AppleParavirtGPUMetalIOGPUFamily.bundle
```

The CLI checks the bundle's iPhoneOS platform version against the selected cloudOS version. Each restore obtains its own ticket online.

The bundle also ships an arm64e GPU compiler plugin. `fw prepare` copies it into the staged GPU bundle before patching and installation.

## Research-board pairings

A cloudOS after the 26.4 beta has no vphone600 components, so the research board stands in (see [Compatibility](compatibility.md#which-cloudos-to-use)). Its kernelcache is rebuilt with the vphone600 virtualization kexts. Everything runs as you, without sudo.

1. Run `fw prepare` as usual.
2. Build the mix:

   ```sh
   vphone-cli fw kernelcache myphone
   ```

3. Continue with `fw patch`, which takes the mix from the cache. `fw patch` also builds the mix itself when it runs as you; as root it only takes it from the cache.

The old `--ipsw` argument of `fw kernelcache` is still accepted but ignored.

## The kmutil that links the mix

A kernel boots only in the layout Apple linked it with, and that layout comes from the kmutil that links it: macOS 15 and 26.0 to 26.3 put the kernel first, macOS 26.4 and later put it last, and macOS 27 keeps the kexts' auth stubs. Every kernelcache records the kmutil version Apple built it with, so `fw kernelcache` links the mix with that same version, on any macOS:

| Kernelcaches | kmutil | from |
| --- | --- | --- |
| iOS 18.1 to 18.3.1 | 463.40.2 | macOS 15.1 (24B83) |
| iOS 18.5 to 18.7.2 | 463.100.7 | macOS 15.6.1 (24G90) |
| iOS 26.4 to 26.7, watchOS 26.4, HomePod 26.5 | 487.100.11 | macOS 26.5 (25F71) |
| iOS 27.2 | 514.40.8 | macOS 27.2.1 (26B131) |

When this Mac's own kmutil is that version, it is used. Otherwise the recovery image of that macOS (about 1 GB) is downloaded once from Apple's IPSW, and its kmutil and kernel collection builder are kept in `~/.vphone/kernelcache/kmutil/<version>` (a few MB); the image is deleted. Nothing is installed and no host setting changes. `VPHONE_KMUTIL_SSH`, another Mac that linked over ssh, is no longer used.

## See also

- [Firmware compatibility](compatibility.md)
- [Create and run a machine](../machines/create-and-run.md)
- [Library, firmware and backups](../storage/library-and-backups.md)
- [Kernelcache recipes](../../../VPhoneExecutable/VPhoneVirtualization/Resources/kernelcache_recipes/README.md)
