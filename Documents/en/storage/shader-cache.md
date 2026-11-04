# Persistent shader caches

Machines keep their compiled GPU shaders between boots, so animations lag only while shaders compile on the first runs. Read this page to turn the cache on for an existing machine or to reset it.

New machines created with the Standard preset enable the Task3 kernel patch and guest Metal cache reuse automatically. The host saves its cache in `<machine>/ShaderCache`, for example `~/.vphone/machines/Lychee/ShaderCache`. A changed executable gets a new host cache identity.

## Turn it on for an existing machine

Install a Core Bundle that contains this feature, and bind the stopped machine to it. Then update the guest environment and the kernel. Both updates keep the guest's data; no restore or `fw patch` is needed.

### In Launchpad

1. Choose **Update Guest Environment** from the machine's actions menu.
2. Choose **Update Kernel** in its **Patches** inspector.

Standard now selects **GPU Task3 shader cache** automatically. An explicit per-machine opt-out is preserved; if the patch was unchecked, enable it in the editor first.

### With the Launchpad CLI

```sh
# Replace <version> with the installed Core Bundle version from bundle list.
vphone-launchpad-cli vm stop Lychee
vphone-launchpad-cli vm set-bundle Lychee <version> --update-environment
vphone-launchpad-cli cfw update-kernel Lychee
vphone-launchpad-cli vm start Lychee --wait
```

- `--update-environment` redeploys the guest libraries and the cache-reuse marker.
- `cfw update-kernel` re-patches the pristine kernel in `FirmwareOriginals` with the current selection and replaces the kernelcache in Preboot.

Changing the Core Bundle binding alone does not update the installed kernel.

### With vphone-cli alone

With the machine off, run the new bundle's commands with root authorization:

```sh
sudo vphone-cli cfw update-environment Lychee
sudo vphone-cli cfw update-kernel Lychee
```

`vphone-cli fw patches Lychee` shows pending patches. Both update commands apply the machine's current selection, including any other pending guest or kernel changes.

### Older machines without a pristine kernel

A machine with no pristine kernel in `FirmwareOriginals` needs `fw prepare` and `fw patch` with the new bundle first, so the fallback restore tree contains the updated kernel. Then run `cfw update-kernel`. Do not run `restore`.

## Reset the host cache

Stop the machine, then delete its `ShaderCache` directory. The next launch starts a fresh host cache.

Guest Metal caches are separate files inside `Disk.img`, so clearing the host cache does not necessarily reproduce all first-run lag.

## Limits

- Task3 applies to cloudOS 26.4 kernels only and is disabled in the tvOS presets.
- On a host older than macOS 27, the guest negotiates the host's own maximum version and keeps that version's features, so the host cache stays per-boot there.
- Runtime validation covered macOS 27.0.1, cloudOS 26.4, and iOS 27.0.1 and 26.6.2 guests. Older hosts were checked from their framework code, not run.

## See also

- [Core Bundles](../launchpad/core-bundles.md)
- [Launchpad CLI](../launchpad/launchpad-cli.md)
- [Library, firmware and backups](library-and-backups.md)
