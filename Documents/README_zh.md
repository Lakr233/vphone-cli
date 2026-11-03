<div align="right"><a href="../README.md">English</a> · <strong>中文</strong> · <a href="README_ja.md">日本語</a> · <a href="README_ko.md">한국어</a></div>

# vphone-cli

在 Apple Silicon Mac 上运行虚拟 iPhone。

> [!WARNING]
> 本项目从未发行或授权发行任何虚拟货币或代币，也不接受任何虚拟货币付款或捐赠。任何以本项目名义发行、推广或声称与本项目有关的虚拟货币或代币，均属诈骗。

![在 macOS 上运行的虚拟 iPhone](demo.jpeg)

vphone-cli 使用 Apple 的 Virtualization.framework 和 PCC 研究虚拟机运行 iOS，适合安全研究、逆向工程和调试。

- **图形窗口**：在 Mac 上操作虚拟 iPhone 的屏幕，浏览 App 和文件，截屏和录屏。
- **自定义固件（Custom Firmware）**：系统已预先打好补丁，可以安装软件包环境。
- **备份与克隆**：虚拟机可以导出、导入和克隆。
- **自动化 API**：可选的本机 HTTP 和 WebSocket 接口。
- **无需额外依赖**：运行时不需要 Xcode、Python 或 Homebrew。

## 准备工作

- 一台实体 Apple Silicon Mac，运行 macOS 15 或更新版本。macOS 虚拟机中无法使用。
- 足够的磁盘空间。每台虚拟机默认使用 64 GB 虚拟磁盘，固件和临时文件另外占用空间。
- 网络连接。恢复系统时需要在线获取签名票据。
- 修改安全设置。启动进入 macOS 恢复，在终端中执行以下命令，然后重新启动：

  ```sh
  csrutil enable --without debug
  csrutil allow-research-guests enable
  ```

  SIP 仍保持启用，只放宽调试限制。原因和其他设置方式见[宿主机设置](Guides/host-setup.md)。

## 快速开始

