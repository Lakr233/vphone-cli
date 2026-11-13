# 下载

选择要下载的 Launchpad 版本以及与之配套的 `VPhone.bundle`。如果最新版本没有已公证的 Launchpad，或者需要手动匹配版本，请参阅本页。

## 每个版本包含的文件

每个[版本](https://github.com/Lakr233/vphone-cli/releases)最多包含三个文件：

| 文件 | 内容 |
| --- | --- |
| `vphone-launchpad-<version>-notarized.zip` | Launchpad，已由 Apple 签名和公证。有这个文件时请下载它。 |
| `vphone-launchpad-<version>.zip` | Launchpad，未经公证。首次打开时 macOS 会阻止它。 |
| `VPhone-<version>.zip` | `VPhone.bundle`。Launchpad 会替你下载并安装，因此不需要这个文件。 |

要打开未经公证的版本，先打开一次，然后前往**系统设置 > 隐私与安全性**，点击**仍要打开**。

## 已公证的 Launchpad 版本

| 系列 | 已公证 | 未公证 |
| --- | --- | --- |
| 2.17 | 2.17.0 | — |
| 2.16 | — | 2.16.0, 2.16.1 |
| 2.15 | 2.15.0 | 2.15.1, 2.15.2 |
| 2.14 | 2.14.0 | 2.14.1, 2.14.2 |
| 2.13 | 2.13.0 | 2.13.1, 2.13.2, 2.13.3, 2.13.4, 2.13.5, 2.13.6, 2.13.7, 2.13.8 |
| 2.12 | 2.12.0, 2.12.2 | 2.12.1 |
| 2.11 | 2.11.0 | — |
| 2.10 | 2.10.1 | — |
| 2.9 | 2.9.0, 2.9.1, 2.9.2 | 2.9.3, 2.9.4, 2.9.5 |
| 2.8 | 2.8.0 | — |
| 2.7 | 2.7.0 | — |
| 2.6 | 2.6.0 | 2.6.1 |
| 2.5 | 2.5.0 | 2.5.1 |
| 2.4 | 2.4.0, 2.4.1 | 2.4.2 |
| 2.3 | 2.3.0 | 2.3.1, 2.3.2 |
| 2.2 | 2.2.0, 2.2.2, 2.2.3, 2.2.4, 2.2.5 | 2.2.1 |
| 2.1 | 2.1.0, 2.1.1, 2.1.2 | 2.1.3, 2.1.4, 2.1.5, 2.1.6, 2.1.7 |
| 2.0 | 2.0.4, 2.0.5, 2.0.6, 2.0.8, 2.0.9 | — |

没有 2.0.7 和 2.10.0 版本。

## 匹配 Launchpad 与 VPhone.bundle

请使用与 Launchpad 同一系列的 `VPhone.bundle`。系列是版本号的前两个数字：Launchpad 2.2.3 属于 2.2 系列，可以与任何 `VPhone.bundle` 2.2.x 配合使用。

| Launchpad | VPhone.bundle |
| --- | --- |
| 2.17.x | 2.17.x |
| 2.16.x | 2.16.x |
| 2.15.x | 2.15.x |
| 2.14.x | 2.14.x |
| 2.13.x | 2.13.x |
| 2.12.x | 2.12.x |
| 2.11.x | 2.11.x |
| 2.10.x | 2.10.x |
| 2.9.x | 2.9.x |
| 2.8.x | 2.8.x |
| 2.7.x | 2.7.x |
| 2.6.x | 2.6.x |
| 2.5.x | 2.5.x |
| 2.4.x | 2.4.x |
| 2.3.x | 2.3.x |
| 2.2.x | 2.2.x |
| 2.1.x | 2.1.x |
| 2.0.x | 2.0.x |

在同一系列中，请安装最新的 `VPhone.bundle`。补丁版本只修复问题，不会改变 Launchpad 与 bundle 的配合方式。

Launchpad 会拒绝对它来说过旧的 `VPhone.bundle`，但仍可能列出更新系列的 bundle。不要安装这些 bundle；请先把 Launchpad 更新到该系列。

> [!NOTE]
> Launchpad 不会自动更新。请从版本页面下载新版本，替换旧的 App。

## 近期系列新增的内容

| 系列 | 新增 | 说明 |
| --- | --- | --- |
| 2.15 | HomeView | 请将 Launchpad 2.15 与同系列的 bundle 搭配使用，这样 New Machine 会为 `HomeAccessory17,1` 和 `HomeAccessory17,2` 选择 `homeview` 预设。 |
| 2.14 | 从文件载入补丁预设：预设选择器中的 **Other…**，或 `--preset <path>` | Launchpad 2.14 需要 2.14 的 bundle。 |
| 2.13 | Apple TV 4K（第 4 代） | 请将 Launchpad 2.13 与同系列的 bundle 搭配使用，这样 New Machine 会为 `AppleTV18,1` 选择 `tvos-4k` 预设。 |

## 1.x 版本

1.x 创建的虚拟机无法在 2.x 中启动。1.x 请参阅 [1.0.14 版本](https://github.com/Lakr233/vphone-cli/releases/tag/1.0.14)。

## 另请参阅

- [快速开始](quick-start.md)
- [Core Bundle](../launchpad/core-bundles.md)
- [Launchpad 命令行](../launchpad/launchpad-cli.md)
