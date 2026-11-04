# 启动 ROM

选择虚拟机从哪个启动 ROM 和 SEP 启动 ROM 启动。本页介绍如何查看虚拟机使用的 ROM，以及如何在开源 ROM 与 Apple 的 ROM 之间切换。

## 查看与切换

```sh
vphone-cli vm info myphone                                    # shows rom and seprom
vphone-cli vm config myphone --rom openavb --seprom opensep   # open-source ROMs
vphone-cli vm config myphone --rom apple --seprom apple       # Apple's ROMs
```

切换在虚拟机下次启动时生效，不需要重新恢复系统，两个方向都可以切换。

| 选项 | 值 | ROM |
| --- | --- | --- |
| `--rom` | `openavb` | bundle 中的 OpenAVB |
| `--rom` | `apple` | Virtualization.framework 的 AVPBooter（如果虚拟机有自己打过补丁的副本，则使用该副本） |
| `--rom` | 文件路径 | 任何其他启动 ROM |
| `--seprom` | `opensep` | bundle 中的 OpenSEP |
| `--seprom` | `apple` | Virtualization.framework 的 AVPSEPBooter |
| `--seprom` | 文件路径 | 任何其他 SEP 启动 ROM |

两种启动 ROM 载入的是同一个打过补丁的 LLB，两种 SEP ROM 载入的都是恢复时安装的 SEP 固件，因此不需要重新恢复。

> [!NOTE]
> 恢复使用 OpenAVB 启动的虚拟机，需要 `VPhone.bundle` 2.10.1 或更新版本。

## 虚拟机使用哪些 ROM

新建的虚拟机不使用 Virtualization.framework 中的闭源 ROM，而是从两个开源 ROM 启动：

- [OpenAVB](https://github.com/owngoal-dev/OpenAVB) 替代启动 ROM AVPBooter。它不需要打补丁，因此 `fw patch` 不会改动它。
- [OpenSEP](https://github.com/owngoal-dev/OpenSEP) 替代 SEP 启动 ROM AVPSEPBooter。

两者同时使用时，iBoot 和 SEPOS 之前不会运行任何由 Apple 编写的代码。旧版本创建的虚拟机会继续使用 Apple 的 ROM，直到你切换为止。

## ROM 的来源

两者都以预编译形式随 `VPhone.bundle` 发布，由固定的上游提交构建。各自的 README 说明了如何重新构建并逐字节核对：

- [OpenAVB README](../../../VPhoneExecutable/VPhoneVirtualization/Resources/OpenAVB/README.md)
- [OpenSEP README](../../../VPhoneExecutable/VPhoneVirtualization/Resources/OpenSEP/README.md)

详细内容见研究记录中的 [OpenAVB](../../../Research/Firmware/openavb_boot_rom.md) 和 [OpenSEP](../../../Research/Firmware/opensep_sep_rom.md)。

## 另请参阅

- [创建与运行虚拟机](create-and-run.md)
- [固件准备](../firmware/firmware-preparation.md)
- [故障排查](../help/troubleshooting.md)
