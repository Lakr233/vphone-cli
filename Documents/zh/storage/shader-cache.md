# 持久着色器缓存

虚拟机会在多次启动之间保留已编译的 GPU 着色器，因此只有在最初几次运行、着色器正在编译时动画才会卡顿。要为现有虚拟机开启缓存或重置缓存，请参阅本页。

使用 Standard 预设新建的虚拟机会自动启用 Task3 内核补丁和客户机 Metal 缓存复用。宿主机把缓存保存在 `<machine>/ShaderCache` 中，例如 `~/.vphone/machines/Lychee/ShaderCache`。可执行文件发生变化时，会获得新的宿主机缓存身份。

## 为现有虚拟机开启

安装包含此功能的 Core Bundle，并把已停止的虚拟机绑定到它。然后更新客户机环境和内核。两项更新都会保留客户机的数据；不需要重新恢复，也不需要 `fw patch`。

### 在 Launchpad 中

1. 在虚拟机的操作菜单中选择 **Update Guest Environment**（更新客户机环境）。
2. 在它的 **Patches**（补丁）检查器中选择 **Update Kernel**（更新内核）。

Standard 现在会自动选择 **GPU Task3 shader cache**。为单台虚拟机明确关闭的设置会被保留；如果之前取消勾选了该补丁，请先在编辑器中启用它。

### 使用 Launchpad CLI

```sh
# Replace <version> with the installed Core Bundle version from bundle list.
vphone-launchpad-cli vm stop Lychee
vphone-launchpad-cli vm set-bundle Lychee <version> --update-environment
vphone-launchpad-cli cfw update-kernel Lychee
vphone-launchpad-cli vm start Lychee --wait
```

- `--update-environment` 重新部署客户机库和缓存复用标记。
- `cfw update-kernel` 按当前的选择重新为 `FirmwareOriginals` 中的原始内核打补丁，并替换 Preboot 中的 kernelcache。

只更改 Core Bundle 绑定不会更新已安装的内核。

### 只用 vphone-cli

在虚拟机关闭时，以 root 授权运行新 bundle 中的命令：

```sh
sudo vphone-cli cfw update-environment Lychee
sudo vphone-cli cfw update-kernel Lychee
```

`vphone-cli fw patches Lychee` 会显示待应用的补丁。两条更新命令都会应用虚拟机当前的选择，包括其他待应用的客户机或内核更改。

### 没有原始内核的旧虚拟机

如果虚拟机的 `FirmwareOriginals` 中没有原始内核，需要先用新 bundle 运行 `fw prepare` 和 `fw patch`，让备用恢复目录包含更新后的内核。然后运行 `cfw update-kernel`。不要运行 `restore`。

## 重置宿主机缓存

停止虚拟机，然后删除它的 `ShaderCache` 目录。下次启动时会使用全新的宿主机缓存。

客户机的 Metal 缓存是 `Disk.img` 中的独立文件，因此清除宿主机缓存不一定能重现首次运行时的全部卡顿。

## 限制

- Task3 只适用于 cloudOS 26.4 内核，在 tvOS 预设中处于停用状态。
- 在早于 macOS 27 的宿主机上，客户机会协商使用宿主机自身支持的最高版本并保留该版本的功能，因此在这类宿主机上，宿主机缓存仅在单次启动内有效。
- 运行时验证覆盖了 macOS 27.0.1、cloudOS 26.4，以及 iOS 27.0.1 和 26.6.2 客户机。较旧的宿主机只检查了其框架代码，未实际运行。

## 另请参阅

- [Core Bundle](../launchpad/core-bundles.md)
- [Launchpad CLI](../launchpad/launchpad-cli.md)
- [资料库、固件与备份](library-and-backups.md)
