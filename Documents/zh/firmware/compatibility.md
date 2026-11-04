# 固件兼容性

哪些客户机固件与 cloudOS 的组合已知可以在哪些宿主机上启动。为新虚拟机选择版本之前，或者创建失败、想知道该组合是否测试过时，请查看本页。

要查看当前目录在你的 Mac 上提供哪些版本，请运行：

```sh
vphone-cli fw catalog
```

> [!NOTE]
> 从 v2.0.0 开始，vphone 只启动 `config.plist` 中 `schemaVersion=2` 的虚拟机。旧版本创建的虚拟机请用 `vm create` 重新创建；不支持原地升级。下面的结果描述的是已测试的组合，而非与旧虚拟机 bundle 的兼容性。

## 已测试的环境

以下是用原生 JB 流程完整跑通的 iPhone17,3 组合。两行 PR #486（[PR #486](https://github.com/Lakr233/vphone-cli/pull/486)）进入了锁定屏幕并响应了 vphoned ping；另外一次全新的 26.6.2 `vm create` 也完成了所有阶段，并在首次启动 ping 后成功退出。

| 验证来源 | iPhone 恢复 IPSW | PCC/cloudOS IPSW | 观察结果 |
| --- | --- | --- | --- |
| PR #486 | `17,3_26.6.2_23G90` | `26.4-23E5207q` | JB 补丁、恢复、CFW、启动、vphoned ping |
| PR #486 | `17,3_27.0_24A435` | `26.4-23E5207q` | JB 补丁、恢复、CFW、启动、vphoned ping |
| 研究主板 | `17,3_26.6_23G71` | `26.6-23G71` | 从 CLI 使用 standard 和 Minimal 预设，从 Launchpad 使用 standard 预设（2026-10-20）：转换设备树和 SEP、kernelcache 组合、恢复、CFW、启动、vphoned ping |
| 研究主板 | `17,3_26.5_23F77` | `26.5-23F75` | 从 CLI 使用 standard 预设（2026-10-20）：GPU 驱动取自临时 cloudOS 恢复、kernelcache 组合、恢复、CFW、启动、vphoned ping |
| 研究主板 | `17,3_26.4_23E246` | `26.4-23E244` | 从 CLI 使用 standard 预设（2026-10-20）：GPU 驱动取自临时 cloudOS 恢复、kernelcache 组合、恢复、CFW、启动、vphoned ping |
| 研究主板 | `Watch7,18_26.4_23T240` | `26.4-23E244` | 从 CLI 和 Launchpad 使用 `watchos` 预设（2026-10-20）：手表 kernelcache 组合、恢复、启动、vphoned ping |
| 研究主板 | `11,6_18.7.2_22H124` | `18.7.2-22H43` | 从 CLI 使用 Minimal 预设（2026-10-21）：GPU 驱动取自临时 cloudOS 恢复，iOS 18 kernelcache 组合通过 ssh 由 macOS 15.6.1 的 kmutil 链接、恢复、启动、vphoned ping；已检查屏幕、锁定屏幕、解锁和主屏幕手势 |
| 研究主板 | `11,6_18.1_22B83` | `18.1-22B83` | 从 CLI 使用 Minimal 预设（2026-10-21）：GPU 驱动取自临时 cloudOS 恢复，kernelcache 组合通过 ssh 由 macOS 15.6.1 的 kmutil 链接、恢复、启动、vphoned；已检查“你好”屏幕、锁定屏幕、解锁和主屏幕手势 |
| 研究主板 | `11,6_18.5_22F76` | `18.5-22F76` | 从 CLI 使用 Minimal 预设（2026-10-21）：GPU 驱动取自临时 cloudOS 恢复，kernelcache 组合通过 ssh 由 macOS 15.6.1 的 kmutil 链接、恢复、启动、vphoned；已检查锁定屏幕、解锁和主屏幕手势 |
| 研究主板 | `11,6_18.6_22G86` | `18.6-22G86` | 从 Launchpad 的 CLI 使用 standard 预设（2026-10-24）：kernelcache 组合（缓存）、恢复、CFW、启动、vphoned、“你好”屏幕；在允许两个 Frida 补丁的情况下，Frida 17.24.3 的 attach、spawn、Interceptor 和 Stalker 均可用 |

