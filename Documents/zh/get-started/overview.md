# 概览

vphone-cli 在 Apple Silicon Mac 上运行虚拟 iPhone。本页介绍它能做什么、Mac 需要满足哪些条件，以及各个程序分别负责什么。

> [!WARNING]
> 本项目从未发行或授权发行任何虚拟货币或代币，也不接受任何虚拟货币付款或捐赠。任何以本项目名义发行、推广或声称与本项目有关的虚拟货币或代币，均属诈骗。

![在 macOS 上运行的虚拟 iPhone](../../demo.jpeg)

vphone-cli 使用 Apple 的 Virtualization.framework 和 PCC 研究虚拟机运行 iOS，适用于安全研究、逆向工程和调试。

## 功能

- **图形窗口**：在 Mac 上操作虚拟 iPhone 的屏幕，浏览 App 和文件，截屏和录屏。
- **自定义固件**：系统已预先打好补丁，可以安装[软件包环境](../machines/package-environment.md)。
- **备份与克隆**：导出、导入和克隆虚拟机。
- **自动化 API**：可选的本机 HTTP 和 WebSocket 接口。见[自动化 API](../machines/automation-api.md)。
- **无需额外依赖**：运行时不需要 Xcode、Python 或 Homebrew。

## 系统要求

- 一台实体 Apple Silicon Mac，运行 macOS 15 或更新版本。无法在 macOS 虚拟机中使用。
- 足够的磁盘空间。每台虚拟机默认使用 64 GB 虚拟磁盘，固件另外占用空间。
- 网络连接。恢复系统时需要在线获取签名票据。
- 调整安全设置。启动进入 macOS 恢复，在终端中运行以下命令，然后重新启动：

  ```sh
  csrutil enable --without debug
  csrutil allow-research-guests enable
  ```

  SIP 仍保持启用，只放宽调试限制。详情见[宿主机设置](host-setup.md)。

## 四个程序

| 程序 | 作用 |
| --- | --- |
| `vphone-launchpad` | Mac App，负责下载和安装 `VPhone.bundle`，并配置宿主机。单独发布。 |
| `vphone-cli` | 准备固件、打补丁、恢复系统、管理虚拟机。 |
| `vphone-vm` | 运行虚拟机并显示虚拟机窗口。 |
| `vphoned` | 虚拟机中的控制服务。窗口中的功能和 API 都通过它实现。 |

`vphone-cli`、`vphone-vm` 和 `vphoned` 一起包含在 `VPhone.bundle` 中。Launchpad 通过该 bundle 中的 `vphone-cli` 管理每台虚拟机；你也可以在终端中直接运行 `vphone-cli`。

## 另请参阅

- [快速开始](quick-start.md)
- [宿主机设置](host-setup.md)
- [下载](downloads.md)
- [创建与运行虚拟机](../machines/create-and-run.md)
