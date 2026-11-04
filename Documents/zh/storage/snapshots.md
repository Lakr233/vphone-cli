# 快照

快照保存已停止虚拟机的磁盘和启动状态，以便日后还原到该状态。可以在全新安装后创建快照，在客户机中尝试有破坏性的操作，然后再还原。

## 创建、列出、还原和删除

1. 停止虚拟机：运行 `vphone-cli vm stop myphone`，或在其窗口中关闭它。
2. 创建快照，然后在客户机中操作。想回到保存的状态时，再次停止虚拟机并还原快照。

```sh
vphone-cli vm snapshot create myphone clean --note "fresh install"
vphone-cli vm snapshot list myphone
vphone-cli vm snapshot revert myphone clean
vphone-cli vm snapshot delete myphone clean
```

- `revert` 和 `delete` 在改动任何内容前都会询问；`--force` 跳过询问。
- 还原后快照仍会保留，因此可以再次回到该快照。
- `list --json` 打印一个由 `{"name", "created", "note"}` 对象组成的数组，按从旧到新排列，`created` 采用 ISO 8601 格式，没有备注时省略 `note`。
- `list` 和 `delete` 可以在虚拟机运行时使用；两者都不会触及虚拟机正在使用的文件。

## create 或 revert 被拒绝时

虚拟机正在运行时，或者有任何进程打开了它的磁盘映像、`SEPStorage` 或 `nvram.bin` 时，`create` 和 `revert` 会拒绝执行。拒绝信息会列出持有这些文件的每个进程。如果这些进程都不是在运行虚拟机（例如备份工具或聚焦），信息中会说明这一点，等该进程关闭文件后重试即可成功。

如果虚拟机不在 APFS 宗卷上，`create` 也会拒绝执行，而不是拷贝可能有几十 GB 的磁盘映像。

如果快照的 `Snapshot.plist` 没有列出全部三个状态文件，或者列出了不属于快照的文件，就会在改动任何内容之前被判定为已损坏并拒绝使用。

还原要么全部完成，要么完全不做。如果中途失败，它会把虚拟机自己的文件放回原处并报告错误，因此虚拟机保持原样。在极少数情况下，如果放回文件也失败了，错误信息会说明这一点：请在启动虚拟机之前再次还原到某个快照。

## 快照包含的内容

| 包含的内容 | 原因 |
| --- | --- |
| 磁盘映像（`Disk.img`） | 客户机的系统和数据 |
| `SEPStorage`、`nvram.bin` | 安全隔区状态和启动链的 NVRAM，必须与磁盘匹配 |
| `PatchReceipt.plist` | 客户机中实际生效的补丁 |
| `restore-info.json` | 磁盘上的 iOS 版本，以及 `cfw install` 是否完成 |

磁盘、`SEPStorage` 和 `nvram.bin` 总是一起变动。安全隔区的防重放计数器保存在 `SEPStorage` 中，磁盘保存与之匹配的状态；如果磁盘与 `SEPStorage` 来自不同时刻，SEP 会在下次启动时 panic。

`PatchReceipt.plist` 和 `restore-info.json` 存在时会被保存。如果创建快照时其中某个文件不存在，还原时会删除它，从而让这些记录描述的是还原后的磁盘，而不是之后的某次安装。

不包含在快照中、还原时也不会改变的内容：

- `config.plist`：设备身份、CPU、内存、网络和其他设置。随时可以用 `vm config` 更改；还原快照不会撤销这些更改。
- 补丁选择（`PatchSelection.plist`）、恢复目录、`FirmwareOriginals/` 和 ROM。这些是 Mac 上的输入，而不是客户机状态。
- `launchpad.json`。Launchpad 会在快照文件夹中保存自己的副本，并自行放回。CLI 不会改动快照文件夹中的任何额外文件，并在删除快照时一并删除它们。

## 磁盘空间

快照以 APFS 克隆的形式保存在 `<vm>/Snapshots/<name>/` 中。创建快照是瞬间完成的，不占用空间：在客户机写入之前，虚拟机与它的快照共享所有块，写入之后也只有改动过的块占用新空间。`du` 和访达会按磁盘的完整大小计算每个快照，夸大了实际占用；宗卷的可用空间才是准确的衡量标准。

快照会保留创建时的磁盘块。只要该虚拟机的快照仍持有旧块，`vm rebase` 就不会释放任何空间；见[在虚拟机之间共享磁盘空间](sharing-disk-space.md)。

## 克隆、导出与重命名

`vm clone` 和 `vm export` 不包含快照：克隆或导入的虚拟机一开始没有快照。删除或重命名虚拟机时，它的快照会一起删除或重命名。

## 另请参阅

- [资料库、固件与备份](library-and-backups.md)
- [在虚拟机之间共享磁盘空间](sharing-disk-space.md)
- [故障排查](../help/troubleshooting.md)