### 使用哪个 cloudOS

除非有特别的理由，请使用 cloudOS 26.4 beta（`26.4-23E5207q`）。它是包含 `vphone600ap` 的最新 cloudOS，客户机的内核、SEP 和设备树都来自这一身份，而且除了 `vphone-cli` 之外不需要任何其他东西。

之后的所有 cloudOS（2026-10-03 核查）都只列出 PCC 主板和 `vresearch101ap`：`SupportedProductTypes` 中已没有 `iPhone99,11`，也没有 `kernelcache.*.vphone600`、`sep-firmware.vphone600` 或 `DeviceTree.vphone600ap`。在这类 cloudOS 上由研究主板代替（Research Board 补丁集）：

- `fw patch` 把研究主板的设备树和 SEP 转换为 vphone600 的版本，并按照该 kernelcache 的配方，用 vphone600 的虚拟化 kext 重新构建它的 kernelcache。
- KDK 提取在本机原生完成；只有链接需要 root 权限（`vphone-cli fw kernelcache`）。见 [kernelcache 配方](../../../VPhoneExecutable/VPhoneVirtualization/Resources/kernelcache_recipes/README.md)和[固件准备](firmware-preparation.md)。
- 没有配方覆盖的 cloudOS 会被 `fw prepare` 拒绝。
- `fw catalog` 会在推荐的 cloudOS 旁列出每个 iOS 版本自己的 cloudOS，Launchpad 在 **Firmware**（固件）下提供它。

| cloudOS | `vresearch101ap` | `vphone600ap` | kernelcache 配方 |
| --- | --- | --- | --- |
| `26.4-23E5207q` (beta) | 有 | 有 | 不需要 |
| `26.4-23E244` | 有 | 无 | 有 |
| `26.4.1-23E254` | 有 | 无 | 无 |
| `26.5-23F75` | 有 | 无 | 有 |
| `26.5.2-23F83` | 有 | 无 | 无 |
| `26.6-23G71` | 有 | 无 | 有 |
| `26.6.1-23G82` | 有 | 无 | 无 |
| `26.7-23H20` | 有 | 无 | 有 |

其他 iPhone 和 iPad 版本或许可以与 `26.4-23E5207q` 配合使用，但尚未通过同样的完整检查。

### iOS 18 客户机

iOS 18.1 到 18.7.2 运行在各自版本的 cloudOS 上，用户空间来自 iPhone XS 系列的 IPSW：

- 用 `vm create --device iPhone11,6` 创建。默认使用 Minimal 预设；`--preset standard` 已在 18.6 上验证。
- `fw catalog --device iPhone11,6` 会列出这些版本。
- 它们的内核是 kernel-first 布局。从 macOS 26.4 起，需要由另一台运行 macOS 15 或 26.0 到 26.3 的 Mac 或 macOS 虚拟机通过 ssh 链接组合（`VPHONE_KMUTIL_SSH`；见[固件准备](firmware-preparation.md)）。
- Launchpad 以 iPhone XS Max 的名义提供它们，并以那台 Mac 作为 macOS 构建机。

18.1、18.5 和 18.7.2 已在虚拟机上验证；其他四个配方尚未启动过。

### iOS 27.0.1 上的 iPhone17,3

iOS 27.0.1（24A446）在 bundle 2.5.0 及更早版本上首次启动失败（2026-10-04 复现，使用未修改的 Apple launchd 也一样）：TXM 的 selector-24 预检查在 init 阶段拒绝所有二进制文件，启动时以 `unexpected SIGKILL of init` panic。旧的 `txm-boot-precheck_admission` 补丁修复了这个问题（见[研究记录](../../../Research/Firmware/txm_selector24_cms_gate.md)）。打上补丁后，`26.4-23E5207q` 上的 iPhone17,3 27.0.1 可以启动到客户机，并响应 vphoned 的 `device.info`（当天验证）。bundle 2.6.0 是第一个包含该补丁的版本。