1. 从[最新版本](https://github.com/Lakr233/vphone-cli/releases/latest)下载 `vphone-launchpad-<版本>-notarized.zip`，解压并打开。并非每个版本都经过公证。如果最新版本没有 `-notarized` 文件，请在[下载说明](Downloads/README.md)中选择一个已公证的版本。
2. 在 **Host Setup** 中授予开发者工具权限，并安装辅助程序。
3. 在 **Core Bundle** 中点击 **Download and Install**。Launchpad 会下载并校验 `VPhone.bundle`，然后允许其中的虚拟机程序在本机运行。
4. 在 **Machines** 中点击 **New Machine**，选择固件组合，点击 **Create**。

Launchpad 会下载固件、打补丁、恢复系统并首次启动。完成后虚拟机会继续运行。

也可以使用自己的 iPhone 和 cloudOS IPSW，已验证的组合见[兼容性说明](Guides/compatibility.md)。

### 让 Agent 代劳

如果这台 Mac 上有编程 Agent（Claude Code、Codex 等），可以直接粘贴下面的提示词，不必手动操作。Agent 会读取 vphone skill，检查已完成的部分，安装 Launchpad 和 `VPhone.bundle`；遇到需要你处理的步骤（例如管理员密码，或在 macOS 恢复中进行的更改）时会停下来询问。

```text
在这台 Mac 上安装 vphone。先阅读这个 skill：
https://raw.githubusercontent.com/Lakr233/vphone-cli/main/Skills/vphone-guest-control/SKILL.md
以及它在 references/（同一目录）下链接的文件，然后照着做：
安装最新的已公证 vphone-launchpad（并非每个 release 都有 -notarized 压缩包），
把 vphone-launchpad-cli 加到 PATH，安装与 Launchpad 系列一致的 VPhone.bundle，
并运行 `vphone-launchpad-cli status` 检查。不要修改 SIP、boot-args 或任何其他
主机安全设置；在我确认固件和可用磁盘空间之前，不要创建虚拟机。遇到需要我
操作的步骤，请准确告诉我该做什么，然后等待。
```

## 安装软件包环境

虚拟机默认不带软件包管理器。安装步骤：

1. 在菜单栏选择 **Apps > Install Bootstrap…**，布局选择 **roothide**（**rootless** 已弃用）。虚拟机中会安装 Irisin。
2. 在 Irisin 中打开 **OwnGoal Packages** 软件源，找到 **OwnGoal Bootstrap for vphone**（`owngoal-bootstrap-vphone`），选择 **Bootstrap Install** 安装。

   这一个软件包会一次装好虚拟机需要的全部内容：`apt` 和 `dpkg`、`bash`、`zsh` 和 `dash`、`sudo`、常用命令行工具、`openssh-server`、`curl`、`wget`、`vim`、`git`、`uikittools`、`launchctl`，以及 OwnGoal 的几个应用。不要逐个安装这些软件包：其中部分软件包相互依赖，`openssh-server` 的依赖声明也存在循环，逐个安装可能在中途失败。
3. 首次安装完成后，其余软件包使用普通安装即可。

如果首次安装失败，或安装后环境状态异常，不要在原环境上修复。请通过 **Apps > Uninstall Bootstrap…** 删除环境，再从第 1 步重新安装。

要删除环境，选择 **Apps > Uninstall Bootstrap…**，删除后虚拟机会重启。

按住 Option 打开 **Apps** 菜单，还有两个选项：

- **Install Bootstrap from File…**：使用本地的 Irisin `.deb` 安装。
- **Uninstall Bootstrap Without Restarting…**：删除环境，不重启虚拟机。

## 命令行

Launchpad 通过 `VPhone.bundle` 中的 `vphone-cli` 管理虚拟机，你也可以在终端中直接使用：

| 操作 | 命令 |
| --- | --- |
| 列出虚拟机 | `vphone-cli vm list` |
| 查看虚拟机信息 | `vphone-cli vm info myphone` |
| 启动虚拟机 | `vphone-cli vm launch myphone` |
| 停止虚拟机 | `vphone-cli vm stop myphone` |
| 克隆虚拟机 | `vphone-cli vm clone myphone copy` |
| 导出虚拟机 | `vphone-cli vm export myphone --out myphone.tzst` |
| 导入虚拟机 | `vphone-cli vm import myphone.tzst --name restored` |

虚拟机默认保存在 `~/.vphone/`。运行 `vphone-cli <group> --help` 查看全部命令。不使用 Launchpad 创建虚拟机的方法见[创建与运行](Guides/create-and-run.md)。

### 自动化 API

启动时加上 `--api-listen` 即可开启：

```sh
vphone-cli vm launch myphone --api-listen 127.0.0.1:8765
# 输出中会显示 [api] token: …
curl -H "Authorization: Bearer $TOKEN" http://127.0.0.1:8765/v1/health
```

每次启动都会生成新的 token。要使用固定的 token，请设置环境变量 `VPHONE_API_TOKEN`。不带 token 的请求和来自网页的请求都会被拒绝。接口说明见 [API 文档](../Research/vphoned_http_api.md)。

## 启动 ROM

新建的虚拟机不再使用 Virtualization.framework 自带的闭源 ROM，而是从两个开源 ROM 启动：

- [OpenAVB](https://github.com/owngoal-dev/OpenAVB) 替代启动 ROM AVPBooter。它不需要打补丁，`fw patch` 不会改动它。
- [OpenSEP](https://github.com/owngoal-dev/OpenSEP) 替代 SEP 启动 ROM AVPSEPBooter。

两者同时使用时，iBoot 和 SEPOS 之前不会运行任何由 Apple 编写的代码。两个 ROM 都以预编译形式随 `VPhone.bundle` 发布，由固定的上游提交构建。各自的说明（[OpenAVB](../VPhoneExecutable/VPhoneVirtualization/Resources/OpenAVB/README.md)、[OpenSEP](../VPhoneExecutable/VPhoneVirtualization/Resources/OpenSEP/README.md)）写了如何从源码重新构建并逐字节核对。

旧版本创建的虚拟机仍使用 Apple 的 ROM。两种 ROM 可以随时切换，不需要重新恢复系统，下次启动时生效：

```sh
vphone-cli vm config myphone --rom openavb --seprom opensep   # 开源 ROM
vphone-cli vm config myphone --rom apple --seprom apple       # Apple 的 ROM
```

`vphone-cli vm info myphone` 会显示虚拟机使用的 ROM。恢复使用 OpenAVB 启动的虚拟机，需要 `VPhone.bundle` 2.10.1 或更新版本。详细内容见研究记录中的 [OpenAVB](../Research/Firmware/openavb_boot_rom.md) 和 [OpenSEP](../Research/Firmware/opensep_sep_rom.md)。

## 遇到问题

请先查看[故障排查](Guides/troubleshooting.md)，其中包括虚拟机程序被系统拒绝、恢复失败、停在 “Press home to continue” 等情况。如果仍未解决，请[提交 issue](https://github.com/Lakr233/vphone-cli/issues)。

## 文档

| 文档 | 内容 |
| --- | --- |
| [下载说明](Downloads/README.md) | 已公证的 Launchpad 版本及匹配的 `VPhone.bundle` 版本 |
| [宿主机设置](Guides/host-setup.md) | SIP 与 AMFI 设置、源码构建、环境检查 |
| [创建与运行](Guides/create-and-run.md) | 创建流程、启动与停止虚拟机 |
| [模板](Guides/templates.md) | 用一次恢复创建多台虚拟机，精简客户机系统 |
| [资料库与备份](Guides/library-and-backups.md) | 虚拟机的存放位置、克隆与导出 |
| [兼容性说明](Guides/compatibility.md) | 已验证的固件组合 |
| [快照](Guides/snapshots.md) | 保存已停止虚拟机的磁盘状态，并可恢复到该状态 |
| [iPadOS 客户机](Guides/ipados.md) | 运行 iPadOS 而非 iOS |
| [其他 iPhone 机型](Guides/iphone-models.md) | 使用其他 iPhone 机型的 IPSW 运行 iOS |
| [软件包环境](Guides/package-environment.md) | 安装和删除虚拟机中的软件包管理器 |
| [故障排查](Guides/troubleshooting.md) | 常见错误及解决方法 |
| [网络](Guides/networking.md) | 网络模式、地址、端口转发，以及在 Mac 使用 VPN 或代理时用的 `tunnel` |
| [Launchpad 命令行](Guides/launchpad-cli.md) | 用 `vphone-launchpad-cli` 安装和测试本地构建 |
| [全部指南](README.md) | 按主题分组的全部指南 |
| [研究记录](../Research/README.md) | 补丁与实现细节 |

## 项目结构

- `vphone-launchpad`：Mac App，负责下载和安装 `VPhone.bundle`、配置宿主机。单独发布。
- `vphone-cli`：准备固件、打补丁、恢复系统、管理虚拟机。
- `vphone-vm`：运行虚拟机并显示虚拟机窗口。
- `vphoned`：虚拟机中的控制服务，窗口中的功能和 API 都通过它实现。

| 路径 | 内容 |
| --- | --- |
| [`VPhoneExecutable/`](../VPhoneExecutable/) | `vphone-cli`、`vphone-vm`、固件补丁与恢复 |
| [`VPhoneKit/`](../VPhoneKit/) | 宿主机共享库与 API 客户端 |
| [`VPhoneDaemon/`](../VPhoneDaemon/) | `vphoned` |
| [`VPhoneGuestComponents/`](../VPhoneGuestComponents/) | 虚拟机中的 hook 与辅助程序 |
| [`VPhoneLaunchpad/`](../VPhoneLaunchpad/) | Launchpad App 及其辅助程序 |

从源码构建：`xcodebuild -workspace VPhone.xcworkspace -scheme VPhone build`，产物为 `VPhone.bundle`。

## 致谢

- [wh1te4ever/super-tart-vphone-writeup](https://github.com/wh1te4ever/super-tart-vphone-writeup)
- [owngoal-dev/OpenAVB](https://github.com/owngoal-dev/OpenAVB) 和 [owngoal-dev/OpenSEP](https://github.com/owngoal-dev/OpenSEP)：新虚拟机使用的启动 ROM
