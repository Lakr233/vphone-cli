# Launchpad command line

`vphone-launchpad-cli` ships in `vphone-launchpad.app/Contents/MacOS`. It
drives the running Launchpad over a Unix socket at
`~/Library/Application Support/vphone-launchpad/control.sock` (mode 0600,
served only to the same user) and starts Launchpad when it is not running. It
has no privileges and no state of its own: bundles are installed through
Launchpad's helper, each machine runs through the `vphone-cli` of its own Core
Bundle, and every command appears in Launchpad's window and command history.
Nothing listens on the network; reach it over ssh from another machine.

A Launchpad the CLI starts opens hidden and does not take focus from the app
in front; click its Dock icon, or Open Launchpad in the menu bar, to show the
window. Pass `--foreground` (before the command, or among the options of any
command but `exec`) to start it with its window in front instead. Neither
changes a Launchpad that is already running.

Progress lines go to stderr as they arrive. The result is one JSON document on
stdout. The exit status is 0 on success and 1 on failure, with the reason on
stderr. Interrupting the CLI cancels a command that can be cancelled
(`exec`, waits, CFW install); a bundle install or machine creation belongs to
the window and keeps running.

```sh
ln -s /Applications/vphone-launchpad.app/Contents/MacOS/vphone-launchpad-cli /usr/local/bin/
vphone-launchpad-cli help
```

## Core Bundle per machine

Every machine is bound to one installed `VPhone.bundle` version, chosen when
it is created and kept in `launchpad.json` in the machine folder. Installing a
bundle never changes a machine's binding. A machine is made of three layers,
each from a bundle at a different time:

| Layer | What | Comes from |
| --- | --- | --- |
| Host Programs | `vphone-cli`, `vphone-vm` | The bound bundle, on every command. A new binding applies at the next start. |
| Guest Environment | vphoned and the hook dylibs | `cfw install` at creation, and `cfw update-environment` (stopped machine) later. |
| Boot Chain | Patched firmware, restore, CFW patches | `fw patch`, `restore` and `cfw install` at creation. After that, `vphone-cli fw set-patches` changes the choice and `vphone-cli fw patches <vm>` lists what has not reached the guest: guest patches apply at the next `cfw update-environment`, AVPBooter at the next `fw patch`, a kernel patch with `cfw update-kernel` (data-preserving, no restore tree needed), and the rest of the boot chain (TXM, DeviceTree, LLB) only with a restore, which erases the guest. Launchpad shows the count in the inspector. |

The **default** bundle (formerly "active") decides only the version
`vm create` binds when `--bundle` is not given, and what `exec` and
library-wide commands run with. A new install becomes the default unless
`--keep-default` is passed. The first start of a machine in a Launchpad
session checks its bundle (execution policy exception, AMFI, host preflight)
once.

Local builds install as `<version>-local.<hash>`, the hash taken from the
bundle's code-signature seal, so two builds of one version sit side by side.
Older stores may still hold `<version>-local` or `<version>-ci.<commit>`.

## Testing a VPhone.bundle build

```sh
xcodebuild -workspace VPhone.xcworkspace -scheme VPhone \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/XcodeBundle build

# Installs as <version>-local.<hash>, makes it the default, adds the execution
# policy exception, allows the new vphone-vm cdhash and runs host preflight.
vphone-launchpad-cli bundle install-local .build/XcodeBundle/Build/Products/Debug/VPhone.bundle

# Move an existing machine to it; --update-environment also redeploys the
# new vphoned and hook dylibs (the machine must be stopped).
vphone-launchpad-cli vm set-bundle research-01 2.4.0-local.1a2b3c4d --update-environment

vphone-launchpad-cli vm start research-01 --wait
vphone-launchpad-cli guest rpc research-01 device.info
vphone-launchpad-cli guest rpc research-01 apps.list '{}'
vphone-launchpad-cli vm log research-01 --lines 100
vphone-launchpad-cli vm stop research-01
```

The exact version is in the install result and in `bundle list`. The first
step that needs the helper after its five-minute authorization expires asks
for an administrator password on the Mac, as the window does.

## Comparing two builds

Install both without moving the default, then give each its own machine:

```sh
vphone-launchpad-cli bundle install-local /path/to/A/VPhone.bundle --keep-default
vphone-launchpad-cli bundle install-local /path/to/B/VPhone.bundle --keep-default
vphone-launchpad-cli bundle list        # note both versions

vphone-launchpad-cli vm create cmp-a --bundle 2.4.0-local.aaaaaaaa
vphone-launchpad-cli vm create cmp-b --bundle 2.4.0-local.bbbbbbbb
```

Machines created this way differ in all three layers. To compare only host
programs and guest environment on one boot chain, clone a machine in the
window and rebind the copy:

```sh
vphone-launchpad-cli vm set-bundle cmp-b 2.4.0-local.bbbbbbbb --update-environment
```

`vm list` shows which bundle each layer came from. `bundle remove` refuses a
version while a machine is bound to it; rebind or delete those machines first.

## Commands

