# Templates

[Documentation](../README.md) · [Create and Run](create-and-run.md) · [Building and finding templates](template-building.md) · [Library and backups](library-and-backups.md)

A template is a complete machine kept in `<library>/.templates/<id>/`. It boots once while it is built, its setup boot, and never again once it is frozen. `vm create` without `--no-template` works out the template key from its options and the two IPSWs before anything is restored: the guest device, the iOS and cloudOS versions and builds, the patch preset and the boot-chain patches it resolves to (every patch it resolves to, guest ones included, for a preset the bundle does not ship: a preset file or one in `~/.vphone/patches_presets` can change under the same identifier, and a clone keeps its template's guest patches), the bundle series (`2.9` for 2.9.x), the disk size, what is trimmed from the guest's System volume (`--trim`), and the slimming switches below. Then:

- If a template with that key exists, the VM is cloned from it with a new identity, given the requested CPU, memory and network, and booted once to check vphoned. This takes seconds and needs neither root nor the IPSWs; nothing is downloaded. The builds come from the IPSWs when they are local files or already in the IPSW cache, and otherwise from a template recorded with the same two sources, as [`vm template find`](template-building.md#finding-a-template) works them out; a local IPSW that has been deleted counts as not there.
- Otherwise the IPSWs are downloaded if they are not there, and the full pipeline runs into a staging folder, `.templates/.building-<id>-<uuid>/`: `cfw install`, the offline trim, then the setup boot; the result is frozen and renamed to `.templates/<id>/` in one step, and the VM is cloned from it. The restore tree is removed before the freeze whatever `--keep-artifacts` says: a template never keeps it, because its ~11 GB would stay pinned for as long as the template lives and no clone can use it. `--keep-artifacts` keeps it only with `--no-template`, and `vm template adopt` removes it too. A second `vm create` with the same key waits for the first instead of restoring a second copy. A failed build stays in its staging folder for inspection.

```sh
vphone-cli vm create phone-a --iphone-source … --cloudos-source …   # builds the template, clones phone-a
vphone-cli vm create phone-b --iphone-source … --cloudos-source …   # clones phone-b, no restore
vphone-cli vm create phone-c --template 3f2a91c0d4e7 --cpu 4 --memory 6144
```

`--template <id>` clones from a template by its identifier (or a unique prefix of four or more digits) and takes no IPSW options. `--device`, `--preset`, `--disk-size` and the slimming switches, when given, must match the template's; a clone cannot change them. CPU, memory, screen and network are not part of the key.

## Offline trim

After `cfw install`, a template build deletes system files the guest never needs from its System volume, offline, with the volume mounted on the host. `--trim` on `vm create` (default `standard`) and `--tier` on `vm template trim` pick the tier:

| Tier | Deletes | About |
| --- | --- | --- |
| `none` | nothing | |
| `conservative` | the contents of `usr/standalone/update` (software-update ramdisk, baseband firmware) | 0.35 GB |
| `standard` | conservative, plus the AirPods/Beats pairing assets (`PreinstalledAssetsV2/RequiredByOs/com_apple_MobileAsset_SharingDeviceAssets`), the watch faces (`NanoTimeKit/FaceBundles`) and the `LinguisticData/RequiredAssets_*.bundle` of every language not kept | 1.2 GB |
| `aggressive` | reserved: refused until it has been validated on a guest | |

`--keep-languages` (default `en,zh-Hans,zh`; English is always kept) chooses the languages standard keeps. The tier, the version of the list and the kept languages are part of the template key (`standard/1/en,zh,zh-Hans`), so templates trimmed differently never match. Trimming cannot be undone: a clone cannot get the files back.

The deleted files free nothing at first. The guest's original system snapshot (`orig-fs.disabled.rn-*`, left by `cfw install`) still holds every block, and the host cannot delete it, even as root. The setup boot deletes it as its first step, and only then is the space returned. So a trim is refused for a template that gets no setup boot, and a trimmed template is frozen or adopted only once its snapshot is gone. `vm template trim` needs no root, runs on a stopped machine that has not been cloned from a template, or on an unfinished `.building-…` folder, and refuses a frozen template.

## Setup boot and slimming

The setup boot finishes the template the way every clone should start. It boots the template once and, through vphoned, in this order:

1. deletes the `orig-fs.disabled.rn-*` APFS snapshot `cfw install` left (it holds about 20 MB, and every file trimmed from the System volume until it is gone);
2. skips Setup Assistant (`setup.skip`);
3. waits for first-boot work to settle (`setup.settle`, up to 10 minutes): installd expands the removable system apps on the first boot;
4. removes the system apps (`apps.remove_system`, backups kept in the guest);
5. applies the service profile (`services.profile.apply`), which includes turning off the sign-in follow-up daemons (`followupd`, `appleidsetupd`);
6. reboots, then checks: no snapshot left, Setup done, none of the profile's services running, the removed apps gone, vphoned answering;
7. clears the device name `vphone-vm` pinned for this boot, and shuts the guest down cleanly.

Every step has a deadline. A failed step stops the VM, records nothing and leaves the build unfrozen; `vm create` names the step and how to retry it.

| Switch | Default | Effect |
| --- | --- | --- |
| `--slim on\|off` | on | `off` trims nothing and keeps every app and service. The setup boot still runs: Setup is skipped and the snapshot deleted. |
| `--trim none\|conservative\|standard` | standard | The offline trim above. |
| `--keep-languages <list>` | `en,zh-Hans,zh` | The languages `--trim standard` keeps. |
| `--service-profile trimmed\|none` | trimmed | vphoned's trimmed profile: about 140 launchd jobs off, the App Store daemons and sign-in follow-up among them. A phone with this profile cannot pair an Apple Watch (see `Research/Guest/watch_pairing.md`). |
| `--remove-apps on\|off` | on | Removes App Store, Home, TV, News, FaceTime, iTunes Store, Messages, Games, Find My and Wallet. Camera and Phone stay. |
| `--keep-apps <ids>` | none | Bundle IDs from that list to keep, comma-separated (`com.apple.findmy,com.apple.Passbook`). |
| `--accounts-off` | off | Also turns off `akd`, `amsaccountsd` and `appleaccountd`. The guest then cannot sign in to an Apple Account. |

Each choice is part of the key, so templates with different slimming live side by side and each serves only the creates that ask for it. Removed apps and the profile stay reversible on a clone: `apps.restore_system` puts an app back from its backup, and `services.profile.apply {"profile":"none"}` turns back on exactly what the profile turned off (both through `vphone-launchpad-cli guest rpc`, or Guest System in Launchpad).

What every clone inherits from the template: Setup done, the apps and services as the setup boot left them, the first-boot work installd and the indexers did, and the Data volume as of that boot. It does not inherit a device name: the template's pin is cleared, so a clone shows `iPhone` until its own VM connects and pins the clone's name. A new identity also means the Mac asks "Trust This Computer?" again.

To turn a VM into a template by hand, ask which template a `vm create` would use, or see how Launchpad builds them, read [Building and finding templates](template-building.md).

## Shared secrets

Every machine cloned from one template shares, with the template and with each other, its SEP root secret, its Data volume keys and the data the restore and the setup boot wrote. One clone could in principle decrypt another's Data volume. A VM that needs keys of its own, for example to sign in to Apple services for multi-device research, should be created with `--no-template` (which takes no slimming switches). Clones get a new ECID, UDID and MAC address on their first start, as with `vm clone --new-identity`, and share every unchanged block with the template on APFS: a new clone costs almost nothing until it starts writing, and a slimmed template leaves it little first-boot work to write.

```sh
vphone-cli vm template list              # id, key summary, STALE with the reasons
vphone-cli vm template show <id> --json
vphone-cli vm template trim myphone --tier standard   # trim a stopped VM before adopting it
vphone-cli vm template setup myphone     # the setup boot, on a stopped VM
vphone-cli vm template adopt myphone     # freeze a stopped, newly created VM into a template
vphone-cli vm template delete <id>
```

- **Stale.** A template is listed as stale when this `vphone-cli` belongs to another bundle series, when its key has an older format, when its preset now resolves to other boot-chain patches, or when its patch receipt disagrees with its plan. A stale template is never used: `vm create` with its key fails and names it. Delete it to have the next `vm create` build a new one.
- **Adopt.** `vm template adopt <vm>` turns a stopped VM into a template, under the key its own records give (`restore-info.json`, `PatchPlan.plist`, `config.plist`, the disk image, Launchpad's `launchpad.json`, and the steps `vm template trim` and `vm template setup` recorded in its `Template.plist`). The VM leaves `vm list`. Adopt a VM straight after its setup boot: every clone inherits what its guest has done since. A VM with snapshots is refused, and so is one that would be stale unless `--force` is given.
- **Never booted once frozen.** `vm launch` and `vphone-vm` refuse a frozen template, in DFU too; no machine name reaches into `.templates`, so `vm launch`, `clone`, `export`, `rename` and `delete` cannot pick one up by accident. A template that booted after being frozen would write state into the blocks every later clone inherits, and the clones made before it would stop sharing them.
- **Machines using it.** A machine cloned from a template records the template in `TemplateSource.plist`; a `vm clone` of it keeps the record (the copy shares the template's blocks too) and `vm export` leaves it out (an import shares nothing). The record also names the template's build, so a template deleted and built again with the same key does not count the machines cloned from the old one, which share none of its blocks. `vm template list` and `show` list the machines using each template and its size on disk, and `vm info` shows a machine's template. When `vm delete` removes the last machine cloned from a template that still exists, it says so, and never deletes the template itself:

  ```
  note: template 3f2a91c0d4e7 (~17.40 GB) is no longer used by any machine; remove it with `vphone-cli vm template delete 3f2a91c0d4e7`
  ```
- **Deleting.** `vm template delete <id>` removes the template; machines cloned from it keep working. The blocks they still share with it are freed only when those machines change them or are deleted, so deleting a template frees less than its size while clones remain. The note it prints says which: the machines that use it, whose shared blocks stay allocated until they change them or are deleted, or that no machine uses it now, so deleting frees its blocks, though a local Time Machine snapshot taken while it existed may keep them until the snapshot expires. `--json` with `--force` prints the same facts. Templates take disk space although `vm list` does not show them; look in `~/.vphone/machines/.templates`, keeping in mind that `du` counts a template and each of its clones in full.
