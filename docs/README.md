# Documentation

[Project overview](../README.md) · [Research notes](../research/README.md)

Start with the [one-command VM flow](guides/create-and-run.md). The guides below describe the current **JB-only** CLI. Older patch variants and installation experiments remain in research notes as historical context, not supported user workflows.

| Guide | Use it for |
| --- | --- |
| [Host setup](guides/host-setup.md) | Apple Silicon, SIP/AMFI settings, signing and preflight |
| [Create and run a VM](guides/create-and-run.md) | Firmware inputs, full or manual pipeline, vphoned, storage and backups |
| [Compatibility](guides/compatibility.md) | Verified firmware pairs and what the checks actually prove |
| [Troubleshooting](guides/troubleshooting.md) | Launch refusals, restore failures, Home key and app problems |

## Translations

[中文](README_zh.md) · [日本語](README_ja.md) · [한국어](README_ko.md) · [Русский](README_ru.md) · [Português](README_pt.md)

These pages give a translated overview and quick start. The English guides above hold the detailed, current procedures so that a change to the host or firmware flow has one place to update.

## For contributors

- [Research index](../research/README.md) groups the patch and implementation records by subject.
- [Patch inventory](../research/0_binary_patch_comparison.md) is the canonical per-component comparison.
- `make help` and `vphone-cli <group> --help` show the current command surface.
- `make check-aux` checks the bundled application's runtime dependency closure.
