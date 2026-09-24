# Documentation

[Research notes](../Research/README.md)

Start with the [one-command VM flow](Guides/create-and-run.md). The guides below describe the current **JB-only** CLI. Older patch variants and installation experiments remain in research notes as historical context, not supported user workflows.

| Guide | Use it for |
| --- | --- |
| [Host setup](Guides/host-setup.md) | Apple Silicon, SIP/AMFI settings, signing and preflight |
| [Create and run a VM](Guides/create-and-run.md) | Firmware inputs, full or manual pipeline, vphoned, storage and backups |
| [Compatibility](Guides/compatibility.md) | Verified firmware pairs and what the checks actually prove |
| [Troubleshooting](Guides/troubleshooting.md) | Launch refusals, restore failures, Home key and app problems |

## Translations

[中文](README_zh.md) · [日本語](README_ja.md) · [한국어](README_ko.md)

These pages give a translated overview and quick start. The guides above hold the detailed, current procedures so that a change to the host or firmware flow has one place to update.

## For contributors

- [Research index](../Research/README.md) groups the patch and implementation records by subject.
- [Patch inventory](../Research/0_binary_patch_comparison.md) is the canonical per-component comparison.
- `xcodebuild -workspace VPhone.xcworkspace -scheme VPhone build` produces and validates `VPhone.bundle`; run each project's test scheme separately.
- `vphone-cli <group> --help` shows the CLI command surface.
