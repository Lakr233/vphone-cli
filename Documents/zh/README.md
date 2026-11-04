# vphone 使用手册

初次使用 vphone？请先阅读[概览](get-started/overview.md)，然后按照[快速开始](get-started/quick-start.md)操作。

## 入门

| 页面 | 用途 |
| --- | --- |
| [概览](get-started/overview.md) | vphone 是什么、需要什么，以及随附的各个程序 |
| [快速开始](get-started/quick-start.md) | 用 Launchpad 或编程 Agent 创建第一台虚拟机 |
| [宿主机设置](get-started/host-setup.md) | Mac 上的 SIP、AMFI 和 Research Guests 设置 |
| [下载](get-started/downloads.md) | 已公证的 Launchpad 版本及匹配的 `VPhone.bundle` 版本 |

## 虚拟机

| 页面 | 用途 |
| --- | --- |
| [创建与运行](machines/create-and-run.md) | 在终端中创建、启动和停止虚拟机 |
| [启动 ROM](machines/boot-roms.md) | 在 OpenAVB/OpenSEP 与 Apple 的 ROM 之间切换 |
| [自动化 API](machines/automation-api.md) | 可选的本机 HTTP 和 WebSocket 接口 |
| [设备名称与时钟](machines/device-name-and-clock.md) | 客户机从虚拟机名称和 Mac 时钟获取哪些信息 |
| [软件包环境](machines/package-environment.md) | 在客户机中安装和删除软件包管理器 |

## 固件与设备

| 页面 | 用途 |
| --- | --- |
| [兼容性](firmware/compatibility.md) | 已验证的 iPhone 与 cloudOS 固件组合 |
| [固件准备](firmware/firmware-preparation.md) | GPU 驱动恢复，以及较新 cloudOS 的 kernelcache 组合 |
| [其他 iPhone 机型](firmware/iphone-models.md) | 使用其他 iPhone 机型的 IPSW 运行 iOS |
| [iPadOS 客户机](firmware/ipados.md) | 运行 iPadOS 而非 iOS |

## 存储与备份

| 页面 | 用途 |
| --- | --- |
| [资料库与备份](storage/library-and-backups.md) | 虚拟机和缓存的存放位置、克隆与导出 |
| [快照](storage/snapshots.md) | 保存已停止虚拟机的磁盘，并还原到该状态 |
| [模板](storage/templates.md) | 一次恢复，供多台虚拟机复用 |
| [构建模板](storage/template-building.md) | 把虚拟机制作成模板，以及查找模板 |
| [共享磁盘空间](storage/sharing-disk-space.md) | 对分别恢复的虚拟机使用 `vm rebase` |
| [批量创建虚拟机](storage/many-machines.md) | 从 plist 运行 `vm create-bulk` |
| [着色器缓存](storage/shader-cache.md) | 为现有虚拟机启用持久的着色器缓存 |

## 网络

| 页面 | 用途 |
| --- | --- |
| [网络模式](networking/overview.md) | 选择模式，为运行中的虚拟机断开网络 |
| [隧道模式](networking/tunnel.md) | Mac 使用 VPN 或代理 App 时 |
| [MAC 与 IP 地址](networking/addresses.md) | 保存的 MAC 地址、旧租约、固定地址 |
| [端口转发](networking/port-forwarding.md) | 把 Mac 上的端口转发到客户机 |
| [网络上的名称](networking/names.md) | 客户机的 `.local` 名称，以及客户机中 Mac 的名称 |
| [虚拟机互访](networking/peers.md) | 位于同一共享网络中的 `nat` 虚拟机 |

## Launchpad 与 Bundle

| 页面 | 用途 |
| --- | --- |
| [Launchpad 命令行](launchpad/launchpad-cli.md) | 用 `vphone-launchpad-cli` 操作 Launchpad |
| [Core Bundle 与本地构建](launchpad/core-bundles.md) | 把虚拟机绑定到 bundle，测试本地构建 |
| [Bundle 集成](launchpad/bundle-integration.md) | `VPhone.bundle` 包含什么，以及 App 如何使用它 |

## 帮助

| 页面 | 用途 |
| --- | --- |
| [故障排查](help/troubleshooting.md) | 启动被拒、恢复失败、客户机问题 |

实现说明、补丁记录和完整的 API 参考见[研究记录](../../Research/README.md)，仅提供英文版。
