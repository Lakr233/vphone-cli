# Core Bundles and local builds

Each Launchpad machine runs with one installed `VPhone.bundle` version, its Core Bundle. This page shows how to install a local build, move a machine to it, and compare two builds side by side.

## Test a VPhone.bundle build

1. Build the bundle from the repository root:

   ```sh
   xcodebuild -workspace VPhone.xcworkspace -scheme VPhone \
     -configuration Debug -destination 'platform=macOS,arch=arm64' \
     -derivedDataPath .build/XcodeBundle build
   ```

2. Install it. It installs as `<version>-local.<hash>`, becomes the default, gets the execution policy exception, has the new `vphone-vm` cdhash allowed, and runs host preflight:

   ```sh
   vphone-launchpad-cli bundle install-local .build/XcodeBundle/Build/Products/Debug/VPhone.bundle
   ```

   The exact version is in the install result and in `bundle list`.

3. Move an existing machine to it. `--update-environment` also redeploys the new vphoned and hook dylibs, and needs the machine to be stopped:

   ```sh
   vphone-launchpad-cli vm set-bundle research-01 2.4.0-local.1a2b3c4d --update-environment
   ```

4. Start the machine and check it:

   ```sh
   vphone-launchpad-cli vm start research-01 --wait
   vphone-launchpad-cli guest rpc research-01 device.info
   vphone-launchpad-cli guest rpc research-01 apps.list '{}'
   vphone-launchpad-cli vm log research-01 --lines 100
   vphone-launchpad-cli vm stop research-01
   ```

The helper's authorization lasts five minutes. The first step that needs the helper after it expires asks for an administrator password on the Mac, as the window does.

For the one-time kernel and guest update that enables persistent shader caches on an existing VM, see [Persistent shader caches](../storage/shader-cache.md).

## Compare two builds

Install both without moving the default, then give each its own machine:

```sh
vphone-launchpad-cli bundle install-local /path/to/A/VPhone.bundle --keep-default
vphone-launchpad-cli bundle install-local /path/to/B/VPhone.bundle --keep-default
vphone-launchpad-cli bundle list        # note both versions

vphone-launchpad-cli vm create cmp-a --bundle 2.4.0-local.aaaaaaaa
vphone-launchpad-cli vm create cmp-b --bundle 2.4.0-local.bbbbbbbb
```

Machines created this way differ in all three layers (see below). To compare only host programs and guest environment on one boot chain, clone a machine in the window and rebind the copy:

```sh
vphone-launchpad-cli vm set-bundle cmp-b 2.4.0-local.bbbbbbbb --update-environment
```

`vm list` shows which bundle each layer came from. `bundle remove` refuses a version while a machine is bound to it; rebind or delete those machines first.

## How machines are bound to bundles

Every machine is bound to one installed version, chosen when it is created and kept in `launchpad.json` in the machine folder. Installing a bundle never changes a machine's binding.

A machine is made of three layers, each taken from a bundle at a different time:

| Layer | What | Comes from |
| --- | --- | --- |
| Host Programs | `vphone-cli`, `vphone-vm` | The bound bundle, on every command. A new binding applies at the next start. |
| Guest Environment | vphoned and the hook dylibs | `cfw install` at creation, and `cfw update-environment` (stopped machine) later. |
| Boot Chain | Patched firmware, restore, CFW patches | `fw patch`, `restore` and `cfw install` at creation. |

### Changing boot-chain patches later

`vphone-cli fw set-patches` changes the patch choice, and `vphone-cli fw patches <vm>` lists what has not reached the guest yet. Launchpad shows the count in the inspector. Each kind of patch reaches the guest a different way:

| Patch | Applies with |
| --- | --- |
| Guest patches | The next `cfw update-environment` |
| AVPBooter | The next `fw patch` |
| Kernel patches | `cfw update-kernel` (keeps the data, no restore tree needed) |
| The rest of the boot chain (TXM, DeviceTree, LLB) | Only a restore, which erases the guest |

## The default bundle

The **default** bundle (formerly "active") decides only:

- which version `vm create` binds when `--bundle` is not given;
- what `exec` and library-wide commands run with.

A new install becomes the default unless you pass `--keep-default`. The first start of a machine in a Launchpad session checks its bundle once (execution policy exception, AMFI, host preflight).

## Version names

Local builds install as `<version>-local.<hash>`, with the hash taken from the bundle's code-signature seal, so two builds of one version sit side by side. Older stores may still hold `<version>-local` or `<version>-ci.<commit>`.

## See also

- [Launchpad command line](launchpad-cli.md)
- [Bundle integration](bundle-integration.md)
- [Downloads](../get-started/downloads.md)
