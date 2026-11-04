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

A cloudOS after the 26.4 beta has no vphone600 components, so the research board stands in (see [Compatibility](compatibility.md#which-cloudos-to-use)). Its kernelcache is rebuilt with the vphone600 virtualization kexts. KDK extraction runs natively as you; only the kmutil link needs root.

1. Run `fw prepare` as usual.
2. Stage the mix as yourself:

   ```sh
   vphone-cli fw kernelcache myphone
   ```

3. Link it as root:

   ```sh
   sudo vphone-cli fw kernelcache myphone
   ```

4. Continue with `fw patch`, which takes the mix from the cache.

The old `--ipsw` argument of `fw kernelcache` is still accepted but ignored.

## Linking on another Mac

A kernel boots only in the layout Apple linked it with, and kmutil takes the layout from the Mac it runs on:

| Host macOS | Links |
| --- | --- |
| macOS 26.4 and later | iOS 26.4 and later kernelcaches (kernel-last) |
| macOS 15, and 26.0 to 26.3 | older kernelcaches (kernel-first), such as iOS 18 |

When this Mac has the other layout, another Mac or a macOS VM links the mix over ssh. Set these for `fw kernelcache` or for the creation:

```sh
export VPHONE_KMUTIL_SSH='user@host'
export VPHONE_KMUTIL_SSH_PASSWORD='password'   # only without ssh keys and passwordless sudo there
```

The staged volume is uploaded to that Mac's `/private/var/tmp`, linked there as root, and removed. Nothing on this Mac needs root for it. On the other Mac, Remote Login must be on, and the user must be allowed to use sudo.

## See also

- [Firmware compatibility](compatibility.md)
- [Create and run a machine](../machines/create-and-run.md)
- [Library, firmware and backups](../storage/library-and-backups.md)
- [Kernelcache recipes](../../../VPhoneExecutable/VPhoneVirtualization/Resources/kernelcache_recipes/README.md)
