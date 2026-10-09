# Create and run a VM

[Documentation](../README.md) · [Host setup](host-setup.md) · [Compatibility](compatibility.md)

The public firmware workflow applies one complete patch set, including the former EXP changes; patch variants cannot be selected. It patches the boot chain and guest system, installs vphoned, and leaves the user's environment empty. It does not install Sileo, apt, TrollStore, an SSH server or VNC server.

## One-command flow

Supply an iPhone17,3 restore IPSW and a compatible PCC/cloudOS IPSW as local paths or URLs. [Compatibility](compatibility.md) records the pairs actually verified here.

```sh
vphone-cli host preflight
vphone-cli vm create myphone \
  --iphone-source /path/to/iPhone17,3_Restore.ipsw \
  --cloudos-source /path/to/cloudOS.ipsw
```

Creation runs prepare → firmware patch → online DFU restore → host-mounted CFW installation → first GUI boot. It needs network access for the restore ticket. The caller must provide root privileges for CFW installation; this bundle has no authorization dialog or privilege helper. The default virtual disk is 64 GB. `--keep-artifacts` retains the large prepared restore tree; omit it when disk space matters.

By default that pipeline builds a [template](#templates) rather than the VM itself, and the VM is cloned from it. The next `vm create` for the same device, iOS and cloudOS builds, preset and disk size clones from the same template instead of restoring again. Pass `--no-template` to build the VM on its own, as before.

`--cpu`, `--memory`, `--network` and `--unlock-at-startup` set those `vm config` settings on the new VM (defaults: 8 cores, 8192 MB, nat, off). `--skip-first-boot` leaves out the final boot, for a caller that boots the VM itself.

`fw prepare` creates a temporary vphone VM, starts it in DFU, and restores the selected cloudOS IPSW using this project's restore backend. It mounts the restored System volume read-only, extracts the GPU bundle, then removes the temporary VM. This first restore supplies the GPU driver for the second, hybrid iPhone restore. The extracted bundle is cached per cloudOS build in `~/.vphone/gpu-drivers/`, so later machines on the same cloudOS skip the temporary restore. `vm create` and `fw prepare` also accept `--gpu-driver-bundle /path/to/AppleParavirtGPUMetalIOGPUFamily.bundle` to reuse a previously extracted bundle without the temporary restore. The CLI checks its iPhoneOS platform version against the selected cloudOS version. Each restore obtains its own ticket online.

The build also ships an arm64e GPU compiler plugin in the bundle. `fw prepare` copies it into the staged GPU bundle before firmware patching and installation.

Success ends with `First boot: vphoned ping succeeded` and `JB VM created; vphoned connected`. **The verification VM is then stopped.** The ping proves the daemon answered over the host control socket during that boot; it does not leave a running VM behind.

```sh
vphone-cli vm launch myphone  # start the VM window and keep it running
vphone-cli vm stop myphone    # run from another terminal to stop it
```

Closing the VM window, ⌘Q, `vm stop` and Control-C in the `vm launch` terminal all shut the guest down first (vphoned `system.shutdown`) and end the virtual machine once the guest has stopped, or after 15 seconds if it has not. A guest vphoned cannot answer for, such as one in DFU or still starting up, is turned off at once, as pulling the power would. A second Control-C turns it off without waiting. `vm stop` only ever signals the machine's own processes, `vphone-vm` and Virtualization's VM service; another program that has the disk open, such as Launchpad measuring its size, Spotlight or a backup tool, is named and left running.

`vm launch` starts the guest without waiting for vphoned; the daemon connects during boot. The VM window and menu provide Home/power keys, app installation and file browsing. The host control socket is `<VM bundle>/vphone.sock`: one JSON line in, one out. Connections are served concurrently, and the socket also exists with `--no-graphics`, where `tap` and `swipe` go through vphoned's touch injection and screen images come from the guest. Besides `tap`, `swipe`, `key` and `screenshot`, `{"t":"rpc","method":"<vphoned method>","params":{…}}` calls any method in `Research/vphoned_http_api.md`. For example, `input.key` with `{"name":"cmd+v"}` pastes and `input.type` types text. No SSH or VNC endpoint is installed by this workflow.

## Device name

The guest shows the VM's name as its device name, in Xcode's device list and `xcrun devicectl list devices`, and cannot be renamed from inside the guest or from Finder, Xcode or `idevicename`: a rename there reports success and changes nothing. `vphone-vm` hands the name to the guest each time it connects to vphoned, a few seconds into every boot, and the guest keeps it for the next boot. After `vm rename`, Finder and `ideviceinfo` see the new name as soon as the machine is up; Xcode and `devicectl` read it when the device appears and may show the old name until the following boot. An existing machine moved to a bundle with this feature receives the guest library with its environment update and uses it from the boot after that. The guest's own name stays in its preferences, untouched. A VM name of more than 255 UTF-8 bytes, or with a control character, is not used, and the guest shows its own name. See `Research/Guest/device_name_pinning.md`.

## Templates

A template is a complete machine kept in `<library>/.templates/<id>/`. It boots once while it is built, its setup boot, and never again once it is frozen. `vm create` without `--no-template` works out the template key from its options and the two IPSWs before anything is restored: the guest device, the iOS and cloudOS versions and builds, the patch preset and the boot-chain patches it resolves to, the bundle series (`2.9` for 2.9.x), the disk size, what is trimmed from the guest's System volume (`--trim`), and the slimming switches below. Then:

- If a template with that key exists, the VM is cloned from it with a new identity, given the requested CPU, memory and network, and booted once to check vphoned. This takes seconds and needs neither root nor the IPSWs; nothing is downloaded. The builds come from the IPSWs when they are local files or already in the IPSW cache, and otherwise from a template recorded with the same two sources, as [`vm template find`](#finding-a-template) works them out; a local IPSW that has been deleted counts as not there.
- Otherwise the IPSWs are downloaded if they are not there, and the full pipeline runs into a staging folder, `.templates/.building-<id>-<uuid>/`: `cfw install`, the offline trim, then the setup boot; the result is frozen and renamed to `.templates/<id>/` in one step, and the VM is cloned from it. The restore tree is removed before the freeze whatever `--keep-artifacts` says: a template never keeps it, because its ~11 GB would stay pinned for as long as the template lives and no clone can use it. `--keep-artifacts` keeps it only with `--no-template`, and `vm template adopt` removes it too. A second `vm create` with the same key waits for the first instead of restoring a second copy. A failed build stays in its staging folder for inspection.

```sh
vphone-cli vm create phone-a --iphone-source … --cloudos-source …   # builds the template, clones phone-a
vphone-cli vm create phone-b --iphone-source … --cloudos-source …   # clones phone-b, no restore
vphone-cli vm create phone-c --template 3f2a91c0d4e7 --cpu 4 --memory 6144
```

`--template <id>` clones from a template by its identifier (or a unique prefix of four or more digits) and takes no IPSW options. `--device`, `--preset`, `--disk-size` and the slimming switches, when given, must match the template's; a clone cannot change them. CPU, memory, screen and network are not part of the key.

### Offline trim

After `cfw install`, a template build deletes system files the guest never needs from its System volume, offline, with the volume mounted on the host. `--trim` on `vm create` (default `standard`) and `--tier` on `vm template trim` pick the tier:

| Tier | Deletes | About |
| --- | --- | --- |
| `none` | nothing | |
| `conservative` | the contents of `usr/standalone/update` (software-update ramdisk, baseband firmware) | 0.35 GB |
| `standard` | conservative, plus the AirPods/Beats pairing assets (`PreinstalledAssetsV2/RequiredByOs/com_apple_MobileAsset_SharingDeviceAssets`), the watch faces (`NanoTimeKit/FaceBundles`) and the `LinguisticData/RequiredAssets_*.bundle` of every language not kept | 1.2 GB |
| `aggressive` | reserved: refused until it has been validated on a guest | |

`--keep-languages` (default `en,zh-Hans,zh`; English is always kept) chooses the languages standard keeps. The tier, the version of the list and the kept languages are part of the template key (`standard/1/en,zh,zh-Hans`), so templates trimmed differently never match. Trimming cannot be undone: a clone cannot get the files back.

The deleted files free nothing at first. The guest's original system snapshot (`orig-fs.disabled.rn-*`, left by `cfw install`) still holds every block, and the host cannot delete it, even as root. The setup boot deletes it as its first step, and only then is the space returned. So a trim is refused for a template that gets no setup boot, and a trimmed template is frozen or adopted only once its snapshot is gone. `vm template trim` needs no root, runs on a stopped machine that has not been cloned from a template, or on an unfinished `.building-…` folder, and refuses a frozen template.

### Setup boot and slimming

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
| `--service-profile trimmed\|none` | trimmed | vphoned's trimmed profile: about 140 launchd jobs off, the App Store daemons and sign-in follow-up among them. |
| `--remove-apps on\|off` | on | Removes App Store, Home, TV, News, FaceTime, iTunes Store, Messages, Games, Find My and Wallet. Camera and Phone stay. |
| `--keep-apps <ids>` | none | Bundle IDs from that list to keep, comma-separated (`com.apple.findmy,com.apple.Passbook`). |
| `--accounts-off` | off | Also turns off `akd`, `amsaccountsd` and `appleaccountd`. The guest then cannot sign in to an Apple Account. |

Each choice is part of the key, so templates with different slimming live side by side and each serves only the creates that ask for it. Removed apps and the profile stay reversible on a clone: `apps.restore_system` puts an app back from its backup, and `services.profile.apply {"profile":"none"}` turns back on exactly what the profile turned off (both through `vphone-launchpad-cli guest rpc`, or Guest System in Launchpad).

What every clone inherits from the template: Setup done, the apps and services as the setup boot left them, the first-boot work installd and the indexers did, and the Data volume as of that boot. It does not inherit a device name: the template's pin is cleared, so a clone shows `iPhone` until its own VM connects and pins the clone's name. A new identity also means the Mac asks "Trust This Computer?" again.

### Finishing a VM as a template

To turn a VM straight after creating it into a template, stop it, trim it, give it the setup boot, and adopt it. This is what Launchpad does for a template it has to build (below):

```sh
vphone-cli vm stop phone-src
vphone-cli vm template trim phone-src --tier standard   # offline, no root; frees nothing until the setup boot
vphone-cli vm template setup phone-src        # headless; --window to watch, slimming switches as for vm create
vphone-cli vm template adopt phone-src --iphone-source … --cloudos-source …   # key from its records; the sources are recorded
vphone-cli vm create phone-d --template <id> --skip-first-boot
```

`--iphone-source` and `--cloudos-source` on `vm template adopt` record the IPSWs the VM was created from in its `Template.plist`, as a `vm create` that builds a template does. `--json` prints the new template as `vm template show --json` does.

`--expect <id>` on `vm template adopt` refuses, and leaves the VM where it is, unless its records give the template identifier `<id>`: the `id` that `vm template find` printed for the options the VM was built with. Without the check, a VM whose setup boot fell short (an app it could not remove) would be saved under another key, and every later `vm create` with those options would miss it and build another template. The refusal names the fields that differ when it can work out the expected key, which it can when a template or build in the library has it or when only the slimming differs; otherwise it prints the VM's own key to compare. With `--json` the refusal is also printed to stdout as `{"adopted": false, "error": "unexpected_template", "id": …, "expected": …, "differences": […], …}`, and the command exits with status 1.

`vm template setup` refuses a running VM and a frozen template. It trims nothing itself: the tier `vm template trim` recorded is kept, and a `--trim` that names another tier is refused. On a VM it reports an app vphoned would not remove and leaves it out of the recorded steps, so the adopted key says what was really done. With `--strict` it fails instead, records nothing, and the setup boot can be run again: use it when the VM is to be adopted with `--expect` under the key `vm template find` gave for the same switches. Given a `.building-…` name from `vm template list` (a `vm create` whose setup boot failed), it sets the build up to its key, which fixes the slimming, runs the offline trim first if the build stopped before it, and freezes it on success.

### Finding a template

`vm template find` answers what template a `vm create` with the same options would clone from, without downloading, restoring or changing anything:

```sh
vphone-cli vm template find --iphone-source … --cloudos-source … [--device …] [--preset …] [--disk-size …] [--block <id>] [--allow <id>] [slimming switches] --json
```

It works out the key as `vm create` does. The builds come from the IPSWs when they are local files or already in the IPSW cache, and otherwise from a template whose record names the same two sources, so the key still resolves once the IPSWs were deleted, local ones included. `--block` and `--allow` are per-patch overrides as `fw set-patches` records them. The JSON has `resolved`, `resolvedBy` (`ipsw` or `template`), `id`, `summary`, `key`, `template` (the matching template as `vm template show --json` prints it, current or stale), `usable` (it exists and is current), `building` (a create holds its build lock) and, when unresolved, `reason`.

### In Launchpad

Launchpad 2.9 creates machines from templates by default. New Machine opens on a short page: the name, the device and iOS version from the firmware catalog, and a Slim System switch. A row below it sums up the rest and opens Advanced Options, four pages for hardware; the template and its parts (the trim tier and kept languages, the service profile, and which system apps go); the Core Bundle, custom IPSWs and patches; and the location, network and restore options. The row counts the settings that differ from the defaults and names anything there that stops Create. Turning off Create from a template restores the machine on its own, as `--no-template` does, with keys of its own and without slimming. Apple Account is not offered: the guest refuses its sign-in either way, so Launchpad passes `--accounts-off` whenever the service profile is trimmed. The sheet grows with its page up to 600 points and scrolls past that, so its buttons stay on a laptop screen.

The creation runs `vm template find` first. When a current template matches, it clones the machine (`vm create --template <id> --skip-first-boot`) and boots it. When none does, it builds the template in a temporary machine of the same library, named `template-` and eight hex digits, with its usual steps (restore, then `cfw install` through the helper), then `vm template trim`, the headless `vm template setup --strict` and `vm template adopt --iphone-source … --cloudos-source … --expect <id>`, and clones the machine from the result. The setup boot fails when an app it should remove stays, and the adopt fails when the build's key comes out other than the one `find` computed, so a build is never saved under an id later creations would not find. Each is a step of its own with its duration, and a failed one shows the reason `vphone-cli` gave.

Per-patch overrides from New Machine's Patch Settings are split the way the template key splits them. Boot-chain overrides are part of the key: the template is built with them, and `find` looks for one with them. Guest patch overrides are not: the template is built without them, and after the clone the creation records them on the new machine with `fw set-patches` and writes them with `cfw update-environment` through the helper (the Apply guest patches step) before its first boot. A template therefore never hands one creation's guest patch choice to another. Once it has built a template, the creation offers to delete the two IPSWs it came from; nothing is deleted without confirming.

File > Templates… lists every library's templates with their machines, slimming, size and state, and deletes them. Guest System… (in a machine's Actions menu and inspector) switches a running machine's service profile and restores system apps the template removed. The inspector and the machine list show each machine's exclusive disk use beside what its files allocate: the blocks no other machine or template holds, which deleting it frees (a local Time Machine snapshot taken before keeps them until it expires).

### Shared secrets

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

## Manual stages

Use these when investigating or repeating one phase. Keep a DFU boot running while `restore` talks to it:

```sh
vphone-cli vm new myphone
vphone-cli fw prepare myphone \
  --iphone-source /path/to/iPhone17,3_Restore.ipsw \
  --cloudos-source /path/to/cloudOS.ipsw
vphone-cli fw patch myphone

vphone-cli vm launch myphone --dfu &
vphone-cli restore myphone
vphone-cli vm stop myphone

vphone-cli cfw install myphone
vphone-cli vm launch myphone
```

The online restore obtains its ticket in process. For an offline restore, see `vphone-cli restore --help` for `--get-shsh` and `--offline`. The manual flow does not perform the automatic first-boot ping check from `vm create`.

## Library, firmware and backups

| Default path | Contents |
| --- | --- |
| `~/.vphone/machines/<name>/` | One VM, including its disk, `config.plist`, and patch work files |
| `~/.vphone/ipsws/` | Remote source IPSWs, shared by every VM; local IPSWs are read in place |
| `~/.vphone/gpu-drivers/<version>_<build>/` | GPU driver bundles extracted from cloudOS, shared by every VM |

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

### Sharing disk space between VMs

Two VMs restored separately from the same IPSW share nothing on disk, although much of their disk images is the same: two iOS 27.0 iPhones hold about 8.6 GB of identical bytes at the same places in their roughly 20 GB of data, mostly the system volume. `vm rebase` makes a stopped VM store those blocks once with another VM's, or with a template's:

```sh
vphone-cli vm rebase second --onto first --dry-run
vphone-cli vm rebase second --onto 3f2a91c0d4e7
```

It rebuilds `second`'s disk image from an APFS clone of the base's and writes in only the blocks that differ. `--onto` takes a VM name or a template identifier (or a unique prefix of one) from `vm template list`; a VM wins when a name matches both. Every byte is compared with the original before the image is replaced, so the guest sees exactly the same disk. Only the disk image changes: `SEPStorage`, `nvram.bin`, `config.plist` and the device identity stay as they are. Rebasing onto a template leaves the template as it is, and the VM does not become one of its clones: `vm template show` does not list it. Both must be stopped and on the same APFS volume, and the volume needs free space for the blocks that are written until the old image is released. `--dry-run` reports what would be shared and written without writing anything.

The saving is the **newly shared** figure. Bytes that are identical but already the same blocks on disk are reported as **already shared**, and rebasing them frees nothing. VMs made by `vm create` from one template already share its blocks, so rebasing one onto another, or onto that template, frees little; the command says so before it compares and again when the saving is under 0.1 GB. The VMs worth rebasing are ones restored without a template (`--no-template`) or imported.

- The space comes back only when nothing else holds the old image's blocks. Snapshots of the VM, and clones made from it, keep them; delete those first or expect no saving.
- `du` and Finder still count each image at its full size. Free space on the volume (`df`) is the honest measure.
- The two images drift apart again as either VM writes to its disk. A base that is never booted, such as a template, stays the best base, and rebasing again later recovers what drifted.
- A rebase that is interrupted leaves the VM unchanged and may leave a hidden `.rebase-*` folder in it; delete that folder.
