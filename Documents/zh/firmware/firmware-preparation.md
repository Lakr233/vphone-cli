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

26.4 beta 之后的 cloudOS 不含 vphone600 组件，因此由研究主板代替（见[兼容性](compatibility.md)）。它的 kernelcache 会用 vphone600 的虚拟化 kext 重新构建。KDK 提取以你的身份原生运行；只有 kmutil 链接需要 root 权限。

1. 照常运行 `fw prepare`。
2. 以你自己的身份准备组合：

   ```sh
   vphone-cli fw kernelcache myphone
   ```

3. 以 root 身份链接：

   ```sh
   sudo vphone-cli fw kernelcache myphone
   ```

4. 继续运行 `fw patch`，它会从缓存中取用组合。

`fw kernelcache` 旧的 `--ipsw` 参数仍可传入，但会被忽略。

## 在另一台 Mac 上链接

内核只能以 Apple 链接时所用的布局启动，而 kmutil 会采用它所运行的 Mac 的布局：

| 宿主机 macOS | 可链接 |
| --- | --- |
| macOS 26.4 及更新版本 | iOS 26.4 及更新版本的 kernelcache（kernel-last） |
| macOS 15，以及 26.0 到 26.3 | 较旧的 kernelcache（kernel-first），例如 iOS 18 |

如果这台 Mac 的布局不符，可以由另一台 Mac 或 macOS 虚拟机通过 ssh 链接组合。为 `fw kernelcache` 或创建流程设置以下变量：

```sh
export VPHONE_KMUTIL_SSH='user@host'
export VPHONE_KMUTIL_SSH_PASSWORD='password'   # only without ssh keys and passwordless sudo there
```

准备好的宗卷会上传到那台 Mac 的 `/private/var/tmp`，在那里以 root 身份链接，然后删除。这台 Mac 上不需要任何 root 权限。另一台 Mac 必须打开“远程登录”，并且该用户必须能够使用 sudo。

## 另请参阅

- [固件兼容性](compatibility.md)
- [创建与运行虚拟机](../machines/create-and-run.md)
- [资料库、固件与备份](../storage/library-and-backups.md)
- [kernelcache 配方](../../../VPhoneExecutable/VPhoneVirtualization/Resources/kernelcache_recipes/README.md)
