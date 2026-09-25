<div align="right"><a href="Documents/README.md">Docs</a> · <a href="Documents/README_zh.md">中文</a> · <a href="Documents/README_ja.md">日本語</a> · <a href="Documents/README_ko.md">한국어</a></div>

# vphone-cli

> Looking for vphone-cli 1.x? See the [1.0.14 release](https://github.com/Lakr233/vphone-cli/releases/tag/1.0.14).

Create and run a virtual iPhone on an Apple Silicon Mac. vphone-cli uses Apple's Virtualization.framework and PCC research VM infrastructure.

![Virtual iPhone running on macOS](Documents/demo.jpeg)

Version 2.x applies the complete firmware patch set, including changes previously offered as EXP. There are no selectable patch variants. The self-contained `VPhone.bundle` handles firmware preparation, restore, and VM control; `vphone-launchpad` installs the bundle and guides you through creating and running a VM.

The recommended host setup runs `csrutil enable --without debug` and `csrutil allow-research-guests enable` in macOS Recovery. SIP remains enabled with debugging restrictions relaxed. Launchpad checks the host and uses its privileged helper to allow each verified VM binary through AMFI; see [host setup](Documents/Guides/host-setup.md) for details.

## Get started

Use the notarized [vphone-launchpad 2.0.6](https://github.com/Lakr233/vphone-cli/releases/download/2.0.6/vphone-launchpad-2.0.6-notarized.zip) on a physical Apple Silicon Mac running macOS 15 or newer. The release needs no Xcode, Python, or Homebrew at runtime.

1. In macOS Recovery, run `csrutil enable --without debug` and `csrutil allow-research-guests enable`, then restart. See [host setup](Documents/Guides/host-setup.md) for details.
2. Unzip and open the app. Complete **Host Setup**, including Developer Tools access and installation of the privileged helper.
3. In **Core Bundle**, choose **Download and Install** for the latest `VPhone.bundle`. Launchpad verifies the download and prepares its VM binary for the host.
4. In **Machines**, choose **New Machine**, select a firmware pairing from the catalog, and click **Create**. Launchpad completes the first-boot check and leaves the VM running.

Catalog pairings download firmware. Creating a VM needs network access for restore tickets and substantial free disk space, even with local IPSWs. You can supply your own compatible iPhone and cloudOS IPSWs. See [compatibility](Documents/Guides/compatibility.md) for verified pairs. For source builds and terminal workflows, see [host setup](Documents/Guides/host-setup.md) and [create and run](Documents/Guides/create-and-run.md).

Version 2.x starts only VMs created with its `schemaVersion=2` format. Older VMs must be recreated.

## Custom Firmware Bootstrap

After launching the VM, choose **Guest > Install Bootstrap…** from the macOS menu bar and select a layout. This installs Irisin in the guest.

For the first setup, select `apt` and `bash` in Irisin. Press and hold the **Install** button, then choose **Bootstrap Install**. This mode unpacks all packages in the installation before running the installation steps again. It resolves the initial dependency cycle where `debianutils` needs `bash`, but `bash` needs `debianutils` to have been configured. Use regular installation after this setup is complete.

## Everyday use

The VM window provides app and file browsing, clipboard and preference tools, screenshots, recording, and diagnostics. For local automation, launch with `--api-listen 127.0.0.1:8765`. The VM prints a new API token at each launch as `[api] token: …`, or uses `VPHONE_API_TOKEN` when you set it. Send the token with every request, for example `curl -H "Authorization: Bearer $TOKEN" http://127.0.0.1:8765/v1/health`. Requests without the token are refused, and so are requests from web pages. See the [guest API](Research/vphoned_http_api.md).

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
