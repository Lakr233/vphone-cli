# Create and Run a VM

Create, start and stop VMs with `vphone-cli` in Terminal. Use this page when you work without Launchpad, script VM creation, or need to repeat one stage of the process.

Launchpad drives VMs through the `vphone-cli` inside `VPhone.bundle`; the same commands work in Terminal:

```sh
vphone-cli vm list
vphone-cli vm launch myphone
vphone-cli vm export myphone --out myphone.tzst
```

VMs are stored in `~/.vphone/`. Run `vphone-cli <group> --help` to see all commands.

## Create a VM

You need an iPhone17,3 restore IPSW and a compatible PCC/cloudOS IPSW, as local paths or URLs. [Compatibility](../firmware/compatibility.md) lists the pairs verified so far.

```sh
vphone-cli host preflight
vphone-cli vm create myphone \
  --iphone-source /path/to/iPhone17,3_Restore.ipsw \
  --cloudos-source /path/to/cloudOS.ipsw
```

Creation runs these stages: prepare, firmware patch, online DFU restore, host-mounted CFW installation, first GUI boot.

- It needs network access for the restore ticket.
- CFW installation needs root. The bundle has no authorization dialog or privilege helper, so you provide root yourself.
- The default virtual disk is 64 GB.

Success ends with `[+] First boot: vphoned ping succeeded.` and `CFW VM created; vphoned connected. Guest user environment is untouched.` The VM is then stopped: the ping proves that vphoned answered during that boot, and no running VM is left behind.

### Options

| Option | Effect |
| --- | --- |
| `--iphone-version`, `--iphone-build` | Resolve the iPhone IPSW instead of passing `--iphone-source`, as `fw prepare` does, for `--device` (iPhone17,3 by default). |
| `--cloudos-source` omitted | Use the cloudOS the catalog recommends for that release, as `fw catalog` lists it. |
| `--disk-size` | Virtual disk size in GB (default 64). |
| `--preset` | Patch preset name, or path to a preset plist (default `standard`). Run `fw patches` to see what each one applies. |
| `--cpu` | CPU cores (default 8). |
| `--memory` | Memory in MB (default 8192). |
| `--network` | `nat` (default), `bridged`, `tunnel` or `none`. |
| `--unlock-at-startup` | `on` or `off` (default). |
| `--no-template` | Build the VM on its own instead of cloning it from a template. |
| `--skip-first-boot` | Leave out the final boot, for a caller that boots the VM itself. |
| `--bootstrap roothide` | Install a package environment during the first boot. See [Package Environment](package-environment.md). |
| `--keep-artifacts` | Keep the large prepared restore tree. Leave it out when disk space matters. |

`--cpu`, `--memory`, `--network` and `--unlock-at-startup` set the same `vm config` settings on the new VM.

### Templates

By default the pipeline builds a [template](../storage/templates.md) and clones the VM from it. The next `vm create` for the same device, iOS and cloudOS builds, preset and disk size clones from that template instead of restoring again. Pass `--no-template` to build the VM on its own.

### Patches and firmware preparation

The firmware workflow has one mode. It patches the boot chain and guest system, installs vphoned, and leaves the user environment empty: it does not install Sileo, apt, TrollStore, an SSH server or a VNC server. A patch preset selects which patches apply; `vphone-cli fw set-patches` with `--block` or `--allow` turns single patches off or on.

Before patching, creation prepares the firmware: a temporary cloudOS restore supplies the GPU driver, and a cloudOS without vphone600 components needs a rebuilt kernelcache. See [Firmware Preparation](../firmware/firmware-preparation.md). To create several machines from one list, see [Many Machines](../storage/many-machines.md).

## Start and stop

```sh
vphone-cli vm launch myphone  # start the VM window and keep it running
vphone-cli vm stop myphone    # run from another terminal to stop it
```

`vm launch` starts the guest without waiting for vphoned; the daemon connects during boot. The VM window and menu provide Home and power keys, app installation and file browsing. `vm launch --headless` boots without a VM window or menu bar.

These all shut the guest down cleanly (vphoned `system.shutdown`):

- closing the VM window
- ⌘Q
- `vm stop`
- Control-C in the `vm launch` terminal

The VM ends once the guest has stopped, or after 15 seconds if it has not. A guest vphoned cannot answer for, such as one in DFU or still starting up, is turned off at once, as pulling the power would. A second Control-C turns it off without waiting.

`vm stop` only signals the machine's own processes, `vphone-vm` and Virtualization's VM service. Another program that has the disk open, such as Launchpad measuring its size, Spotlight or a backup tool, is named and left running.

## Control socket

Each running VM has a control socket at `vphone.sock` in its folder (`~/.vphone/machines/<name>/vphone.sock`): one JSON line in, one JSON line out. Connections are served concurrently, and the socket also exists for a VM without a window, where `tap` and `swipe` go through vphoned's touch injection and screen images come from the guest.

Besides `tap`, `swipe`, `key` and `screenshot`, an `rpc` request calls any vphoned method in the [API reference](../../../Research/vphoned_http_api.md):

```sh
printf '%s\n' '{"t":"rpc","method":"device.info","params":{}}' | nc -U ~/.vphone/machines/myphone/vphone.sock
```

For example, `input.key` with `{"name":"cmd+v"}` pastes, and `input.type` types text. This workflow installs no SSH or VNC endpoint. For HTTP and WebSocket access, see [Automation API](automation-api.md).

## Run each stage by hand

Use these when you investigate or repeat one phase. Keep a DFU boot running while `restore` talks to it:

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

The online restore obtains its ticket in process. For an offline restore, see `vphone-cli restore --help` for `--get-shsh` and `--offline`. The manual flow does not run the first-boot ping check that `vm create` does.

## See also

- [Templates](../storage/templates.md)
- [Device Name and Clock](device-name-and-clock.md)
- [Library and Backups](../storage/library-and-backups.md)
- [Sharing Disk Space](../storage/sharing-disk-space.md)
