# 其他 iPhone 机型

如何运行一个 iOS 来自其他 iPhone 恢复 IPSW、而非 iPhone17,3（iPhone 16）的客户机。需要特定机型的用户空间、面板尺寸或身份时，请参阅本页。

与 [iPad 客户机](ipados.md)一样，虚拟硬件保持不变：启动链、内核、SEP 和设备树仍来自 PCC cloudOS IPSW（`vresearch101ap` / `vphone600ap`）。只有用户空间来自所选机型的 IPSW，客户机启动所用的设备树也会被改写，以呈现为该机型。

## 创建

在 Launchpad 中，选择 **New Machine**（新建虚拟机），在 **Device**（设备）下选择机型，在 **iOS** 下选择版本。

在终端中通过 Launchpad 创建：

```sh
vphone-launchpad-cli vm create iphone17pro --device iPhone18,1
```

使用 `vphone-cli` 时，传入该机型的 IPSW 和 cloudOS：

```sh
vphone-cli vm create iphone17pro \
  --iphone-source 'https://updates.cdn-apple.com/2026SummerFCS/f768ecdf-e037-44e6-bfa6-949b6d127c4f/iPhone18,1_26.6.2_23G90_Restore.ipsw' \
  --cloudos-source 'https://updates.cdn-apple.com/private-cloud-compute/c0ecdb4b310cf5239ab2b248dd3098eec297dc5aa3bbe6ada27273262b0b8b64'
```

每款 iPhone 都有自己的 IPSW，因此明确指定来源时不需要 `--device`。

要查找版本，请运行 `fw catalog`。它会列出 iPhone 13、iPhone 16 和 iPhone 17 系列机型从 26.0 到 27.0.1 的版本（iPhone 17e 从 26.3.1 起），以及 iPhone 18 Pro 的 27.0.1，每个版本都附有同版本 iPhone17,3 所用的 cloudOS。只列出一款机型的版本：

```sh
vphone-cli fw catalog --device iPhone18,1
```

## 支持的设备

| 产品 | 机型 | 主板 | 面板 | 点数 @3x |
| --- | --- | --- | --- | --- |
| `iPhone14,5` | iPhone 13 | D17AP | 1170x2532 @ 460 ppi | 390x844 |
| `iPhone17,3` | iPhone 16 | D47AP | 1179x2556 @ 460 ppi | 393x852 |
| `iPhone17,4` | iPhone 16 Plus | D48AP | 1290x2796 @ 460 ppi | 430x932 |
| `iPhone17,1` | iPhone 16 Pro | D93AP | 1206x2622 @ 460 ppi | 402x874 |
| `iPhone17,2` | iPhone 16 Pro Max | D94AP | 1320x2868 @ 460 ppi | 440x956 |
| `iPhone17,5` | iPhone 16e | V59AP | 1170x2532 @ 460 ppi | 390x844 |
| `iPhone18,3` | iPhone 17 | V57AP | 1206x2622 @ 460 ppi | 402x874 |
| `iPhone18,4` | iPhone Air | D23AP | 1260x2736 @ 460 ppi | 420x912 |
| `iPhone18,1` | iPhone 17 Pro | V53AP | 1206x2622 @ 460 ppi | 402x874 |
| `iPhone18,2` | iPhone 17 Pro Max | V54AP | 1320x2868 @ 460 ppi | 440x956 |
| `iPhone18,5` | iPhone 17e | V159AP | 1170x2532 @ 460 ppi | 390x844 |
| `iPhone19,2` | iPhone 18 Pro | V63AP | 1206x2622 @ 460 ppi | 402x874 |

每款机型（包括 iPhone17,3）的面板和身份都来自它自己的设备树。新建的 iPhone17,3 机器使用 iPhone 16 自己的 1179x2556 面板；用更早的 VPhone.bundle 创建的机器保留其配置中记录的 1290x2796 面板。

iPhone 17 Pro、17 Pro Max 和 18 Pro 有启动验证记录；见[兼容性](compatibility.md)。iPhone 17 Pro 和 17 Pro Max 在 iOS 27 上需要一个补丁，详见该页。

> [!WARNING]
> iPhone19,2 使用 ARM64E_X1。在不原生支持 X1 的宿主机上，standard 预设会把不支持的指令降级处理，这会削弱与 PC 绑定的指针认证。

## 其他 iPhone 有哪些不同

[iPad 有哪些不同](ipados.md)中列出的内容全部适用，但有两点区别：

- 主板的 `/product` 值同样会替换 vphone600 的占位值，但 iPhone 主板保留手机特有的属性：灵动岛、便捷访问、OLED、音量按钮布局、CarPlay 和 Apple Watch 配对都取自主板，而不会被移除。补丁 ID 仍是 `devicetree-cfw-ipad_*`；它们是在 iPhone 使用之前命名的。
- 不会为显示缩放比例给 LLB 打补丁。半虚拟化显示器的启动视频字表示 3x，这本来就是 iPhone 的缩放比例。

## 另请参阅

- [iPadOS 客户机](ipados.md)
- [固件兼容性](compatibility.md)
- [创建与运行虚拟机](../machines/create-and-run.md)
