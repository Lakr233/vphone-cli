# Launchpad command line

`vphone-launchpad-cli` drives the running Launchpad from Terminal or a script: install bundles, create, start and stop machines, and talk to the guest. Use it when you want Launchpad's behavior without clicking through the window.

## Set it up

The CLI ships in `vphone-launchpad.app/Contents/MacOS`. Link it onto your `PATH`:

```sh
ln -s /Applications/vphone-launchpad.app/Contents/MacOS/vphone-launchpad-cli /usr/local/bin/
vphone-launchpad-cli help
```

It starts Launchpad when Launchpad is not running. A Launchpad the CLI starts opens hidden and does not take focus from the app in front; click its Dock icon, or Open Launchpad in the menu bar, to show the window. Pass `--foreground` (before the command, or among the options of any command but `exec`) to start it with its window in front instead. Neither changes a Launchpad that is already running.

## Output and exit status

- Progress lines go to stderr as they arrive.
- The result is one JSON document on stdout.
- The exit status is 0 on success and 1 on failure, with the reason on stderr.
- Interrupting the CLI cancels a command that can be cancelled (`exec`, waits, CFW install). A bundle install or a machine creation belongs to the window and keeps running.

Every command also appears in Launchpad's window and command history.

## Commands

Machine commands take `--root <library>` when two libraries hold a machine with the same name.

### Status and bundles

| Command | Does |
| --- | --- |
| `status` | Host checks, helper, default bundle, machine counts |
| `bundle list` | Installed versions, receipts, cdhashes, check results, bound machines |
| `bundle install-local <path> [--keep-default]` | Install a local `VPhone.bundle` folder or `.zip` |
| `bundle install-release <version\|latest> [--keep-default]` | Download and install a GitHub release |
| `bundle set-default <version>` | Make a version the default. `bundle use` is the old name |
| `bundle verify <version>` | Re-check a version |
| `bundle accept <version> [--off]` | Skip failed checks, or stop skipping them with `--off` |
| `bundle remove <version>` | Remove a version no machine is bound to |

To install a local build, move a machine to it, or compare two builds, see [Core Bundles and local builds](core-bundles.md).

### Machines

