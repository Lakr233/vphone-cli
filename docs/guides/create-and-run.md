# Create and run a VM

[Documentation](../README.md) · [Host setup](host-setup.md) · [Compatibility](compatibility.md)

The public firmware workflow creates one **JB** configuration. It patches the boot chain and guest system, installs vphoned, and leaves the user's environment empty. It does not install Sileo, apt, TrollStore, an SSH server or VNC server.

## One-command flow

Supply an iPhone17,3 restore IPSW and a compatible PCC/cloudOS IPSW as local paths or URLs. [Compatibility](compatibility.md) records the pairs actually verified here.

```sh
vphone-cli host preflight
vphone-cli vm create myphone \
  --iphone-source /path/to/iPhone17,3_Restore.ipsw \
  --cloudos-source /path/to/cloudOS.ipsw
```

Creation runs prepare → JB patch → online DFU restore → host-mounted CFW installation → first GUI boot. It needs network access for the restore ticket. CFW installation needs administrator authentication; on a host without an interactive terminal, `--root-popup` uses a macOS authentication dialog. The default virtual disk is 64 GB. `--keep-artifacts` retains the large prepared restore tree; omit it when disk space matters.

If Apple's WKMS server no longer serves the AEA key for the selected PCC image, `vm create` and `fw prepare` accept `--gpu-driver-bundle /path/to/AppleParavirtGPUMetalIOGPUFamily.bundle`. Supply a complete bundle previously extracted from **the same cloudOS build**. The CLI validates its files and identifier, then stages it in the restore tree without decrypting the PCC OS image. The iPhone restore still uses its own AEA keys and an online restore ticket.

Success ends with `First boot: vphoned ping succeeded` and `JB VM created; vphoned connected`. **The verification VM is then stopped.** The ping proves the daemon answered over the host control socket during that boot; it does not leave a running VM behind.

```sh
vphone-cli vm launch myphone  # start the VM window and keep it running
vphone-cli vm stop myphone    # run from another terminal to stop it
```

`vm launch` starts the guest without waiting for vphoned; the daemon connects during boot. The VM window and menu provide Home/power keys, app installation and file browsing. The host control socket is `<VM bundle>/vphone.sock`. No SSH or VNC endpoint is installed by this workflow.

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
| `~/.vphone/VMs/` | One bundle per VM, including its disk and `config.plist` |
| `~/.vphone/ipsws/` | Cached source IPSWs |
| `~/.vphone/tools/` | Cached firmware patching tools and artifacts |

`VPHONE_ROOT` relocates the complete tree. `VPHONE_LIBRARY_ROOT` takes precedence for the VM library alone. Source IPSWs remain cached; the prepared restore tree is removed after a successful `vm create` unless `--keep-artifacts` is set.

```sh
vphone-cli vm list
vphone-cli vm info myphone
vphone-cli vm clone myphone copy
vphone-cli vm export myphone --out myphone.tzst
vphone-cli vm import myphone.tzst --name restored
```

Run resource-heavy creations **one at a time**. Both the IPSWs and temporary restore tree consume substantial disk space, and patching large caches can be memory intensive. Check free space before starting a second VM.
