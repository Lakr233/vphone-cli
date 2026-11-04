# iPadOS 客户机

如何在 vphone 虚拟机中运行 iPadOS 而非 iOS。需要 iPad 的用户空间、屏幕尺寸或多任务处理功能时，请参阅本页。

虚拟硬件不变：启动链、内核、SEP 和设备树仍来自 PCC cloudOS IPSW（`vresearch101ap` / `vphone600ap`）。只有用户空间改为来自 iPad 的恢复 IPSW，而非 iPhone17,3 的；设备树也会被改写，让用户空间认为自己运行在 iPad 上。

![在 vphone 虚拟机中运行的 iPadOS 主屏幕](../../ipados-demo.jpeg)

## 创建 iPad 客户机

### 在 Launchpad 中

1. 选择 **New Machine**（新建虚拟机）。
2. 在 **Device**（设备）下选择 iPad，在 **iPadOS** 下选择版本。推荐的 cloudOS 会一并选好。
3. 如果 IPSW 不在目录中，请把 **Source**（来源）设为 **Custom IPSWs**（自定义 IPSW），把 iPad IPSW 填入 **iPhone IPSW** 栏，把 cloudOS IPSW 填入另一栏。

只有当 Core Bundle 的目录中列出了 iPad 时，才会出现 **Device** 菜单。在终端中，`vphone-launchpad-cli vm create <name> --device iPad16,1` 可以完成同样的操作。

### 使用 vphone-cli

在原本填 iPhone 恢复 IPSW 的地方传入 iPad 的恢复 IPSW。cloudOS 与同版本的 iPhone 客户机所用的相同。

```sh
vphone-cli vm create ipad-mini \
  --iphone-source 'https://updates.cdn-apple.com/2026SummerFCS/cf7db64d-5866-4bf2-bfff-50a32f58bec3/iPad16,1,iPad16,2_26.6.2_23G90_Restore.ipsw' \
  --cloudos-source 'https://updates.cdn-apple.com/private-cloud-compute/c0ecdb4b310cf5239ab2b248dd3098eec297dc5aa3bbe6ada27273262b0b8b64'

# The 13-inch iPad Pro (M5), from the IPSW that also carries the 11-inch
vphone-cli vm create ipad-pro-13 --device iPad17,3 \
  --iphone-source 'https://updates.cdn-apple.com/2026SummerFCS/<…>/iPad17,1,iPad17,2,iPad17,3,iPad17,4_26.6.2_23G90_Restore.ipsw' \
  --cloudos-source 'https://updates.cdn-apple.com/private-cloud-compute/c0ecdb4b310cf5239ab2b248dd3098eec297dc5aa3bbe6ada27273262b0b8b64'
```

查找版本：

| 命令 | 列出的内容 |
| --- | --- |
| `vphone-cli fw catalog` | 每款受支持 iPad 的 iPadOS 版本，以及各自对应的 cloudOS |
| `vphone-cli fw catalog --device iPad16,1` | 一款 iPad 的版本 |
| `vphone-cli fw prepare --device iPad16,1 --list` | 该 iPad 可下载的 IPSW |
| `vphone-cli fw prepare --device iPad16,1 --iphone-version 26.6.2` | 解析出一个 IPSW |

指定 `--device` 但不提供来源时，`vm create` 会列出该 iPad 的版本供你选择。

### 在共用的 IPSW 中选择机型

大多数 iPad IPSW 覆盖多个机型；iPad Air 和 iPad Pro 的 IPSW 同时包含两种尺寸。不指定 `--device` 时，`fw prepare` 会使用 IPSW 列出的第一个机型（11 英寸）。要使用 13 英寸机型，请给 `fw prepare` 或 `vm create` 传入 `--device iPad17,3`。Launchpad 的 New Machine 会传入在 **Device** 下选择的机型；选择 **Custom IPSWs** 时则使用第一个机型。

<img src="../../ipados/ipad-pro-13-home.jpg" alt="在 vphone 虚拟机中运行的 13 英寸 iPad Pro 主屏幕" width="360" />

### 手动运行各个阶段

手动阶段与 iPhone 客户机相同：`vm new`、`fw prepare`、`fw patch`、DFU 和 `restore`、`cfw install`、`vm launch`。对 iPad 而言，只有 `fw prepare` 和 `fw patch` 的行为不同；DFU、`restore` 和 `cfw install` 照常运行。

## 支持的设备

