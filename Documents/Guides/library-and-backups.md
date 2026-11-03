# Library, firmware and backups

[Documentation](../README.md) · [Create and Run](create-and-run.md) · [Sharing disk space](sharing-disk-space.md) · [Snapshots](snapshots.md)

| Default path | Contents |
| --- | --- |
| `~/.vphone/machines/<name>/` | One VM, including its disk, `config.plist`, and patch work files |
| `~/.vphone/ipsws/` | Remote source IPSWs, shared by every VM; local IPSWs are read in place |
| `~/.vphone/gpu-drivers/<version>_<build>/` | GPU driver bundles extracted from cloudOS, shared by every VM |
| `~/.vphone/kernelcache/` | Kernelcache mixes for cloudOS releases without vphone600 components, their staged volumes and the donor extraction |

`VPHONE_ROOT` relocates the VM library and both caches. `VPHONE_LIBRARY_ROOT` takes precedence for the library alone, and `--ipsw-cache <dir>` on `vm create` and `fw prepare` for the IPSW cache alone. Downloaded IPSWs stay cached until you delete them (in Launchpad, with File > Downloaded IPSWs…), so a second VM from the same URL downloads nothing; the prepared restore tree is removed after a successful `vm create` unless `--keep-artifacts` is set. VMs prepared by an earlier build may still hold a `.ipsw-cache/` directory; it is safe to delete, and `vm export` leaves it out.

A remote IPSW downloads over four connections at once when its server answers HTTP range requests, as Apple's CDN does; each connection fetches 32 MB segments in turn and resumes a dropped segment where it stopped. `--download-connections <n>` on `fw prepare` sets the count (1 to 16); 1 downloads the IPSW as a single stream, which is also what a server that ignores ranges gets.

```sh
vphone-cli vm list
vphone-cli vm info myphone
vphone-cli vm clone myphone copy
vphone-cli vm clone myphone second --new-identity
vphone-cli vm export myphone --out myphone.tzst
vphone-cli vm import myphone.tzst --name restored
```

`vm clone` copies a stopped machine, using APFS copy-on-write when available; it refuses while the source runs. A plain copy keeps everything, including the device identity (machine identifier and MAC address), so it is a backup and cannot run beside the original.

`--new-identity` makes a second device instead. The copy gets a new machine identifier (ECID), and with it a new UDID, and a new MAC address on its first start. Its fixed IPv4 address, port forwards and a hand-chosen mDNS name are cleared, since they would collide with the original's; an mDNS name `--mdns on` derived from the original's name follows the new name, as on rename. Set new ones with `vm config` if you need them. The guest keeps the original's data, apps and settings, and no restore is needed. Before lockdown tools such as `ideviceinstaller` work, unlock the copy and trust this Mac again. On APFS a copy shares its disk blocks with the original and holds only what it changes, about 0.35 GB after its first boots, although `du` and Finder report the full size for each.

Do not swap `SEPStorage`, `nvram.bin` or the disk image between machines: they were made together by one restore, and a guest whose SEP storage does not match its disk panics at boot.

Run resource-heavy creations **one at a time**. Both the IPSWs and temporary restore tree consume substantial disk space, and patching large caches can be memory intensive. Check free space before starting a second VM. Launchpad places CFW scratch files on the VM library's mounted external volume when applicable; standalone `vphone-cli cfw install` defaults to `/private/var/tmp` and accepts `--work-parent` for a root-owned private directory.
