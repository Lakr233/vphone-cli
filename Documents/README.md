# Documentation

Start with the [Launchpad quick start](../README.md#get-started). For terminal use, see [Create and Run](Guides/create-and-run.md). There is one public firmware mode; a patch preset (Standard, Minimal and others) selects the patches, and `--block` or `--allow` adjusts single patches.

## Get Started

| Page | Use it for |
| --- | --- |
| [Downloads](Downloads/README.md) | Notarized Launchpad versions and matching `VPhone.bundle` versions |
| [Host Setup](Guides/host-setup.md) | Apple Silicon, SIP and AMFI settings, signing and preflight |
| [Create and Run](Guides/create-and-run.md) | The one-command flow, starting and stopping a VM, manual stages |
| [Compatibility](Guides/compatibility.md) | Verified firmware pairs and what the checks prove |

## Machines

| Page | Use it for |
| --- | --- |
| [Firmware Preparation](Guides/firmware-preparation.md) | The GPU driver restore, kernelcache mixes for newer cloudOS, remote linking |
| [Templates](Guides/templates.md) | How `vm create` reuses one restore, offline trim, setup boot and slimming |
| [Building and Finding Templates](Guides/template-building.md) | Turning a VM into a template, `vm template find`, templates in Launchpad |
| [Create Many Machines](Guides/many-machines.md) | `vm create-bulk` from a plist |
| [Device Name and Clock](Guides/device-name-and-clock.md) | What the guest takes from the VM name and the Mac's clock |
| [Library, Firmware and Backups](Guides/library-and-backups.md) | Where machines and caches live, downloads, clones and exports |
| [Sharing Disk Space](Guides/sharing-disk-space.md) | `vm rebase` for VMs restored separately |
| [Snapshots](Guides/snapshots.md) | Saving a stopped VM's disk state and reverting to it |
| [Package Environment](Guides/package-environment.md) | Installing and removing a package manager in the VM |
| [Persistent Shader Caches](Guides/shader-cache.md) | Enabling shader caches on an existing VM |

## Devices

| Page | Use it for |
| --- | --- |
| [Other iPhone Models](Guides/iphone-models.md) | Running iOS from an iPhone 16 Pro, 17, 17 Pro, Air or other model's IPSW |
| [iPadOS Guests](Guides/ipados.md) | Running iPadOS from an iPad restore IPSW instead of iOS |

## Networking

| Page | Use it for |
| --- | --- |
| [Networking](Guides/networking.md) | Network modes, choosing one, unplugging a running VM |
| [Tunnel Mode](Guides/network-tunnel.md) | A Mac behind a VPN or proxy app |
| [MAC and IP Addresses](Guides/network-addresses.md) | The saved MAC, leases held by old MACs, fixed addresses |
| [Port Forwarding](Guides/network-port-forwarding.md) | Carrying a port on the Mac into the guest |
| [Names on the Network](Guides/network-names.md) | The guest's `.local` name and this Mac's name in the guest |
| [Machines Reaching Each Other](Guides/network-peers.md) | `nat` machines on one shared network |

## Reference

| Page | Use it for |
| --- | --- |
| [Launchpad Command Line](Guides/launchpad-cli.md) | Driving Launchpad with `vphone-launchpad-cli` |
| [Core Bundles and Local Builds](Guides/core-bundles.md) | Binding machines to bundles, installing and comparing local builds |
| [Bundle Integration](Guides/bundle-integration.md) | What `VPhone.bundle` contains and how an app integrates it |

## Help

| Page | Use it for |
| --- | --- |
| [Troubleshooting](Guides/troubleshooting.md) | Launch refusals, restore failures, Home key and app problems |

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