本次改动用 `txm-cfw-executable_remap` 替代原来强制归为 type 10 的准入方式，`standard` 预设默认选中该补丁，不受操作系统版本限制。宿主机测试覆盖了原先的签名拒绝路径。在 iOS 27.1（24A94425）上，测试者反馈启动和 App 加载正常；运行时探针的主程序和 framework 原始代码 remap 执行测试共 28 项，全部通过，实际映射权限均为 RX。此前出现问题的 iOS 27.0.1 完整组合尚未复测。见[替换方案评估](../../../Research/Firmware/txm_executable_remap.md)。

## macOS 26.6.2 宿主机

于 2026-10-23 使用 Core Bundle 2.12.1 验证，2026-10-24 又使用 Core Bundle 2.12.2 再次验证，宿主机为 Mac mini M4（Mac16,10，16 GB，macOS 26.6.2 25G83）。每台虚拟机都从零开始通过 CLI 创建。研究主板组合以普通用户身份准备 kernelcache 组合，用 sudo 链接，然后运行 `sudo vphone-cli vm create`。“默认”表示 `fw catalog` 在这台 Mac 上为该设备给出的最新组合，也就是 Launchpad 的 New Machine 会选择的组合。之后每台虚拟机都以无界面方式启动两次：vphoned 有响应，`device.info` 报告了正确的版本，客户机的串口日志中没有 panic。

| 客户机 | 固件 | cloudOS | 结果 |
| --- | --- | --- | --- |
| iPhone17,3 | iOS 27.0.1（默认） | `26.4-23E5207q` | 构建模板、克隆、两次启动 |
| iPhone18,2 | iOS 27.0.1（默认） | `26.4-23E5207q` | 构建模板、克隆、两次启动 |
| iPad16,1 | iPadOS 27.0.1（默认） | `26.4-23E5207q` | 构建模板、克隆、两次启动 |
| iPhone17,3 | iOS 26.6.2 | `26.4-23E5207q` | 构建模板、克隆、两次启动 |
| iPhone17,3 | iOS 26.6.2 | `26.6-23G71` | 研究主板：原生 KDK 提取，macOS 26 链接后无残留 auth stub，28 个 kernelcache 补丁，两次启动 |
| iPhone17,3 | iOS 26.5 | `26.5-23F75` | 研究主板，同上 |
| iPhone17,3 | iOS 26.4 | `26.4-23E244` | 研究主板，同上 |
| iPhone17,3 | iOS 18.6.2 | `26.1-23B85` | 构建模板、克隆、两次启动 |
| iPhone11,6 | iOS 18.7.2（默认） | `18.7.2-22H43` | Minimal，组合通过 ssh 由 macOS 15.7.7 虚拟机的 kmutil 链接，两次启动 |
| iPhone11,6 | iOS 18.6 | `18.6-22G86` | 同上：该配方的首次启动 |
| iPhone11,6 | iOS 18.7 | `18.7-22H20` | 同上：该配方的首次启动 |
| Watch7,18 | watchOS 26.4（默认） | `26.4-23E244` | `watchos` 预设，手表 kernelcache 组合，两次启动 |
| AppleTV5,3 | tvOS 26.6（默认） | `26.4-23E5207q` | `tvos` 预设，两次启动 |
| AppleTV14,1 | tvOS 26.6（macOS 26 上的默认） | `26.4-23E5207q` | `tvos-4k` 预设，26.6 OTA 用户空间，两次启动 |
| AudioAccessory5,1 | HomePod 软件 27.0（macOS 26 上的默认） | `26.4-23E5207q` | `homepod-mini` 预设，两次启动 |
| AppleTV14,1 | tvOS 27.0 | — | 下载前即被拒绝：需要 macOS 27 |
| AudioAccessory5,1 | HomePod 软件 27.2 | — | 下载前即被拒绝：需要 macOS 27 |

tvOS 27.0（24J361）和 HomePod 软件 27.2（24K120）的 OTA 使用 LZRAVEN 压缩负载，只有 macOS 27 能够解压。在较旧的 Mac 上，`fw catalog` 不会列出它们，因此 Launchpad 为这些设备提供的默认版本是 tvOS 26.6 和 HomePod 软件 27.0；如果指定其中任何一个，会在下载任何内容之前被拒绝。

