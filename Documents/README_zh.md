<div align="right"><a href="../README.md">English</a> · <strong>中文</strong> · <a href="README_ja.md">日本語</a> · <a href="README_ko.md">한국어</a></div>

# vphone-cli

> [!WARNING]
> 2.0 版仍在开发中。需要稳定版本请使用 [1.0.14](https://github.com/Lakr233/vphone-cli/tree/1.0.14)。

在 Apple Silicon Mac 上创建和运行虚拟 iPhone。vphone-cli 使用 Apple 的 Virtualization.framework 和 PCC 研究虚拟机基础设施。

![在 macOS 上运行的虚拟 iPhone](demo.jpeg)

2.0 移除了 1.0 中不少繁重的宿主机环境配置，也精简了定制固件所需的系统修复。目前核心流程已趋于稳定，因此只保留一套 **JB** 配置：自包含的 `VPhone.bundle` 通过其中的 CLI 完成固件下载、安装和启动。

目前推荐在 macOS 恢复模式中执行 `csrutil enable --without debug` 和 `csrutil allow-research-guests enable`。这样会保留 SIP，但放宽调试限制。让 AMFI 放行虚拟机程序需要 root 权限；具体步骤见[宿主机设置](Guides/host-setup.md)，原理见 [amfi-allow 研究项目](https://github.com/Lakr233/amfi-allow)。后续的 `vphone-ui.app` 会简化设置，并提供安装阶段修复项的开关。

## 开始使用

需要运行 macOS 15 或更新版本的 Apple Silicon Mac、用于源码构建的 Xcode、iPhone 恢复 IPSW，以及兼容的 cloudOS IPSW。先按[宿主机设置](Guides/host-setup.md)允许虚拟机所需的私有授权，并查看[已验证的固件组合](Guides/compatibility.md)。不能在嵌套的 macOS 虚拟机中运行访客系统。

```sh
git clone https://github.com/Lakr233/vphone-cli.git
cd vphone-cli
xcodebuild -workspace VPhone.xcworkspace -scheme VPhone \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/XcodeBundle build
export PATH="$PWD/.build/XcodeBundle/Build/Products/Debug/VPhone.bundle/Contents/MacOS:$PATH"

vphone-cli host preflight
vphone-cli vm create myphone \
  --iphone-source /path/to/iPhone17,3_Restore.ipsw \
  --cloudos-source /path/to/cloudOS.ipsw
vphone-cli vm launch myphone
```

`vm create` 准备和恢复访客系统、安装 JB 系统改动，并确认 `vphoned` 能响应。验证完成后，它会停止本次启动；执行 `vm launch` 才会打开供日常使用的虚拟机窗口。创建过程需要网络，安装 CFW 需要管理员权限。详见[创建与运行指南](Guides/create-and-run.md)。

2.x 版只能启动以 `schemaVersion=2` 格式创建的虚拟机。旧版虚拟机需要重新创建。

## 定制固件 Bootstrap

启动虚拟机后，在 macOS 菜单栏选择 **Guest > Install Bootstrap…**，再选择所需的环境布局。此操作会在访客系统内安装 Irisin。

目前需要在 Irisin 中依次安装 `coreutils`、`debianutils`、`dash` 等基础软件包。如果安装因软件包脚本出错而失败，请打开失败操作页面左上角的 **More** 菜单，选择 **Ignore Script Errors and Retry**。Irisin 仍会运行脚本，但会忽略脚本错误继续安装。环境就绪后，即可恢复正常安装。后续版本会改善这段初始配置流程。

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