| Command | Does |
| --- | --- |
| `vm list` | Machines in every library with run state, Core Bundle and log path |
| `vm start <name> [--headless] [--wait]` | Launch with the machine's bundle. `--wait` waits for vphoned |
| `vm stop <name>` | Ask the guest to shut down (vphoned `system.shutdown`) and wait up to 30 s. When the guest cannot be asked or does not stop, end the virtual machine |
| `vm wait <name>` | Wait for vphoned |
| `vm log <name> [--lines <n>] [--kind create\|dfu\|patch]` | Read a console log |
| `vm create <name> [options]` | The New Machine pipeline; see [Create a machine](#create-a-machine) |
| `vm set-bundle <name> <version> [--update-environment]` | Bind a machine to another installed version |
| `vm leases [--release]` | DHCP leases on the shared NAT network and the machine that owns each. `--release` frees the ones no machine in any library uses, through the helper (see [Addresses held by old MACs](../networking/addresses.md#addresses-held-by-old-macs)) |

Notes:

- In `vm list`, only a VM process holding the disk (`vphone-vm`, or Virtualization's VM service) makes a machine `running`. Any other process that has the disk open (`tail`, Spotlight, a backup tool) is listed in `diskOpenIn` (for example `12925 tail`) and leaves the machine `stopped`.
- `vm start`, like `vphone-cli vm launch`, is not refused by a process that only has the disk open; it prints a note naming that process.
- `vm start --wait` and `vm wait` also take `--timeout`.
- `vm set-bundle --update-environment` also redeploys that version's guest environment and needs a stopped machine. A disk another process has open refuses it, naming that process, before the binding changes. If the update itself fails, the machine stays bound to the new version and `vm list` still shows the old `guestEnvironmentBundle`; run `cfw update-environment` to finish.

### CFW

These run through Launchpad's helper on a stopped machine, with the machine's own bundle. Each refuses a disk another process has open, naming it (`12925 tail`).

| Command | Does |
| --- | --- |
| `cfw install <name>` | Install CFW. The helper puts temporary work files on the VM library's external volume when applicable |
| `cfw update-environment <name>` | Redeploy the bundle's guest resources (vphoned, hook dylibs); nothing else changes |
| `cfw update-kernel <name>` | Re-patch the kernelcache from the machine's current patch selection and swap it into Preboot, keeping the data. This is the data-preserving way to change a kernel patch on an installed VM; no restore tree is needed |

### Guest

`guest` commands and `--wait` go through the machine's `vphone.sock`, which every launch serves. Bundles up to 2.0.9 serve it only for machines launched with a window.

| Command | Does |
| --- | --- |
| `guest send <name> <json>` | One raw `vphone.sock` request (tap, swipe, key, screenshot) |
| `guest rpc <name> <method> [params]` | Any vphoned method; see [`Research/vphoned_http_api.md`](../../../Research/vphoned_http_api.md). When vphoned refuses it, the last stderr line is its error object as JSON (`code`, `message`, `results`, `reason` …) |
| `guest push <name> <local> <guest-path> [--mode <octal>]` | Copy a Mac file into the guest. It streams through vphoned, so size is not limited by `guest rpc`'s 1 MiB JSON line; use it for binaries and IPAs. A guest path ending in `/` keeps the file's name; the mode defaults to the Mac file's permissions |
| `guest pull <name> <guest-path> <local>` | Copy a guest file to the Mac, streamed. `local` may be a folder. The file replaces `local` only once complete |
| `guest unlock <name> [--passcode <code>] [--timeout <seconds>]` | Turn the screen on and unlock the guest, whatever state it was in (vphoned `screen.unlock`). `--passcode` is needed only when the guest has one |

### Run vphone-cli

| Command | Does |
| --- | --- |
| `exec [--bundle <version>] <vphone-cli arguments>` | Run the default bundle's `vphone-cli`, or that version's, streaming its output. `--bundle` must come first |

## Create a machine

`vm create` runs the New Machine pipeline, bound to `--bundle <version>` or to the default bundle. The machine is cloned from a template, which is built first when missing (2.9), or restored on its own with `--no-template`.

```sh
vphone-launchpad-cli vm create rt-e --block system-debugserver-cfw-install
```

| Option | Does |
| --- | --- |
| `--bundle <version>` | Bind the machine to this installed version instead of the default |
| `--device <product-type>` | Make another device; see [Other devices](#other-devices) |
| `--preset <preset>` | A preset name, or the path of a preset plist (2.14), which the machine keeps a copy of |
| `--block <patch>`, `--allow <patch>` | Turn one patch of the preset off or on; repeatable. See [Patch overrides](#patch-overrides) |
| `--no-template` | Restore the machine on its own instead of cloning a template. Of the slimming switches only `--slim` applies: `on` (the default) gives the machine a setup boot of its own, which skips Setup Assistant; `off` starts it at Setup Assistant |
| `--slim on\|off`, `--trim …`, `--keep-languages …`, `--service-profile …`, `--remove-apps …`, `--keep-apps …` | The slimming switches of `vphone-cli vm create`. Apple Account goes with the trimmed service profile, as in New Machine |
| `--accounts-off` | Accepted, and changes nothing |
| `--ipsw <path>` | Optional. Passed only to a 2.12.0 bundle, which stages the kernelcache mix with it, as New Machine's ipsw field does. A 2.12.1 bundle extracts natively |
| `--kmutil-ssh <user@host>` | The Mac that links an iOS 18 guest's (`--device iPhone11,6`) kernel-first mix over ssh, as New Machine's macOS builder field. The password for ssh and sudo there comes from the client's `VPHONE_KMUTIL_SSH_PASSWORD`, never from an argument |
| `--from <step>` | Retry from a step (`findTemplate` … `firstBoot`) with the options the creation started with |

The parser also accepts `--iphone-source`, `--cloudos-source`, `--cpu`, `--memory`, `--disk-size`, `--network`, `--keep-artifacts` and `--no-wait`; see `vphone-launchpad-cli help`.

The result names the template, whether this creation built it, and the patches it used.

### Other devices

| `--device` | Guest | Notes |
| --- | --- | --- |
| An iPad product type | iPadOS | See [iPadOS guests](../firmware/ipados.md) |
| `AppleTV5,3` | Apple TV HD | Always restored on its own without slimming; takes the `tvos` preset unless `--preset` names another |
| `AppleTV14,1` | Apple TV 4K (3rd generation) | The same, with the `tvos-4k` preset and its userland from the catalog's OTA |
| `AppleTV18,1` | Apple TV 4K (4th generation) | Needs Launchpad and Core Bundle 2.13. Selects `tvos-4k`, restores independently without slimming, and takes tvOS 27.2 beta (`24K120`) from its full OTA over the Apple TV HD base. Creation requires macOS 27. A live boot is still pending; see the [bring-up notes](../../../Research/Firmware/tvos_support.md#apple-tv-4k-4th-generation) |

Two more cases run steps as root through the helper:

- `--preset minimal` (Minimal: a stock boot chain, kernel and TXM, with the system customized before the restore) is also restored on its own without slimming, and its `fw patch` runs as root through the helper. Its Userspace debugging box (`userspace-debugging` under Features in `vphone-cli fw patches`) is an `--allow` for each patch it lists. Its Trusted darwinOS environment box (`trusted-darwinos`, which is `--allow filesystem-exp-trusted_darwinos`) restores an iPhone or iPad as trusted darwinOS with cloudOS's cryptexctl, so a cryptex can be installed while it runs (Apps › Install Cryptex… in the VM window; see [Cryptexes](../machines/cryptexes.md)), and the box's summary says what it changes. The guest then enforces Restricted Execution Mode, and a research-board guest (cloudOS 26.5 to 26.7) cannot turn on Developer Mode, and changing the box takes effect only with a new restore.
- For a machine whose cloudOS has no vphone600 components (its release's own cloudOS, a watch, an iOS 18 guest), the kernelcache mix is staged with `fw kernelcache` and linked by the helper as root.

### Patch overrides

`--block <patch>` and `--allow <patch>` take the identifiers that `vphone-cli fw patches` lists, once per patch:

```sh
vphone-launchpad-cli exec fw patches --preset <preset>
```

Launchpad reads that catalog from the creation's bundle, refuses an identifier no patch set declares or one both blocked and allowed, and keeps only what differs from the preset, as `fw set-patches` does. It then splits them the way New Machine does:

- **Boot-chain patches** (AVPBooter, iBSS, iBEC, LLB, TXM, kernelcache, DeviceTree …) are part of the template's key. Find Template looks for a template built with them, and a template build records them with `fw set-patches` before `fw patch`.
- **Guest patches** stay out of the template. The clone records them with `fw set-patches`, and the Apply Guest Patches step writes them with `cfw update-environment` through the helper before the first boot. A guest override alone therefore reuses the plain template.

The result's `patches` object holds the preset, the `blocked` and `allowed` overrides, and the `guest` ones applied to the clone. With `--no-template` every override goes into the machine's own restore. `--from` refuses `--block` and `--allow`: a retry keeps the creation's patches.

## Bundle fields in results

| Command | Field | Meaning |
| --- | --- | --- |
| `status` | `defaultBundle` | The default version. `activeBundle` holds the same value for older scripts |
| `bundle list` | `default` | This version is the default. `active` holds the same value for older scripts |
| `bundle list` | `machines` | Names of the machines bound to this version |
| `vm list` | `bundle` | The version the machine's host programs run with |
| `vm list` | `guestEnvironmentBundle` | The version whose guest environment was installed last; `null` while unknown |
| `vm list` | `bootChainBundle` | The version that built the boot chain; `null` for a machine created before Launchpad recorded it |
| `vm create`, `cfw …`, `exec` | `bundle` | The version the command ran with |

When `guestEnvironmentBundle` differs from `bundle`, host and guest come from different builds; `cfw update-environment` brings the guest in line.

## Touch coordinates and display geometry

Touch coordinates for `guest send` refer to the **full upright screenshot** that `t:screenshot` returns: after a quarter turn its width and height swap. The host converts that point into fixed-panel HID coordinates for both GUI and headless launches. A swipe keeps the geometry sampled at its start. If the geometry changes across a screenshot, you get an error rather than an image with ambiguous input coordinates.

To diagnose rotated coordinate mismatches, read the geometry:

```sh
vphone-launchpad-cli guest send <name> '{"t":"display.geometry"}'
```

It returns the host's configured and captured pixel dimensions plus the live display-view bounds, rotation, aspect-fit drawing rect, and pointer/touch path, and changes no input or display state. `capture_pixels` is the raw host frame; `screenshot_pixels` and `input_orientation` describe input coordinates. Compare it with `device.screen`, `display.orientation` and the events the guest actually receives.

## How it connects

The CLI talks to the running Launchpad over a Unix socket at `~/Library/Application Support/vphone-launchpad/control.sock` (mode 0600, served only to the same user). It has no privileges and no state of its own: bundles are installed through Launchpad's helper, and each machine runs through the `vphone-cli` of its own Core Bundle. Nothing listens on the network; to use it from another machine, connect over ssh.

## See also

- [Core Bundles and local builds](core-bundles.md)
- [Bundle integration](bundle-integration.md)
- [Create and run](../machines/create-and-run.md)
