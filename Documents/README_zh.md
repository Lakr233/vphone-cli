<div align="right"><a href="../README.md">English</a> · <strong>中文</strong> · <a href="README_ja.md">日本語</a> · <a href="README_ko.md">한국어</a></div>

# vphone-cli

> 查找旧版 1.x？请前往 [1.0.14 Release](https://github.com/Lakr233/vphone-cli/releases/tag/1.0.14)。

在 Apple Silicon Mac 上创建和运行虚拟 iPhone。vphone-cli 使用 Apple 的 Virtualization.framework 和 PCC 研究虚拟机基础设施。

![在 macOS 上运行的虚拟 iPhone](demo.jpeg)

2.x 会应用完整的固件补丁集，包含此前作为 EXP 提供的改动；目前不能选择不同的补丁方案。自包含的 `VPhone.bundle` 负责固件准备、恢复和虚拟机控制；`vphone-launchpad` 负责安装 bundle，并引导你创建和运行虚拟机。

推荐在 macOS 恢复模式中执行 `csrutil enable --without debug` 和 `csrutil allow-research-guests enable`。这样会保留 SIP，但放宽调试限制。Launchpad 会检查宿主机，并通过特权辅助程序让 AMFI 放行已验证的虚拟机程序；详见[宿主机设置](Guides/host-setup.md)。

## 开始使用

推荐在运行 macOS 15 或更新版本的实体 Apple Silicon Mac 上使用已公证的 [vphone-launchpad 2.0.4](https://github.com/Lakr233/vphone-cli/releases/download/2.0.4/vphone-launchpad-2.0.4-notarized.zip)。运行发布版无需 Xcode、Python 或 Homebrew。

1. 在 macOS 恢复模式中执行 `csrutil enable --without debug` 和 `csrutil allow-research-guests enable`，然后重新启动。详见[宿主机设置](Guides/host-setup.md)。
2. 解压并打开 App，按 **Host Setup** 的提示授予开发者工具权限并安装特权辅助程序。
3. 在 **Core Bundle** 中点击 **Download and Install**，安装最新的 `VPhone.bundle`。Launchpad 会验证下载内容，并完成虚拟机程序的宿主机准备。
4. 在 **Machines** 中点击 **New Machine**，从目录选择固件组合，再点击 **Create**。Launchpad 完成首次启动检查后，虚拟机会保持运行。

选择目录中的固件组合时会下载固件。即使使用本地 IPSW，创建虚拟机仍需联网获取恢复票据，并留出充足的磁盘空间。也可以自行提供兼容的 iPhone 和 cloudOS IPSW；已验证的组合见[兼容性说明](Guides/compatibility.md)。源码构建和命令行操作见[宿主机设置](Guides/host-setup.md)与[创建与运行指南](Guides/create-and-run.md)。

2.x 版只能启动以 `schemaVersion=2` 格式创建的虚拟机。旧版虚拟机需要重新创建。

## 定制固件 Bootstrap

启动虚拟机后，在 macOS 菜单栏选择 **Guest > Install Bootstrap…**，再选择所需的环境布局。此操作会在访客系统内安装 Irisin。
按住 Option 打开此菜单项可选取本地 Irisin `.deb`；按住 Option 打开 **Uninstall Bootstrap…** 会同时删除现存的 rootless 和 RootHide 环境，但不重启客体。普通卸载会在删除后重启。

首次准备环境时，在 Irisin 中选中 `apt` 和 `bash`，长按**安装**按钮，然后选择**引导安装（Bootstrap Install）**。这种模式会先解压本次安装涉及的所有软件包，再重新执行安装流程，以绕过初始阶段的依赖循环：`debianutils` 需要 `bash`，而 `bash` 又需要已经配置好的 `debianutils`。首次准备完成后，即可使用普通安装模式。

## 日常使用

虚拟机窗口提供 App 和文件浏览、剪贴板与偏好设置工具、截图、录屏及诊断功能。需要本机自动化接口时，可用 `--api-listen 127.0.0.1:8765` 启动；详见[访客 API](../Research/vphoned_http_api.md)。

| 操作 | 命令 |
| --- | --- |
| 列出虚拟机 | `vphone-cli vm list` |
| 查看虚拟机 | `vphone-cli vm info myphone` |
| 启动虚拟机窗口 | `vphone-cli vm launch myphone` |
| 停止虚拟机 | `vphone-cli vm stop myphone` |
| 导出备份 | `vphone-cli vm export myphone --out myphone.tzst` |
| 导入备份 | `vphone-cli vm import myphone.tzst --name restored` |

虚拟机默认保存在 `~/.vphone/`。更多命令可运行 `vphone-cli <group> --help` 查看。

## 架构简述

`vphone-cli` 负责准备固件、恢复虚拟机并管理其生命周期。bundle 中的 `vphone-vm` 运行访客系统并管理 macOS 窗口。访客系统内的 `vphoned` 为窗口以及可选的 HTTP 和 WebSocket API 提供控制能力。Xcode 的 `VPhone` scheme 会构建并验证自包含的 `VPhone.bundle`。

## 仓库目录

| 路径 | 内容 |
| --- | --- |
| [`VPhoneExecutable/`](../VPhoneExecutable/) | CLI、虚拟机进程、固件补丁与恢复后端 |
| [`VPhoneKit/`](../VPhoneKit/) | 宿主机共享库与 API 客户端 |
| [`VPhoneDaemon/`](../VPhoneDaemon/) | 访客控制服务 `vphoned` |
| [`VPhoneGuestComponents/`](../VPhoneGuestComponents/) | 访客系统 hook 与辅助程序 |
| [`Documents/`](README.md) | 设置、使用、兼容性和故障排查指南 |
| [`Research/`](../Research/README.md) | 补丁与实现研究记录 |

## 致谢

- [wh1te4ever/super-tart-vphone-writeup](https://github.com/wh1te4ever/super-tart-vphone-writeup)
