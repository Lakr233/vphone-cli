# vphone Manual

New to vphone? Read [Overview](get-started/overview.md), then follow [Quick Start](get-started/quick-start.md).

## Get Started

| Page | Use it for |
| --- | --- |
| [Overview](get-started/overview.md) | What vphone is, what it needs, and the programs it ships |
| [Quick Start](get-started/quick-start.md) | Your first VM with Launchpad, or with a coding agent |
| [Host Setup](get-started/host-setup.md) | SIP, AMFI and Research Guests settings on the Mac |
| [Downloads](get-started/downloads.md) | Notarized Launchpad versions and matching `VPhone.bundle` versions |

## Machines

| Page | Use it for |
| --- | --- |
| [Create and Run](machines/create-and-run.md) | Creating, starting and stopping a VM from Terminal |
| [Boot ROMs](machines/boot-roms.md) | Switching between OpenAVB/OpenSEP and Apple's ROMs |
| [Automation API](machines/automation-api.md) | The optional local HTTP and WebSocket interface |
| [Device Name and Clock](machines/device-name-and-clock.md) | What the guest takes from the VM name and the Mac's clock |
| [Package Environment](machines/package-environment.md) | Installing and removing a package manager in the guest |
| [Cryptexes](machines/cryptexes.md) | Installing your own programs in a trusted darwinOS guest as a cryptex |

## Firmware and Devices

| Page | Use it for |
| --- | --- |
| [Compatibility](firmware/compatibility.md) | Verified iPhone and cloudOS firmware pairs |
| [Firmware Preparation](firmware/firmware-preparation.md) | GPU driver restore, kernelcache mixes for newer cloudOS |
| [Other iPhone Models](firmware/iphone-models.md) | Running iOS from another iPhone model's IPSW |
| [iPadOS Guests](firmware/ipados.md) | Running iPadOS instead of iOS |

## Storage and Backups

| Page | Use it for |
| --- | --- |
| [Library and Backups](storage/library-and-backups.md) | Where VMs and caches live, clones and exports |
| [Snapshots](storage/snapshots.md) | Saving a stopped VM's disk and reverting to it |
| [Templates](storage/templates.md) | Reusing one restore for many VMs |
| [Building Templates](storage/template-building.md) | Turning a VM into a template and finding templates |
| [Sharing Disk Space](storage/sharing-disk-space.md) | `vm rebase` for VMs restored separately |
| [Create Many Machines](storage/many-machines.md) | `vm create-bulk` from a plist |
| [Shader Caches](storage/shader-cache.md) | Persistent shader caches on an existing VM |

## Networking

| Page | Use it for |
| --- | --- |
| [Network Modes](networking/overview.md) | Choosing a mode, unplugging a running VM |
| [Tunnel Mode](networking/tunnel.md) | A Mac behind a VPN or proxy app |
| [MAC and IP Addresses](networking/addresses.md) | The saved MAC, old leases, fixed addresses |
| [Port Forwarding](networking/port-forwarding.md) | Carrying a port on the Mac into the guest |
| [Names on the Network](networking/names.md) | The guest's `.local` name and the Mac's name in the guest |
| [Machines Reaching Each Other](networking/peers.md) | `nat` machines on one shared network |

## Launchpad and Bundles

| Page | Use it for |
| --- | --- |
| [Launchpad Command Line](launchpad/launchpad-cli.md) | Driving Launchpad with `vphone-launchpad-cli` |
| [Core Bundles and Local Builds](launchpad/core-bundles.md) | Binding machines to bundles, testing local builds |
| [Bundle Integration](launchpad/bundle-integration.md) | What `VPhone.bundle` contains and how an app uses it |

## Help

| Page | Use it for |
| --- | --- |
| [Troubleshooting](help/troubleshooting.md) | Launch refusals, restore failures, guest problems |

Implementation notes, patch records and the full API reference are in the [research notes](../../Research/README.md), in English only.
