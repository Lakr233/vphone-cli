# Documentation

Start with the [Launchpad quick start](../README.md#get-started). For terminal use, see [Create and Run](Guides/create-and-run.md). There is one public firmware mode; a patch preset (Standard, Minimal and others) selects the patches, and `--block` or `--allow` adjusts single patches.

| Guide | Use it for |
| --- | --- |
| [Downloads](Downloads/README.md) | Notarized Launchpad versions and matching `VPhone.bundle` versions |
| [Host Setup](Guides/host-setup.md) | Apple Silicon, SIP and AMFI settings, signing and preflight |
| [Create and Run](Guides/create-and-run.md) | Firmware inputs, full or manual pipeline, vphoned, storage and backups |
| [Snapshots](Guides/snapshots.md) | Saving a stopped VM's disk state and reverting to it |
| [Compatibility](Guides/compatibility.md) | Verified firmware pairs and what the checks prove |
| [iPadOS Guests](Guides/ipados.md) | Running iPadOS from an iPad restore IPSW instead of iOS |
| [Other iPhone Models](Guides/iphone-models.md) | Running iOS from an iPhone 16 Pro, 17, 17 Pro, Air or other model's IPSW |
| [Package Environment](Guides/package-environment.md) | Installing and removing a package manager in the VM |
| [Troubleshooting](Guides/troubleshooting.md) | Launch refusals, restore failures, Home key and app problems |
| [Networking](Guides/networking.md) | Network modes, fixed addresses, port forwarding, and `tunnel` for a Mac behind a VPN or proxy |
| [Launchpad Command Line](Guides/launchpad-cli.md) | Installing and testing a local build with `vphone-launchpad-cli` |

## Translations

[中文](README_zh.md) · [日本語](README_ja.md) · [한국어](README_ko.md)

These pages give a translated overview and quick start. The guides above hold the current procedures.

## For Contributors

- `vphone-launchpad`: A Mac app that downloads and installs `VPhone.bundle` and sets up the host. Released separately.
- `vphone-cli`: Prepares firmware, patches it, restores the system, and manages VMs.
- `vphone-vm`: Runs the VM and shows its window.
- `vphoned`: The control service inside the VM. The window's features and the API work through it.

| Path | Contents |
| --- | --- |
| [`VPhoneExecutable/`](../VPhoneExecutable/) | `vphone-cli`, `vphone-vm`, firmware patching and restore |
| [`VPhoneKit/`](../VPhoneKit/) | Shared host libraries and API client |
| [`VPhoneDaemon/`](../VPhoneDaemon/) | `vphoned` |
| [`VPhoneGuestComponents/`](../VPhoneGuestComponents/) | Hooks and helper programs inside the VM |
| [`VPhoneLaunchpad/`](../VPhoneLaunchpad/) | The Launchpad app and its helper |

- `xcodebuild -workspace VPhone.xcworkspace -scheme VPhone build` produces and validates `VPhone.bundle`. Run each project's test scheme separately.
- The [research index](../Research/README.md) groups patch and implementation records by subject.
- The [patch inventory](../Research/0_binary_patch_comparison.md) compares patches per component.
