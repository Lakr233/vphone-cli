<div align="right"><strong>English</strong> · <a href="docs/README_zh.md">中文</a> · <a href="docs/README_ja.md">日本語</a> · <a href="docs/README_ko.md">한국어</a></div>

# vphone-cli

Boot a virtual iPhone with Apple's Virtualization.framework and PCC research VM infrastructure.

![Virtual iPhone running on macOS](docs/demo.jpeg)

The supported firmware flow is **JB only**. It applies the required system patches and installs **vphoned** for host control. It leaves the guest user environment alone: no package manager, SSH server, VNC server, or first-boot bootstrap is installed.

## Quick start

Use an Apple Silicon Mac running macOS 15 or newer. The host must permit PV=3 research guests and the private entitlements on `vphone-vm`; see [host setup](docs/guides/host-setup.md) before the first boot. A Mac running inside another VM cannot boot this guest.

```sh
vphone-cli vm create myphone \
  --iphone-source /path/to/iPhone17,3_Restore.ipsw \
  --cloudos-source /path/to/cloudOS.ipsw

vphone-cli vm launch myphone
```

To expose the guest HTTP and WebSocket API on the host for local tools or an
app using `VPhoneAPIKit`, opt in when launching:

```sh
vphone-cli vm launch myphone --api-listen 127.0.0.1:8765
```

The guest runs `icli` commands through the API. See the [API design and usage](research/vphoned_http_api.md)
for routes, WebSocket messages, and the Swift Kit client.

`vm create` prepares and patches firmware, restores the VM, installs the JB system changes and vphoned, then boots once to check a real vphoned ping. **It stops that verification boot before returning.** Run `vm launch` to keep using the VM. The create flow needs network access for Apple's restore ticket and asks for administrator authentication during CFW installation.

For local validation, iPhone17,3 **26.6.2 (23G90)** and **27.0 (24A435)** both reached the lock screen and answered vphoned ping with cloudOS **26.4 (23E5207q)**. See [compatibility and evidence](docs/guides/compatibility.md); other firmware combinations are not implied by these results.

## Install or build

A distributed `.app` uses macOS system tools and its own bundled binaries; it does not need Homebrew, Python, or Xcode to run. Building from source does not install a separate runtime environment.

Building from source needs Xcode, including its iPhoneOS SDK for vphoned:

```sh
git clone --recurse-submodules https://github.com/Lakr233/vphone-cli.git
cd vphone-cli
zsh Scripts/build.sh
.build/release/vphone-cli --help
```

`Scripts/build.sh` builds, signs, and bundles the binaries. Run `swift test` for the Swift tests and `zsh Scripts/check_aux.sh` for the bundle checks. After every rebuild, a host using the AMFI allowlist must allow the new signed binaries because their cdhashes change. See [host setup](docs/guides/host-setup.md).

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

## Documentation

- [Documentation index](docs/README.md) — setup, workflows, compatibility, troubleshooting, and translations.
- [Create and run a VM](docs/guides/create-and-run.md) — full flow, manual stages, storage, and vphoned.
- [Research index](research/README.md) — patch inventory, firmware analysis, restore work, and historical notes.
- [Patch inventory](research/0_binary_patch_comparison.md) — per-component patch breakdown and historical variant comparison. Only JB is exposed by the current CLI.

## Acknowledgements

- [wh1te4ever/super-tart-vphone-writeup](https://github.com/wh1te4ever/super-tart-vphone-writeup)
