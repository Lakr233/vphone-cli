<div align="right"><a href="Documents/README.md">Documentation and translations</a></div>

# vphone-cli

Boot a virtual iPhone with Apple's Virtualization.framework and PCC research VM infrastructure.

![Virtual iPhone running on macOS](Documents/demo.jpeg)

The supported firmware flow is **JB only**. It applies the required system patches and installs **vphoned** for host control. It leaves the guest user environment alone: no package manager, SSH server, VNC server, or first-boot bootstrap is installed.

## Quick start

Use an Apple Silicon Mac running macOS 15 or newer. The host must permit PV=3 research guests and the private entitlements on `vphone-vm`; see [host setup](Documents/Guides/host-setup.md) before the first boot. A Mac running inside another VM cannot boot this guest.

**v2.0.0 VM compatibility:** This release starts only newly created VMs with
`schemaVersion=2`. VMs created by earlier releases must be recreated with
`vm create`; there is no in-place upgrade.

```sh
vphone-cli vm create myphone \
  --iphone-source /path/to/iPhone17,3_Restore.ipsw \
  --cloudos-source /path/to/cloudOS.ipsw

vphone-cli vm launch myphone
```

To expose the guest HTTP and WebSocket API on the host for local tools or an
app using `VPhoneExternalAccessKit`, opt in when launching:

```sh
vphone-cli vm launch myphone --api-listen 127.0.0.1:8765
```

The guest runs `icli` commands through the API. See the [API design and usage](Research/vphoned_http_api.md)
for routes, WebSocket messages, and the Swift Kit client.

`vm create` prepares and patches firmware, restores the VM, installs the JB system changes and vphoned, then boots once to check a real vphoned ping. **It stops that verification boot before returning.** Run `vm launch` to keep using the VM. The create flow needs network access for Apple's restore ticket and requires the caller to provide root privileges for CFW installation.

For local validation, iPhone17,3 **26.6.2 (23G90)** and **27.0 (24A435)** both reached the lock screen and answered vphoned ping with cloudOS **26.4 (23E5207q)**. See [compatibility and evidence](Documents/Guides/compatibility.md); other firmware combinations are not implied by these results.

## Build the bundle

Xcode builds a self-contained `VPhone.bundle` for a future `vphone-workstation`
to download and load. The bundle contains no app launcher, installer, privileged
service or password prompt. Root access and installation belong to the
workstation. Building from source needs Xcode and its iPhoneOS SDK for vphoned:

```sh
git clone https://github.com/Lakr233/vphone-cli.git
cd vphone-cli
xcodebuild -workspace VPhone.xcworkspace -scheme VPhone \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/XcodeBundle build
.build/XcodeBundle/Build/Products/Debug/VPhone.bundle/Contents/MacOS/vphone-cli --help
```

The `VPhone` scheme builds the host tools, guest daemon, and guest components;
every shipped binary is under `Contents/MacOS`. They use ad hoc code signatures,
with private virtualization entitlements only on `vphone-vm`. Run the test
schemes in their respective projects and `zsh Scripts/check_aux.sh` to inspect
the bundle. An AMFI allowlist must be updated whenever the VM binary's cdhash
changes. See [host setup](Documents/Guides/host-setup.md) and the
[bundle integration contract](Documents/Guides/bundle-integration.md).

## Everyday commands

| Task | Command |
| --- | --- |
| List VMs | `vphone-cli vm list` |
| Inspect a VM | `vphone-cli vm info myphone` |
| Start its window | `vphone-cli vm launch myphone` |
| Stop it | `vphone-cli vm stop myphone` |
| Back it up | `vphone-cli vm export myphone --out myphone.tzst` |
| Restore a backup | `vphone-cli vm import myphone.tzst --name restored` |
| Inspect firmware pairings | `vphone-cli fw catalog` |
| Check the host | `vphone-cli host preflight` |

VMs and downloaded firmware live under `~/.vphone/` by default. `VPHONE_ROOT` relocates the tree; `VPHONE_LIBRARY_ROOT` overrides just the VM library. Use `vphone-cli <group> --help` for current command options.

## Acknowledgements

- [wh1te4ever/super-tart-vphone-writeup](https://github.com/wh1te4ever/super-tart-vphone-writeup)
