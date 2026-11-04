# Downloads

Pick the Launchpad version to download and the `VPhone.bundle` that goes with it. Use this page when the latest release has no notarized Launchpad, or when you need to match versions by hand.

## What each release contains

Each [release](https://github.com/Lakr233/vphone-cli/releases) has up to three files:

| File | Contents |
| --- | --- |
| `vphone-launchpad-<version>-notarized.zip` | Launchpad, signed and notarized by Apple. Download this one when it is available. |
| `vphone-launchpad-<version>.zip` | Launchpad, not notarized. macOS blocks it the first time you open it. |
| `VPhone-<version>.zip` | `VPhone.bundle`. Launchpad downloads and installs it for you, so you do not need this file. |

To open a version that is not notarized, open it once, then go to **System Settings > Privacy & Security** and click **Open Anyway**.

## Notarized Launchpad versions

| Series | Notarized | Not Notarized |
| --- | --- | --- |
| 2.15 | 2.15.0 | 2.15.1 |
| 2.14 | 2.14.0 | 2.14.1, 2.14.2 |
| 2.13 | 2.13.0 | 2.13.1, 2.13.2, 2.13.3, 2.13.4, 2.13.5, 2.13.6, 2.13.7, 2.13.8 |
| 2.12 | 2.12.0, 2.12.2 | 2.12.1 |
| 2.11 | 2.11.0 | — |
| 2.10 | 2.10.1 | — |
| 2.9 | 2.9.0, 2.9.1, 2.9.2 | 2.9.3, 2.9.4, 2.9.5 |
| 2.8 | 2.8.0 | — |
| 2.7 | 2.7.0 | — |
| 2.6 | 2.6.0 | 2.6.1 |
| 2.5 | 2.5.0 | 2.5.1 |
| 2.4 | 2.4.0, 2.4.1 | 2.4.2 |
| 2.3 | 2.3.0 | 2.3.1, 2.3.2 |
| 2.2 | 2.2.0, 2.2.2, 2.2.3, 2.2.4, 2.2.5 | 2.2.1 |
| 2.1 | 2.1.0, 2.1.1, 2.1.2 | 2.1.3, 2.1.4, 2.1.5, 2.1.6, 2.1.7 |
| 2.0 | 2.0.4, 2.0.5, 2.0.6, 2.0.8, 2.0.9 | — |

There is no 2.0.7 or 2.10.0 release.

## Matching Launchpad and VPhone.bundle

Use a `VPhone.bundle` from the same series as Launchpad. The series is the first two numbers of the version: Launchpad 2.2.3 belongs to 2.2 and works with any `VPhone.bundle` 2.2.x.

| Launchpad | VPhone.bundle |
| --- | --- |
| 2.15.x | 2.15.x |
| 2.14.x | 2.14.x |
| 2.13.x | 2.13.x |
| 2.12.x | 2.12.x |
| 2.11.x | 2.11.x |
| 2.10.x | 2.10.x |
| 2.9.x | 2.9.x |
| 2.8.x | 2.8.x |
| 2.7.x | 2.7.x |
| 2.6.x | 2.6.x |
| 2.5.x | 2.5.x |
| 2.4.x | 2.4.x |
| 2.3.x | 2.3.x |
| 2.2.x | 2.2.x |
| 2.1.x | 2.1.x |
| 2.0.x | 2.0.x |

Within a series, install the newest `VPhone.bundle`. Patch releases fix problems without changing how Launchpad and the bundle work together.

Launchpad refuses a `VPhone.bundle` that is too old for it, but it may still list bundles from a newer series. Do not install those; update Launchpad to that series first.

> [!NOTE]
> Launchpad does not update itself. Download the new version from the release page and replace the old app.

## What recent series add

| Series | Adds | Note |
| --- | --- | --- |
| 2.15 | HomeView | Use Launchpad 2.15 with its bundle so New Machine selects the `homeview` preset for `HomeAccessory17,1` and `HomeAccessory17,2`. |
| 2.14 | Patch presets from a file: **Other…** in the preset picker, or `--preset <path>` | Launchpad 2.14 needs a 2.14 bundle. |
| 2.13 | Apple TV 4K (4th generation) | Use Launchpad 2.13 with its bundle so New Machine selects the `tvos-4k` preset for `AppleTV18,1`. |

## Version 1.x

VMs created by 1.x do not start in 2.x. For 1.x, see the [1.0.14 release](https://github.com/Lakr233/vphone-cli/releases/tag/1.0.14).

## See also

- [Quick Start](quick-start.md)
- [Core Bundles](../launchpad/core-bundles.md)
- [Launchpad Command Line](../launchpad/launchpad-cli.md)
