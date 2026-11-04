# 快速开始

用 Launchpad 设置 vphone，并启动第一台虚拟 iPhone。请在 Mac 满足[系统要求](overview.md)后再进行。

## 用 Launchpad 设置

1. 从[最新版本](https://github.com/Lakr233/vphone-cli/releases/latest)下载 `vphone-launchpad-<version>-notarized.zip`，解压并打开。并非每个版本都经过公证。如果最新版本没有 `-notarized` 文件，请在[下载](downloads.md)中选择一个已公证的版本。
2. 在 **Host Setup**（宿主机设置）中授予开发者工具权限，并安装辅助程序。
3. 在 **Core Bundle** 中点击 **Download and Install**（下载并安装）。
4. 在 **Machines**（虚拟机）中点击 **New Machine**（新建虚拟机），选择固件组合，然后点击 **Create**（创建）。

Launchpad 会下载固件、打补丁、恢复系统并启动虚拟机。要使用自己的 iPhone 和 cloudOS IPSW，请参阅[兼容性](../firmware/compatibility.md)。

## 让 Agent 代劳

如果你在这台 Mac 上使用编程 Agent（Claude Code、Codex 等），可以直接粘贴下面的提示词，不必手动操作。Agent 会读取 vphone skill，检查哪些已经设置好，安装 Launchpad 和 `VPhone.bundle`；遇到需要你处理的步骤（例如输入管理员密码，或在 macOS 恢复中进行更改）时会停下来询问。

```text
在这台 Mac 上设置 vphone。先阅读这个 skill：
https://raw.githubusercontent.com/Lakr233/vphone-cli/main/Skills/vphone-guest-control/SKILL.md
以及它在 references/（同一目录）下链接的文件，然后照着做：
安装最新的已公证 vphone-launchpad（并非每个 release 都有 -notarized 压缩包），
把 vphone-launchpad-cli 加到 PATH，安装与 Launchpad 系列一致的 VPhone.bundle，
并运行 `vphone-launchpad-cli status` 检查。不要修改 SIP、boot-args 或任何其他
宿主机安全设置；在我确认固件和可用磁盘空间之前，不要创建虚拟机。遇到需要我
操作的步骤，请准确告诉我该做什么，然后等待。
```

## 后续步骤

- 在虚拟机中安装软件包管理器：[软件包环境](../machines/package-environment.md)。
- 在终端中管理虚拟机，或不用 Launchpad 创建虚拟机：[创建与运行虚拟机](../machines/create-and-run.md)。
- 通过 HTTP 和 WebSocket 编写脚本控制虚拟机：[自动化 API](../machines/automation-api.md)。
- 遇到问题：[故障排查](../help/troubleshooting.md)。

## 另请参阅

- [宿主机设置](host-setup.md)
- [下载](downloads.md)
- [Launchpad 命令行](../launchpad/launchpad-cli.md)
