# Library, firmware and backups

Where vphone keeps machines and downloaded firmware, how to move them, and how to copy, back up and restore a machine. Read it when you plan disk space, relocate the library, or need a second copy of a machine.

## Back up, copy and restore

```sh
vphone-cli vm list
vphone-cli vm info myphone
vphone-cli vm clone myphone copy                    # backup: same identity
vphone-cli vm clone myphone second --new-identity   # a second device
vphone-cli vm export myphone --out myphone.tzst
vphone-cli vm import myphone.tzst --name restored
```

`vm clone` copies a stopped machine, using APFS copy-on-write when available. It refuses while the source runs.

| Clone | Identity | Use |
| --- | --- | --- |
| Plain `vm clone` | Same machine identifier and MAC address | A backup. It cannot run beside the original. |
| `vm clone --new-identity` | New machine identifier (ECID), and with it a new UDID; new MAC address on its first start | A second device that runs beside the original |

A `--new-identity` copy:

- clears its fixed IPv4 address, port forwards and a hand-chosen mDNS name, since they would collide with the original's. An mDNS name that `--mdns on` derived from the original's name follows the new name, as on rename. Set new ones with `vm config` if you need them.
- keeps the original's data, apps and settings; no restore is needed.
- needs you to unlock it and trust this Mac again before lockdown tools such as `ideviceinstaller` work.
- shares its disk blocks with the original on APFS and holds only what it changes, about 0.35 GB after its first boots, although `du` and Finder report the full size for each.

> [!WARNING]
> Do not swap `SEPStorage`, `nvram.bin` or the disk image between machines. One restore made them together, and a guest whose SEP storage does not match its disk panics at boot.

## Where files live

| Default path | Contents |
| --- | --- |
| `~/.vphone/machines/<name>/` | One VM, including its disk, `config.plist`, and patch work files |
| `~/.vphone/ipsws/` | Remote source IPSWs, shared by every VM; local IPSWs are read in place |
| `~/.vphone/gpu-drivers/<version>_<build>/` | GPU driver bundles extracted from cloudOS, shared by every VM |
| `~/.vphone/kernelcache/` | Kernelcache mixes for cloudOS releases without vphone600 components, their staged volumes and the donor extraction |

To move them:

| Setting | Moves |
| --- | --- |
| `VPHONE_ROOT` | The whole `~/.vphone` data root: the machine library and the caches |
| `VPHONE_LIBRARY_ROOT` | The machine library alone; takes precedence over `VPHONE_ROOT` |
| `--ipsw-cache <dir>` on `vm create` and `fw prepare` | The IPSW cache alone |

## IPSW cache and downloads

Downloaded IPSWs stay cached until you delete them, so a second machine from the same URL downloads nothing. In Launchpad, delete them with **File > Downloaded IPSWs…**.

The prepared restore tree is removed after a successful `vm create` unless you pass `--keep-artifacts`. Machines prepared by an earlier build may still hold a `.ipsw-cache/` directory; it is safe to delete, and `vm export` leaves it out.

A remote IPSW downloads over four connections at once when its server answers HTTP range requests, as Apple's CDN does. Each connection fetches 32 MB segments in turn and resumes a dropped segment where it stopped. `--download-connections <n>` on `fw prepare` sets the count, from 1 to 16. With 1 the IPSW downloads as a single stream, which is also what a server that ignores ranges gets.

## Disk space and memory

Run resource-heavy creations one at a time. The IPSWs and the temporary restore tree take substantial disk space, and patching large caches can use a lot of memory. Check free space before you start a second machine.

Launchpad places CFW scratch files on the library's mounted external volume when that applies. Standalone `vphone-cli cfw install` defaults to `/private/var/tmp` and accepts `--work-parent` for a root-owned private directory.

## See also

- [Snapshots](snapshots.md)
- [Templates](templates.md)
- [Sharing disk space between VMs](sharing-disk-space.md)
- [Create and run a machine](../machines/create-and-run.md)
