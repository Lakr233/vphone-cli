<div align="right"><a href="https://lakr233.github.io/vphone-cli/">Docs</a> · <strong>English</strong> · <a href="https://lakr233.github.io/vphone-cli/zh/">中文</a> · <a href="https://lakr233.github.io/vphone-cli/ja/">日本語</a> · <a href="https://lakr233.github.io/vphone-cli/ko/">한국어</a></div>

# vphone-cli

Run a virtual iPhone on an Apple Silicon Mac.

> [!WARNING]
> This project has never issued or authorized any cryptocurrency or token, and does not accept cryptocurrency payments or donations. Any cryptocurrency or token issued or promoted in this project's name, or claiming any affiliation with it, is a scam.

![Virtual iPhone running on macOS](Documents/demo.jpeg)

vphone-cli runs iOS with Apple's Virtualization.framework and PCC research virtual machines, for security research, reverse engineering, and debugging.

## Documentation

Everything else lives on the documentation site: **<https://lakr233.github.io/vphone-cli/>**

- [Quick Start](https://lakr233.github.io/vphone-cli/get-started/quick-start): requirements, host settings, and your first VM with Launchpad.
- [Manual](https://lakr233.github.io/vphone-cli/get-started/overview): machines, firmware, storage, networking, and troubleshooting, in English, 中文, 日本語 and 한국어.
- [Research Notes](https://lakr233.github.io/vphone-cli/research/): patches, boot chain, restore, and the automation API reference.

The sources of the site are in [`Documents/`](Documents/) and [`Research/`](Research/).

## Let an Agent Install It

If you use a coding agent (Claude Code, Codex, or similar) on this Mac, paste the prompt below instead of following the steps by hand. The agent reads the vphone skill, checks what is already set up, installs Launchpad and `VPhone.bundle`, and stops to ask when a step needs you, such as an administrator password or a change in macOS Recovery.

```text
Set up vphone on this Mac. Read the skill at
https://raw.githubusercontent.com/Lakr233/vphone-cli/main/Skills/vphone-guest-control/SKILL.md
and the files it links under references/ (same folder), then follow them:
install the newest notarized vphone-launchpad (not every release has a
-notarized zip), put vphone-launchpad-cli on PATH, install the VPhone.bundle
that matches Launchpad's series, and check `vphone-launchpad-cli status`.
Do not change SIP, boot-args or any other host security setting, and do not
create a machine until I confirm the firmware and the free disk space. When a
step needs me, tell me exactly what to do and wait.
```

## Acknowledgements

- [wh1te4ever/super-tart-vphone-writeup](https://github.com/wh1te4ever/super-tart-vphone-writeup)
- [owngoal-dev/OpenAVB](https://github.com/owngoal-dev/OpenAVB) and [owngoal-dev/OpenSEP](https://github.com/owngoal-dev/OpenSEP), the boot ROMs new VMs start from

## License

vphone-cli is released under the [MIT License](LICENSE).
