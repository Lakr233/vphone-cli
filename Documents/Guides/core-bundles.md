# Core Bundles and local builds

[Documentation](../README.md) · [Launchpad command line](launchpad-cli.md) · [Bundle integration](bundle-integration.md)

## One bundle per machine

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

For the one-time kernel and guest update that enables persistent shader caches
on an existing VM, see [Persistent shader caches](shader-cache.md).

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