| 产品 | 机型 | 主板 | 面板 | 点数 @2x |
| --- | --- | --- | --- | --- |
| `iPad16,1` | iPad mini (A17 Pro) | J410AP | 1488x2266 @ 326 ppi | 744x1133 |
| `iPad15,7` | iPad (A16) | J481AP | 1640x2360 @ 264 ppi | 820x1180 |
| `iPad15,3` | iPad Air 11 英寸 (M3) | J607AP | 1640x2360 @ 264 ppi | 820x1180 |
| `iPad15,5` | iPad Air 13 英寸 (M3) | J637AP | 2048x2732 @ 264 ppi | 1024x1366 |
| `iPad16,3` | iPad Pro 11 英寸 (M4) | J717AP | 1668x2420 @ 264 ppi | 834x1210 |
| `iPad16,5` | iPad Pro 13 英寸 (M4) | J720AP | 2064x2752 @ 264 ppi | 1032x1376 |
| `iPad17,1` | iPad Pro 11 英寸 (M5) | J817AP | 1668x2420 @ 264 ppi | 834x1210 |
| `iPad17,3` | iPad Pro 13 英寸 (M5) | J820AP | 2064x2752 @ 264 ppi | 1032x1376 |

蜂窝网络机型（`iPad16,2`、`iPad15,4`、`iPad15,6`、`iPad16,4`、`iPad16,6`、`iPad17,2`、`iPad17,4`）与对应的无线局域网机型共用 IPSW，并以该机型运行：虚拟机没有基带。`iPad15,8` 使用单独的 IPSW，其中不含无线局域网机型的主板，因此不受支持。

已测试的组合见[兼容性](compatibility.md)。

## iPad 有哪些不同

- **`fw prepare`** 根据 `SupportedProductTypes` 识别 IPSW，为客户机的主板选取对应的抹掉身份和 `DeviceMap` 条目（一个 iPad IPSW 覆盖多款主板），并把产品类型和 iPad 的显示参数记录到虚拟机的 `config.plist` 中（`guestProductType`、`screenConfig`）。恢复目录命名为 `iPhoneOS_iPad16,1_<version>_<build>_Restore`；`iPhone` 前缀是所有读取方都依赖的恢复目录命名约定，与设备无关。
- **两份设备树。** 混合清单通常让 `DeviceTree` 和 `RestoreDeviceTree` 指向同一个 vphone600 文件。对 iPad，`DeviceTree` 指向一份副本 `Firmware/all_flash/DeviceTree.vphone600ap.guest.im4p`。恢复时启动的是未修改的身份，`restored_external` 会将其与清单（`iPhone99,11`）核对；客户机启动的则是副本。
- **`fw patch`** 为这份副本赋予 iPad 的身份和呈现方式（补丁集 `devicetree`，条目 `devicetree-cfw-ipad_*`）：
  - 根节点的 `model`、`target-type` 和 `target-sub-type` 与主板一致（iPad mini 为 `iPad16,1`、`J410`、`J410AP`），`compatible` 把主板放在第一位，`VPHONE600AP` 保留在第二位；
  - `/product`：主板的图稿风格（idiom）、子类型和缩放比例、产品名称、外观、摄像头和按键布局、多任务处理能力（`medusa-overlay-app-capability`、`ui-floating-live-app`、`ui-overlay-app`、`ui-pinned-app`，以及在没有台前调度的主板上设置 `disable-chamois`），还有产品类型和唯一机型，全部读取自恢复目录中保留的主板 `DeviceTree.<board>.im4p`；
  - 移除仅适用于手机的 `syscfg` 占位项（灵动岛、便捷访问、响铃开关、音量按钮布局、CarPlay、Apple Watch 配对）。

  虚拟硬件保留 vphone600 的描述：GPU 功能集、帧缓冲区、内存等级和启动标志。
- **LLB** 在 iPad 客户机上多一个补丁 `llb-cfw-display_scale`。LLB 会根据半虚拟化显示器的启动视频字填写 `/chosen/display-scale`，而该值始终表示 3x；MobileGestalt 会把这个属性转换为屏幕缩放比例，因此 iPad 会得到一块 496x755 点的画布。该补丁让 LLB 写入 iPad 自己的缩放比例（2x，iPad mini 为 744x1133 点）。
- **`cfw install`** 不改动已安装的设备树。iPad 客户机会跳过 iPhone17,3 恢复后的身份改写（`preboot-exp-devicetree_identity`）。
- **虚拟机窗口**遵循 `screenConfig`，因此会按 iPad 的宽高比打开。

<img src="../../ipados/display-scale-3x-before.jpg" alt="打 LLB 补丁之前，以 3x 显示缩放比例运行的 iPad 客户机" width="240" />

## 添加其他 iPad

添加一款 iPad 机型只需在 [`VPhoneGuestDevice`](../../../VPhoneKit/VPhoneCoreKit/VirtualMachine/VPhoneGuestDevice.swift) 中加一行：它的产品类型、主板和面板。设备树需要的其他内容都读取自 IPSW 中该主板自己的 `DeviceTree.<board>.im4p`。

## 另请参阅

- [其他 iPhone 机型](iphone-models.md)
- [固件兼容性](compatibility.md)
- [创建与运行虚拟机](../machines/create-and-run.md)