| Command | Does |
| --- | --- |
| `status` | Host checks, helper, default bundle, machine counts |
| `bundle list` | Installed versions, receipts, cdhashes, check results, bound machines |
| `bundle install-local <path> [--keep-default]` | Install a local `VPhone.bundle` folder or `.zip` |
| `bundle install-release <version\|latest> [--keep-default]` | Download and install a GitHub release |
| `bundle set-default <version>` / `bundle verify <version>` | Make a version the default, or re-check it. `bundle use` is the old name of `set-default` |
| `bundle accept <version> [--off]` / `bundle remove <version>` | Skip failed checks, or remove a version no machine is bound to |
| `vm list` | Machines in every library with run state, Core Bundle and log path. Only a VM process holding the disk (`vphone-vm`, or Virtualization's VM service) makes a machine `running`; any other process that has it open (`tail`, Spotlight, a backup tool) is listed in `diskOpenIn` (`12925 tail`) and leaves it `stopped` |
| `vm start <name> [--headless] [--wait]` / `vm stop <name>` | Launch with the machine's bundle, or stop; `--wait` waits for vphoned. Stop asks the guest to shut down (vphoned `system.shutdown`) and waits up to 30 s; when the guest cannot be asked or does not stop, it ends the virtual machine as before. Like `vphone-cli vm launch`, start is not refused by a process that only has the disk open; it prints a note naming it |
| `vm wait <name>` / `vm log <name> [--kind create\|dfu\|patch]` | Wait for vphoned; read a console log |
| `vm create <name> [--bundle <version>] [...] [--device <product-type>] [--preset <preset>] [--block <patch>]... [--allow <patch>]... [--no-template \| --slim on\|off --trim … --keep-languages … --service-profile … --remove-apps … --keep-apps … --accounts-off] [--from <step>]` | The New Machine pipeline, bound to `--bundle` or the default: cloned from a template, built first when missing (2.9), or restored on its own with `--no-template`; the slimming switches are `vphone-cli vm create`'s, except that Apple Account goes with the trimmed service profile as in New Machine (`--accounts-off` is accepted and changes nothing). `--block`/`--allow` (repeatable) turn one patch of the preset off or on, as New Machine's patch list and `vphone-cli fw set-patches` do (see below). `--device` makes an iPad guest, `--from` retries from a step (`findTemplate` … `firstBoot`) with the options the creation started with; the result names the template, whether this creation built it, and the patches it used |
| `vm set-bundle <name> <version> [--update-environment]` | Bind a machine to another installed version. `--update-environment` also redeploys that version's guest environment and needs a stopped machine; a disk another process has open refuses it, naming that process, before the binding changes. If the update itself fails, the machine stays bound to the new version and `vm list` still shows the old `guestEnvironmentBundle`: run `cfw update-environment` to finish |
| `vm leases [--release]` | DHCP leases on the shared NAT network and the machine that owns each. `--release` frees the ones no machine in any library uses, through the helper (see [Networking](networking.md#addresses-held-by-old-macs)) |
| `cfw install <name>` | Install CFW into a stopped machine with its own bundle, through the helper. The helper puts temporary work files on the VM library's external volume when applicable. It and the two updates below refuse a disk another process has open, naming it (`12925 tail`). |
| `cfw update-environment <name>` | Redeploy the machine's own bundle's guest resources (vphoned, hook dylibs) into it while stopped, through the helper; nothing else changes |
| `cfw update-kernel <name>` | Re-patch the kernelcache from the machine's current selection and swap it into Preboot, keeping the data (VM off); the data-preserving way to change a kernel patch on an installed VM, no restore tree needed |
| `guest send <name> <json>` | One raw `vphone.sock` request (tap, swipe, key, screenshot) |
| `guest rpc <name> <method> [params]` | Any vphoned method, see `Research/vphoned_http_api.md`. When vphoned refuses it, the last stderr line is its error object as JSON (`code`, `message`, `results`, `reason` …) |
| `guest unlock <name> [--passcode <code>] [--timeout <seconds>]` | Turn the screen on and unlock the guest, whatever state it was in (vphoned `screen.unlock`). `--passcode` is needed only when the guest has one |
| `exec [--bundle <version>] <vphone-cli arguments>` | Run the default bundle's `vphone-cli`, or that version's, streaming its output. `--bundle` must come first |

### Patch overrides in `vm create`

`--block <patch>` and `--allow <patch>` take the identifiers `vphone-cli fw
patches` lists (`vphone-launchpad-cli exec fw patches --preset <preset>`),
once per patch. Launchpad reads that catalog from the creation's bundle,
refuses an identifier no patch set declares or one both blocked and allowed,
and keeps only what differs from the preset, as `fw set-patches` does. It
then splits them the way New Machine does:

- Boot-chain patches (AVPBooter, iBSS, iBEC, LLB, TXM, kernelcache,
  DeviceTree …) are part of the template's key: Find Template looks for a
  template built with them, and a template build records them with `fw
  set-patches` before `fw patch`.
- Guest patches stay out of the template. The clone records them with `fw
  set-patches`, and the Apply Guest Patches step writes them with `cfw
  update-environment` through the helper before the first boot. A guest
  override alone therefore reuses the plain template.

```sh
vphone-launchpad-cli vm create rt-e --block system-debugserver-cfw-install
```

The result's `patches` object holds the preset, the `blocked` and `allowed`
overrides and the `guest` ones applied to the clone. With `--no-template`
every override goes into the machine's own restore. `--from` refuses
`--block` and `--allow`: a retry keeps the creation's patches.

Machine commands take `--root <library>` when two libraries hold a machine
with the same name. `guest` commands and `--wait` go through the machine's
`vphone.sock`, which every launch serves; bundles up to 2.0.9 serve it only
for machines launched with a window.

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

When `guestEnvironmentBundle` differs from `bundle`, host and guest come from
different builds; `cfw update-environment` brings the guest in line.
