# Quick Start

Set up vphone with Launchpad and boot your first virtual iPhone. Do this once your Mac meets the [requirements](overview.md#requirements).

## Set up with Launchpad

1. Download `vphone-launchpad-<version>-notarized.zip` from the [latest release](https://github.com/Lakr233/vphone-cli/releases/latest), unzip it, and open it. Not every release is notarized. If the latest one has no `-notarized` file, pick a notarized version from [Downloads](downloads.md).
2. In **Host Setup**, grant Developer Tools access and install the helper.
3. In **Core Bundle**, click **Download and Install**.
4. In **Machines**, click **New Machine**, choose a firmware pairing, and click **Create**.

Launchpad downloads the firmware, patches it, restores the system, and boots the VM. To use your own iPhone and cloudOS IPSWs, see [Compatibility](../firmware/compatibility.md).

## Let an agent do it

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

## Next steps

- Install a package manager in the VM: [Package Environment](../machines/package-environment.md).
- Drive VMs from Terminal, or create one without Launchpad: [Create and Run a VM](../machines/create-and-run.md).
- Script the VM over HTTP and WebSocket: [Automation API](../machines/automation-api.md).
- Something went wrong: [Troubleshooting](../help/troubleshooting.md).

## See also

- [Host Setup](host-setup.md)
- [Downloads](downloads.md)
- [Launchpad Command Line](../launchpad/launchpad-cli.md)
