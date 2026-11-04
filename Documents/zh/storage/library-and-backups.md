# 资料库、固件与备份

vphone 把虚拟机和下载的固件保存在哪里、如何移动它们，以及如何拷贝、备份和恢复虚拟机。规划磁盘空间、迁移资料库，或者需要虚拟机的第二份副本时，请参阅本页。

## 备份、拷贝与恢复

```sh
vphone-cli vm list
vphone-cli vm info myphone
vphone-cli vm clone myphone copy                    # backup: same identity
vphone-cli vm clone myphone second --new-identity   # a second device
vphone-cli vm export myphone --out myphone.tzst
vphone-cli vm import myphone.tzst --name restored
```

`vm clone` 拷贝一台已停止的虚拟机，可用时使用 APFS 写时拷贝。源虚拟机运行时会拒绝执行。

| 克隆方式 | 身份 | 用途 |
| --- | --- | --- |
| 普通 `vm clone` | 相同的机器标识符和 MAC 地址 | 备份。不能与原虚拟机同时运行。 |
| `vm clone --new-identity` | 新的机器标识符（ECID），因而也有新的 UDID；首次启动时获得新的 MAC 地址 | 可与原虚拟机同时运行的第二台设备 |

使用 `--new-identity` 的副本：

- 会清除固定 IPv4 地址、端口转发和手动指定的 mDNS 名称，因为它们会与原虚拟机冲突。由 `--mdns on` 根据原虚拟机名称生成的 mDNS 名称会像重命名时一样跟随新名称。如有需要，请用 `vm config` 重新设置。
- 保留原虚拟机的数据、App 和设置；不需要重新恢复。
- 需要你解锁它并再次信任这台 Mac，之后 `ideviceinstaller` 等 lockdown 工具才能使用。
- 在 APFS 上与原虚拟机共享磁盘块，只保存自己改动的部分，首次启动几次后约为 0.35 GB；不过 `du` 和访达会把每台都按完整大小计算。

> [!WARNING]
> 不要在虚拟机之间互换 `SEPStorage`、`nvram.bin` 或磁盘映像。它们是同一次恢复一起生成的，SEP 存储与磁盘不匹配的客户机会在启动时 panic。

## 文件存放位置

| 默认路径 | 内容 |
| --- | --- |
| `~/.vphone/machines/<name>/` | 一台虚拟机，包括其磁盘、`config.plist` 和补丁工作文件 |
| `~/.vphone/ipsws/` | 远程来源的 IPSW，所有虚拟机共用；本地 IPSW 在原位置读取 |
| `~/.vphone/gpu-drivers/<version>_<build>/` | 从 cloudOS 中提取的 GPU 驱动 bundle，所有虚拟机共用 |
| `~/.vphone/kernelcache/` | 不含 vphone600 组件的 cloudOS 版本所用的 kernelcache 组合、准备好的宗卷，以及从供体中提取的内容 |

移动位置：

| 设置 | 移动的内容 |
| --- | --- |
| `VPHONE_ROOT` | 整个 `~/.vphone` 数据根目录：虚拟机资料库和各类缓存 |
| `VPHONE_LIBRARY_ROOT` | 仅虚拟机资料库；优先于 `VPHONE_ROOT` |
| `vm create` 和 `fw prepare` 的 `--ipsw-cache <dir>` | 仅 IPSW 缓存 |

## IPSW 缓存与下载

下载的 IPSW 会一直缓存到你删除为止，因此用同一 URL 创建第二台虚拟机时无需再下载。在 Launchpad 中，可以通过 **File > Downloaded IPSWs…** 删除它们。

`vm create` 成功后，准备好的恢复目录会被删除，除非传入了 `--keep-artifacts`。旧版本准备的虚拟机可能仍有一个 `.ipsw-cache/` 目录；可以放心删除，`vm export` 也不会包含它。

如果服务器支持 HTTP 范围请求（Apple 的 CDN 支持），远程 IPSW 会同时通过四个连接下载。每个连接依次获取 32 MB 的分段，分段中断后会从中断处继续。`fw prepare` 的 `--download-connections <n>` 用于设置连接数，范围为 1 到 16。设为 1 时 IPSW 以单一数据流下载，不支持范围请求的服务器也是这样处理。

## 磁盘空间与内存

占用资源较多的创建任务请一次只运行一个。IPSW 和临时恢复目录会占用大量磁盘空间，为大型缓存打补丁也可能占用很多内存。开始创建第二台虚拟机之前，请检查可用空间。

如果资料库位于已装载的外置宗卷上，Launchpad 会把 CFW 临时文件放在该宗卷上。独立运行的 `vphone-cli cfw install` 默认使用 `/private/var/tmp`，也可以用 `--work-parent` 指定一个 root 拥有的私有目录。

## 另请参阅

- [快照](snapshots.md)
- [模板](templates.md)
- [在虚拟机之间共享磁盘空间](sharing-disk-space.md)
- [创建与运行虚拟机](../machines/create-and-run.md)
