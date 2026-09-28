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

`fw prepare` creates a temporary vphone VM, starts it in DFU, and restores the selected cloudOS IPSW using this project's restore backend. It mounts the restored System volume read-only, extracts the GPU bundle, then removes the temporary VM. This first restore supplies the GPU driver for the second, hybrid iPhone restore. The extracted bundle is cached per cloudOS build in `~/.vphone/gpu-drivers/`, so later machines on the same cloudOS skip the temporary restore. `vm create` and `fw prepare` also accept `--gpu-driver-bundle /path/to/AppleParavirtGPUMetalIOGPUFamily.bundle` to reuse a previously extracted bundle without the temporary restore. The CLI checks its iPhoneOS platform version against the selected cloudOS version. Each restore obtains its own ticket online.

The build also ships an arm64e GPU compiler plugin in the bundle. `fw prepare` copies it into the staged GPU bundle before firmware patching and installation.

Success ends with `First boot: vphoned ping succeeded` and `JB VM created; vphoned connected`. **The verification VM is then stopped.** The ping proves the daemon answered over the host control socket during that boot; it does not leave a running VM behind.

```sh
vphone-cli vm launch myphone  # start the VM window and keep it running
vphone-cli vm stop myphone    # run from another terminal to stop it
```

`vm launch` starts the guest without waiting for vphoned; the daemon connects during boot. The VM window and menu provide Home/power keys, app installation and file browsing. The host control socket is `<VM bundle>/vphone.sock`: one JSON line in, one out. Besides `tap`, `swipe`, `key` and `screenshot`, `{"t":"rpc","method":"<vphoned method>","params":{…}}` calls any method in `Research/vphoned_http_api.md`. For example, `input.key` with `{"name":"cmd+v"}` pastes and `input.type` types text. No SSH or VNC endpoint is installed by this workflow.

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

`VPHONE_ROOT` relocates the VM library and both caches. `VPHONE_LIBRARY_ROOT` takes precedence for the library alone, and `--ipsw-cache <dir>` on `vm create` and `fw prepare` for the IPSW cache alone. Downloaded IPSWs stay cached until you delete them, so a second VM from the same URL downloads nothing; the prepared restore tree is removed after a successful `vm create` unless `--keep-artifacts` is set. VMs prepared by an earlier build may still hold a `.ipsw-cache/` directory; it is safe to delete, and `vm export` leaves it out.

```sh
vphone-cli vm list
vphone-cli vm info myphone
vphone-cli vm clone myphone copy
vphone-cli vm export myphone --out myphone.tzst
vphone-cli vm import myphone.tzst --name restored
```

`vm clone` copies the complete machine state, including its device identity and boot files. It uses APFS copy-on-write when available. Edit the identity yourself if you need a different device.

Run resource-heavy creations **one at a time**. Both the IPSWs and temporary restore tree consume substantial disk space, and patching large caches can be memory intensive. Check free space before starting a second VM.