Apple TV 4K（第 4 代），即 `AppleTV18,1` / `J265AP`，目前仅供早期适配，使用 tvOS 27.2 beta（`24K120`）：它的完整 OTA 叠加在 Apple TV HD 26.6 恢复基础和 cloudOS 26.4 beta（`23E5207q`）之上。它需要 macOS 27 和 `tvos-4k` 预设。2026-10-24，一台虚拟机完成了恢复和自定义固件安装，并两次冷启动到 vphoned 和旧版 TVSetup 的 4K 语言屏幕；设置本身没有完成。它不在上面的测试表中。见[适配记录](../../../Research/Firmware/tvos_support.md#apple-tv-4k-4th-generation)。

cloudOS 26.7（23H20）没有可以搭配的 iPhone 版本。使用 iOS 26.6.2 的用户空间准备时，它的组合可以链接，28 个 kernelcache 补丁也都能应用，但 CFW 补丁 `_vm_fault_enter_prepare` 在该内核中找不到补丁位置。它尚未启动过。

> [!TIP]
> `vphone-escalator` 把允许列表保存在 amfid 的内存中，因此 amfid 重启时允许列表会丢失；这些宿主机在测试中途就发生过一次。AMFI 拒绝 bundle 时，Launchpad 会重新允许它。使用 CLI 时，请再次运行 `host preflight` 打印的 `vphone-escalator allow` 命令。

## 其他 iPhone 机型

iPhone17,3 以外的机型见[其他 iPhone 机型](iphone-models.md)。

| 宿主机 | iPhone 恢复 IPSW | PCC/cloudOS IPSW | 观察结果 |
| --- | --- | --- | --- |
| Mac17,9 (M5 Pro) 27.0.1 | `18,1_26.6.2_23G90` (iPhone 17 Pro) | `26.4-23E5207q` | Launchpad `vm create`（2.5.1 本地 bundle）：准备、补丁、恢复、CFW、启动到主屏幕，402x874 pt @3x，`model` 为 iPhone18,1，vphoned ping |
| Mac17,9 (M5 Pro) 27.0.1 | `18,2_27.0.1_24A446` (iPhone 17 Pro Max) | `26.4-23E5207q` | 打上 `kernel-boot-shared_region_size` 补丁后**可以启动**（2026-10-06，bundle 2.6.0-local.0d5e6f90）：`dyld cache mapped system-wide`，0 次 panic，vphoned 报告版本为 27.0.1，主屏幕为 440x956 pt @3x |
| Mac17,7 (M5 Max) 26.4 | `19,2_27.0.1_24A446` (iPhone 18 Pro) | `26.4-23E5207q` | 集成 ARM64E_X1 兼容后**可以启动**（2026-10-17）：离线恢复无错误，根卷封印验证通过，vphoned ping，“设置”、Safari 浏览器和“计算器”均可打开 |

### iOS 27 上的 iPhone18,1 和 iPhone18,2

这两款需要 `kernel-boot-shared_region_size` 补丁（[issue #596](https://github.com/Lakr233/vphone-cli/issues/596)，27.0 和 27.0.1）。自 2026-10-06 起，`standard` 预设在 iOS 27 基础系统上默认开启它。

它们在 27.0.1 上的 dyld 共享缓存记录的 `sharedRegionSize` 为 `0x185804000`，大于 cloudOS 26.4 客户机内核的 `0x180000000` 共享区域，因此即使 `dyld-boot-maxslide` 取消了滑动，缓存也无法映射。没有这个补丁时，launchd 会在首次启动时以 `Library not loaded: /usr/lib/libSystem.B.dylib` panic。iPhone17,3 的 27.0.1 缓存（`0x17D508000`）仍然放得下。

该补丁把 arm64 区域扩大到 `0x1C0000000`，这是不超过 26.4 内核自身任务映射上限的最大值。当虚拟机的内核带有该补丁时（其 `PatchReceipt.plist` 中会注明），`cfw install` 会按扩大后的区域衡量缓存，因此这些设备可以安装和启动；这已在上文的 iPhone18,2 27.0.1 上验证。

没有该补丁时（bundle 较旧，或取消勾选了该补丁），`cfw install` 会拒绝这样的缓存并给出上述说明，而不是留下一个会 panic 的客户机。iOS 27 请使用 iPhone17,3，这些设备请使用 iOS 26。

## iPadOS

iPad 客户机见 [iPadOS 客户机](ipados.md)。

| 宿主机 | iPad 恢复 IPSW | PCC/cloudOS IPSW | 观察结果 |
| --- | --- | --- | --- |
| Mac17,9 (M5 Pro) 27.0.1 | `iPad16,1,iPad16,2_26.6.2_23G90` | `26.4-23E5207q` | 准备、补丁、恢复、CFW（2.2.5 辅助程序）、启动到 iPadOS 主屏幕，744x1133 pt @2x，`model` 为 iPad16,1，vphoned ping |
| Mac17,9 (M5 Pro) 27.0.1 | `iPad16,1,iPad16,2_27.0.1_24A446` | `26.4-23E5207q` | 从目录用 Launchpad 运行 `vm create --device iPad16,1`（2.4.0 bundle）：准备、补丁、恢复、CFW、启动到 iPadOS 主屏幕，744x1133 pt @2x，`model` 为 iPad16,1，`ios_version` 为 27.0.1，vphoned ping |

## 早期报告的组合

以前的 README 记录了以下宿主机与固件组合。它们早于当前的单一模式流程，或者缺少同等的 vphoned 验收证据，因此请把它们视为研究历史，而不是当前的支持矩阵。

| 宿主机          | iPhone                | CloudOS         |
| --------------- | --------------------- | --------------- |
| Mac16,11 27.0b2 | `17,3_18.6.2_22G100`  | `26.1-23B85`    |
| Mac16,8 26.5.1  | `17,3_26.0_23A341`    | `26.1-23B85`    |
| Mac16,8 26.5.1  | `17,3_26.0.1_23A355`  | `26.1-23B85`    |
| Mac16,12 26.3   | `17,3_26.1_23B85`     | `26.1-23B85`    |
| Mac16,12 26.3   | `17,3_26.3_23D127`    | `26.1-23B85`    |
| Mac16,12 26.3   | `17,3_26.3_23D127`    | `26.3-23D128`   |
| Mac16,12 26.3   | `17,3_26.3.1_23D8133` | `26.3-23D128`   |
| Mac16,11 26.2   | `17,3_26.4_23E246`    | `26.4-23E5207q` |
| Mac16,11 26.2   | `17,3_26.5_23F77`     | `26.4-23E5207q` |
| Mac16,11 27.0b2 | `17,3_26.5.2_23F84`   | `26.4-23E5207q` |
| Mac16,6 26.4.1  | `17,3_26.6_23G71`     | `26.4-23E5207q` |
| Mac16,11 27.0b2 | `17,3_26.6.1_23G83`   | `26.4-23E5207q` |
| Mac16,6 26.6.1  | `17,3_26.6.2_23G90`   | `26.4-23E5207q` |
| Mac16,11 27.0b2 | `17,3_27.0_24A5380h`  | `26.4-23E5207q` |
| Mac16,6 26.4.1  | `17,3_27.0_24A5390f`  | `26.4-23E5207q` |
| Mac16,6 26.6.1  | `17,3_27.0_24A5408d`  | `26.4-23E5207q` |
| Mac16,11 27.0b2 | `17,3_27.0_24A5418b`  | `26.4-23E5207q` |
| Mac16,11 27.0b2 | `17,3_27.0_24A5424a`  | `26.4-23E5207q` |
| Mac16,11 27.0b2 | `17,3_27.0_24A5430a`  | `26.4-23E5207q` |
| Mac16,6 26.6.1  | `17,3_27.0_24A435`    | `26.4-23E5207q` |

全部补丁及各自的适用范围见[补丁清单](../../../Research/0_binary_patch_comparison.md)。

## 另请参阅

- [固件准备](firmware-preparation.md)
- [其他 iPhone 机型](iphone-models.md)
- [iPadOS 客户机](ipados.md)
- [创建与运行虚拟机](../machines/create-and-run.md)
