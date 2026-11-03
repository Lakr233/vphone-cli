# Create and run a VM

[Documentation](../README.md) · [Host setup](host-setup.md) · [Compatibility](compatibility.md)

The public firmware workflow has one mode. A patch preset selects which patches apply (see [Templates](templates.md) for how presets enter the template key), and `--block` or `--allow` adjusts single patches. It patches the boot chain and guest system, installs vphoned, and leaves the user's environment empty. It does not install Sileo, apt, TrollStore, an SSH server or VNC server.

## One-command flow

Supply an iPhone17,3 restore IPSW and a compatible PCC/cloudOS IPSW as local paths or URLs. [Compatibility](compatibility.md) records the pairs actually verified here.

```sh
vphone-cli host preflight
vphone-cli vm create myphone \
  --iphone-source /path/to/iPhone17,3_Restore.ipsw \
  --cloudos-source /path/to/cloudOS.ipsw
```

Creation runs prepare → firmware patch → online DFU restore → host-mounted CFW installation → first GUI boot. It needs network access for the restore ticket. The caller must provide root privileges for CFW installation; this bundle has no authorization dialog or privilege helper. The default virtual disk is 64 GB. `--keep-artifacts` retains the large prepared restore tree; omit it when disk space matters.

By default that pipeline builds a [template](templates.md) rather than the VM itself, and the VM is cloned from it. The next `vm create` for the same device, iOS and cloudOS builds, preset and disk size clones from the same template instead of restoring again. Pass `--no-template` to build the VM on its own, as before.

`--iphone-version` or `--iphone-build` instead of `--iphone-source` resolves the IPSW as `fw prepare` does, for `--device` (iPhone17,3 by default). Without `--cloudos-source` the cloudOS is the one the catalog recommends for that release, as `fw catalog` lists it.

`--cpu`, `--memory`, `--network` and `--unlock-at-startup` set those `vm config` settings on the new VM (defaults: 8 cores, 8192 MB, nat, off). `--skip-first-boot` leaves out the final boot, for a caller that boots the VM itself.

Before patching, creation prepares the firmware: a temporary cloudOS restore supplies the GPU driver, and a cloudOS without vphone600 components needs a rebuilt kernelcache. See [Firmware preparation](firmware-preparation.md). To create several machines from one list, see [Create many machines](many-machines.md).

## Start and stop

Success ends with `First boot: vphoned ping succeeded` and `JB VM created; vphoned connected`. **The verification VM is then stopped.** The ping proves the daemon answered over the host control socket during that boot; it does not leave a running VM behind.

```sh
vphone-cli vm launch myphone  # start the VM window and keep it running
vphone-cli vm stop myphone    # run from another terminal to stop it
```

Closing the VM window, ⌘Q, `vm stop` and Control-C in the `vm launch` terminal all shut the guest down first (vphoned `system.shutdown`) and end the virtual machine once the guest has stopped, or after 15 seconds if it has not. A guest vphoned cannot answer for, such as one in DFU or still starting up, is turned off at once, as pulling the power would. A second Control-C turns it off without waiting. `vm stop` only ever signals the machine's own processes, `vphone-vm` and Virtualization's VM service; another program that has the disk open, such as Launchpad measuring its size, Spotlight or a backup tool, is named and left running.

`vm launch` starts the guest without waiting for vphoned; the daemon connects during boot. The VM window and menu provide Home/power keys, app installation and file browsing. The host control socket is `<VM bundle>/vphone.sock`: one JSON line in, one out. Connections are served concurrently, and the socket also exists with `--no-graphics`, where `tap` and `swipe` go through vphoned's touch injection and screen images come from the guest. Besides `tap`, `swipe`, `key` and `screenshot`, `{"t":"rpc","method":"<vphoned method>","params":{…}}` calls any method in `Research/vphoned_http_api.md`. For example, `input.key` with `{"name":"cmd+v"}` pastes and `input.type` types text. No SSH or VNC endpoint is installed by this workflow.

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

## Further reading

- [Templates](templates.md): how `vm create` reuses one restore for many machines, and how to slim, find and delete templates.
- [Device name and clock](device-name-and-clock.md): what the guest takes from the VM and the Mac.
- [Library, firmware and backups](library-and-backups.md): where machines and caches live, clones and exports.
- [Sharing disk space between VMs](sharing-disk-space.md): `vm rebase`.
