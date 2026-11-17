# 固件准备

在为固件打补丁之前，`vm create` 和 `fw prepare` 会如何处理两个 IPSW，以及不含 vphone600 组件的 cloudOS 还需要哪些额外步骤。手动运行各个阶段、复用 GPU 驱动，或者用研究主板组合创建虚拟机时，请参阅本页。

## GPU 驱动

`fw prepare` 需要先从 cloudOS 中取得半虚拟化 GPU 驱动，才能构建混合的 iPhone 恢复包。获取方式如下：

1. 创建一台没有网络设备的临时 vphone 虚拟机，并以 DFU 模式启动。
2. 用 vphone 自己的恢复后端把所选的 cloudOS IPSW 恢复到这台虚拟机中。
3. 以只读方式装载恢复后的 System 宗卷，提取 GPU bundle。
4. 删除临时虚拟机。

提取出的 bundle 按 cloudOS 构建版本缓存在 `~/.vphone/gpu-drivers/` 中，因此之后使用同一 cloudOS 的虚拟机会跳过临时恢复。

要复用之前提取的 bundle，请把它传给 `vm create` 或 `fw prepare`：

```sh
vphone-cli fw prepare myphone \
  --gpu-driver-bundle /path/to/AppleParavirtGPUMetalIOGPUFamily.bundle
```

CLI 会把该 bundle 的 iPhoneOS 平台版本与所选 cloudOS 版本进行核对。每次恢复都会在线获取自己的票据。

bundle 中还附带一个 arm64e GPU 编译器插件。`fw prepare` 会在打补丁和安装之前把它拷贝到准备好的 GPU bundle 中。

## 研究主板组合

26.4 beta 之后的 cloudOS 不含 vphone600 组件，因此由研究主板代替（见[兼容性](compatibility.md)）。它的 kernelcache 会用 vphone600 的虚拟化 kext 重新构建。全部步骤都以你的身份运行，不需要 sudo。

1. 照常运行 `fw prepare`。
2. 构建组合：

   ```sh
   vphone-cli fw kernelcache myphone
   ```

3. 继续运行 `fw patch`，它会从缓存中取用组合。以你的身份运行时，`fw patch` 也会自行构建组合；以 root 身份运行时，它只从缓存中取用。

`fw kernelcache` 旧的 `--ipsw` 参数仍可传入，但会被忽略。

## 链接组合的 kmutil

内核只能以 Apple 链接时所用的布局启动，而布局由链接它的 kmutil 决定：macOS 15 以及 26.0 到 26.3 把内核放在前面，macOS 26.4 及更新版本把内核放在后面，macOS 27 还会保留 kext 的 auth stub。每个 kernelcache 都记录了 Apple 构建它时所用的 kmutil 版本，所以 `fw kernelcache` 在任何 macOS 上都用同一版本链接组合：

| kernelcache | kmutil | 来自 |
| --- | --- | --- |
| iOS 18.1 到 18.3.1 | 463.40.2 | macOS 15.1 (24B83) |
| iOS 18.5 到 18.7.2 | 463.100.7 | macOS 15.6.1 (24G90) |
| iOS 26.4 到 26.7、watchOS 26.4、HomePod 26.5 | 487.100.11 | macOS 26.5 (25F71) |
| iOS 27.2 | 514.40.8 | macOS 27.2.1 (26B131) |

如果这台 Mac 自带的 kmutil 正是该版本，就直接使用它。否则会从 Apple 的 IPSW 中下载一次该 macOS 的恢复映像（约 1 GB），把其中的 kmutil 和内核集合构建器保存在 `~/.vphone/kernelcache/kmutil/<version>`（几 MB），然后删除映像。不会安装任何东西，也不会更改宿主机设置。通过 ssh 在另一台 Mac 上链接的 `VPHONE_KMUTIL_SSH` 已不再使用。

## 另请参阅

- [固件兼容性](compatibility.md)
- [创建与运行虚拟机](../machines/create-and-run.md)
- [资料库、固件与备份](../storage/library-and-backups.md)
- [kernelcache 配方](../../../VPhoneExecutable/VPhoneVirtualization/Resources/kernelcache_recipes/README.md)
