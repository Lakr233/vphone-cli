<div align="right"><a href="Documents/README.md">Docs</a> · <a href="Documents/README_zh.md">中文</a> · <a href="Documents/README_ja.md">日本語</a> · <a href="Documents/README_ko.md">한국어</a></div>

# vphone-cli

> [!WARNING]
> Version 2.0 is under construction. For the stable version, use [1.0.14](https://github.com/Lakr233/vphone-cli/tree/1.0.14).

Create and run a virtual iPhone on an Apple Silicon Mac. vphone-cli uses Apple's Virtualization.framework and PCC research VM infrastructure.

![Virtual iPhone running on macOS](Documents/demo.jpeg)

Version 2.0 removes much of 1.0's heavy host setup and simplifies the system fixes needed by custom firmware. The core flow is now stable enough for a single **JB** configuration: the self-contained `VPhone.bundle` handles firmware download, installation, and launch through its CLI.

For now, the recommended host setup runs `csrutil enable --without debug` and `csrutil allow-research-guests enable` in macOS Recovery. SIP remains enabled with debugging restrictions relaxed. Allowing the VM binary through AMFI requires root; see [host setup](Documents/Guides/host-setup.md) and the [amfi-allow research](https://github.com/Lakr233/amfi-allow). A future `vphone-ui.app` will make setup easier and offer switches for installation-time fixes.

## Get started

You need an Apple Silicon Mac running macOS 15 or newer, Xcode to build from source, an iPhone restore IPSW, and a compatible cloudOS IPSW. Follow [host setup](Documents/Guides/host-setup.md) to permit the VM's private entitlements, then check the [verified firmware pairs](Documents/Guides/compatibility.md). A nested macOS VM cannot run the guest.

```sh
git clone https://github.com/Lakr233/vphone-cli.git
cd vphone-cli
xcodebuild -workspace VPhone.xcworkspace -scheme VPhone \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/XcodeBundle build
export PATH="$PWD/.build/XcodeBundle/Build/Products/Debug/VPhone.bundle/Contents/MacOS:$PATH"

vphone-cli host preflight
vphone-cli vm create myphone \
  --iphone-source /path/to/iPhone17,3_Restore.ipsw \
  --cloudos-source /path/to/cloudOS.ipsw
vphone-cli vm launch myphone
```

`vm create` prepares and restores the guest, installs the JB system changes, and checks that `vphoned` responds. It stops the verification boot when finished; `vm launch` starts the VM window for use. Creation needs network access and administrator privileges for CFW installation. See [create and run](Documents/Guides/create-and-run.md) for details.

Version 2.x starts only VMs created with its `schemaVersion=2` format. Older VMs must be recreated.

## Custom Firmware Bootstrap

After launching the VM, choose **Guest > Install Bootstrap…** from the macOS menu bar and select a layout. This installs Irisin in the guest.

For now, install `coreutils`, `debianutils`, `dash`, and other essential packages in Irisin one at a time. If a package script causes an installation to fail, open the **More** menu at the top left of the failed operation and choose **Ignore Script Errors and Retry**. Irisin still runs the scripts but continues past their errors. Once the environment is ready, return to normal installation. A later release will improve this initial setup.

## Everyday use

The VM window provides app and file browsing, clipboard and preference tools, screenshots, recording, and diagnostics. For local automation, launch with `--api-listen 127.0.0.1:8765`; see the [guest API](Research/vphoned_http_api.md).

| Task | Command |
| --- | --- |
| List VMs | `vphone-cli vm list` |
| Inspect a VM | `vphone-cli vm info myphone` |
| Start the VM window | `vphone-cli vm launch myphone` |
| Stop a VM | `vphone-cli vm stop myphone` |
| Export a backup | `vphone-cli vm export myphone --out myphone.tzst` |
| Import a backup | `vphone-cli vm import myphone.tzst --name restored` |

VMs live under `~/.vphone/` by default. Run `vphone-cli <group> --help` for more commands.

## How it fits together

`vphone-cli` prepares firmware, restores VMs, and manages their lifecycle. The bundled `vphone-vm` runs the guest and owns its macOS window. Inside the guest, `vphoned` provides the controls used by the window and the optional HTTP and WebSocket API. The `VPhone` Xcode scheme builds and validates the self-contained `VPhone.bundle`.

## Repository map

| Path | Contents |
| --- | --- |
| [`VPhoneExecutable/`](VPhoneExecutable/) | CLI, VM process, firmware patcher, and restore backend |
| [`VPhoneKit/`](VPhoneKit/) | Shared host libraries and API client |
| [`VPhoneDaemon/`](VPhoneDaemon/) | Guest control daemon, `vphoned` |
| [`VPhoneGuestComponents/`](VPhoneGuestComponents/) | Guest hooks and support binaries |
| [`Documents/`](Documents/README.md) | Setup, usage, compatibility, and troubleshooting guides |
| [`Research/`](Research/README.md) | Patch and implementation notes |

## Acknowledgements

- [wh1te4ever/super-tart-vphone-writeup](https://github.com/wh1te4ever/super-tart-vphone-writeup)
