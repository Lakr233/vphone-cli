# 模板

模板是一台完整且已冻结的虚拟机，`vm create` 从它克隆出新的虚拟机。使用某组选项第一次创建时会构建模板；之后使用相同选项的每次创建只需几秒钟，也不会下载任何内容。要控制模板的构建、精简和清理方式，请参阅本页。

## 从模板创建虚拟机

`vm create` 默认使用模板：

```sh
vphone-cli vm create phone-a --iphone-source … --cloudos-source …   # builds the template, clones phone-a
vphone-cli vm create phone-b --iphone-source … --cloudos-source …   # clones phone-b, no restore
vphone-cli vm create phone-c --template 3f2a91c0d4e7 --cpu 4 --memory 6144
```

- 有匹配的模板时，`vm create` 会以新身份从模板克隆虚拟机，为它设置所需的 CPU、内存和网络，并启动一次以检查 vphoned。这既不需要 root 权限，也不需要 IPSW。
- 没有匹配的模板时，它会按需下载 IPSW，在暂存文件夹中运行完整流程，构建并冻结模板，然后从模板克隆虚拟机。
- `--template <id>` 按标识符或至少四位的唯一前缀从模板克隆，不接受 IPSW 选项。如果指定了 `--device`、`--preset`、`--disk-size` 和精简开关，它们必须与模板一致；克隆无法更改这些设置。
- `--no-template` 单独恢复虚拟机，使用它自己的密钥；不接受精简开关。

要手动把虚拟机制作成模板、查询 `vm create` 会使用哪个模板，或者了解 Launchpad 如何构建模板，请参阅[构建与查找模板](template-building.md)。

## 模板如何匹配

在恢复任何内容之前，`vm create` 会根据选项和两个 IPSW 算出一个模板键。该键包括：

- 客户机设备；
- iOS 和 cloudOS 的版本及构建版本；
- 补丁预设及其解析出的启动链补丁。对于 bundle 不自带的预设（预设文件，或 `~/.vphone/patches_presets` 中的预设），它解析出的每个补丁都会计入，包括客户机补丁，因为这类预设可能在标识符不变的情况下发生变化，而克隆会保留模板的客户机补丁；
- bundle 系列（2.9.x 为 `2.9`）；
- 磁盘大小；
- 从客户机 System 宗卷中精简掉的内容（`--trim`）以及保留的语言；
- 下文的精简开关。

CPU、内存、屏幕和网络不属于该键。

如果 IPSW 是本地文件或已在 IPSW 缓存中，构建版本从 IPSW 读取。否则，会像 [`vm template find`](template-building.md) 那样，从记录了相同两个来源的模板中获取；已被删除的本地 IPSW 视为不存在。

### 构建模板

没有匹配的模板时，完整流程会在 `.templates/.building-<id>-<uuid>/` 中运行：`cfw install`、离线精简，然后是设置启动。结果会冻结，并一步重命名为 `<library>/.templates/<id>/`。

- 无论 `--keep-artifacts` 如何设置，恢复目录都会在冻结前删除。它约有 11 GB，只要模板存在就会一直占用空间，而且任何克隆都用不上它。`--keep-artifacts` 只在使用 `--no-template` 时才会保留它；`vm template adopt` 也会删除它。
- 使用相同键的第二个 `vm create` 会等待第一个完成，而不是再恢复一份副本。
- 构建失败时，结果会保留在暂存文件夹中供检查。

模板在构建过程中会为设置启动而启动一次，冻结后就再也不会启动。

## 离线精简

`cfw install` 之后，模板构建会在宿主机上装载客户机的 System 宗卷，离线删除其中客户机永远用不到的系统文件。`vm create` 的 `--trim`（默认 `standard`）和 `vm template trim` 的 `--tier` 用于选择精简级别：

| 级别 | 删除的内容 | 约 |
| --- | --- | --- |
| `none` | 不删除 | |
| `conservative` | `usr/standalone/update` 中的内容（软件更新 ramdisk、基带固件） | 0.35 GB |
| `standard` | conservative 的内容，加上 AirPods/Beats 配对资源（`PreinstalledAssetsV2/RequiredByOs/com_apple_MobileAsset_SharingDeviceAssets`）、表盘（`NanoTimeKit/FaceBundles`），以及所有未保留语言的 `LinguisticData/RequiredAssets_*.bundle` | 1.2 GB |
| `aggressive` | 保留：在客户机上验证之前会被拒绝 | |

`--keep-languages`（默认 `en,zh-Hans,zh`；始终保留英语）选择 `standard` 保留哪些语言。级别、列表版本和保留的语言都属于模板键（`standard/1/en,zh,zh-Hans`），因此精简方式不同的模板永远不会匹配。

> [!WARNING]
> 精简无法撤销：克隆无法找回这些文件。

删除的文件起初不会释放任何空间。客户机原始的系统快照（`orig-fs.disabled.rn-*`，由 `cfw install` 留下）仍持有所有块，而宿主机即使以 root 身份也无法删除它。设置启动的第一步就是删除它，之后空间才会归还。因此，不会进行设置启动的模板不能精简，而精简过的模板只有在其快照删除后才能冻结或采纳。

`vm template trim` 不需要 root 权限。它可以在一台未从模板克隆、已停止的虚拟机上运行，也可以在未完成的 `.building-…` 文件夹上运行，但会拒绝已冻结的模板。

## 设置启动与精简

设置启动以每个克隆都应具备的初始状态完成模板。它启动模板一次，并通过 vphoned 依次执行：

1. 删除 `cfw install` 留下的 `orig-fs.disabled.rn-*` APFS 快照（在删除之前，它占用约 20 MB，外加从 System 宗卷中精简掉的所有文件）；
2. 跳过设置助理（`setup.skip`）；
3. 等待首次启动的工作完成（`setup.settle`，最长 10 分钟）：installd 会在首次启动时展开可移除的系统 App；
4. 移除系统 App（`apps.remove_system`，备份保留在客户机中）；
5. 应用服务配置（`services.profile.apply`），其中包括关闭登录后续操作守护进程（`followupd`、`appleidsetupd`）；
6. 重启，然后检查：没有残留快照、设置已完成、配置中的服务都未运行、已移除的 App 不存在、vphoned 有响应；
7. 清除 `vphone-vm` 在这次启动中固定的设备名称，然后正常关闭客户机。

每一步都有时限。某一步失败时，虚拟机会停止，不记录任何内容，构建也不会被冻结；`vm create` 会指出是哪一步以及如何重试。

| 开关 | 默认值 | 作用 |
| --- | --- | --- |
| `--slim on\|off` | on | `off` 不精简任何内容，保留所有 App 和服务。设置启动仍会运行：跳过设置并删除快照。 |
| `--trim none\|conservative\|standard` | standard | 上文所述的离线精简。 |
| `--keep-languages <list>` | `en,zh-Hans,zh` | `--trim standard` 保留的语言。 |
| `--service-profile trimmed\|none` | trimmed | vphoned 的精简配置：关闭约 140 个 launchd 任务，其中包括 App Store 守护进程和登录后续操作。使用此配置的手机无法与 Apple Watch 配对（见 `Research/Guest/watch_pairing.md`）。 |
| `--remove-apps on\|off` | on | 移除 App Store、“家庭”、Apple TV、Apple News、FaceTime 通话、iTunes Store、“信息”、“游戏”、“查找”和“钱包”。保留“相机”和“电话”。 |
| `--keep-apps <ids>` | 无 | 要从上述列表中保留的 bundle ID，以逗号分隔（`com.apple.findmy,com.apple.Passbook`）。 |
| `--accounts-off` | off | 同时关闭 `akd`、`amsaccountsd` 和 `appleaccountd`。之后客户机无法登录 Apple 账户。 |

每个选择都属于模板键，因此精简方式不同的模板可以并存，并且各自只服务于请求该精简方式的创建。服务配置的限制见[手表配对记录](../../../Research/Guest/watch_pairing.md)。

在克隆上，移除的 App 和服务配置仍可以撤销，方法是使用 `vphone-launchpad-cli guest rpc` 或 Launchpad 中的 **Guest System**：

- `apps.restore_system` 从备份中恢复一个 App。
- `services.profile.apply {"profile":"none"}` 重新开启配置所关闭的全部内容，不多也不少。

### 克隆继承的内容

克隆会从模板继承：已完成的设置、设置启动后的 App 和服务状态、installd 和索引程序在首次启动时完成的工作，以及那次启动时的 Data 宗卷。

克隆不会继承设备名称。模板固定的名称已被清除，因此在克隆自己的虚拟机连接并固定克隆的名称之前，它显示为 `iPhone`。新身份还意味着 Mac 会再次询问“要信任此电脑吗？”。

## 共享的密钥

> [!WARNING]
> 从同一个模板克隆出的每台虚拟机，都与模板以及彼此共享 SEP 根密钥、Data 宗卷密钥，以及恢复和设置启动写入的数据。理论上，一个克隆可以解密另一个克隆的 Data 宗卷。

需要独立密钥的虚拟机（例如为多设备研究登录 Apple 服务）应使用 `--no-template` 创建。

与 `vm clone --new-identity` 一样，克隆首次启动时会获得新的 ECID、UDID 和 MAC 地址。在 APFS 上，它们与模板共享所有未改动的块：新克隆在开始写入之前几乎不占用空间，而精简过的模板留给它的首次启动写入也很少。

## 管理模板

```sh
vphone-cli vm template list              # id, key summary, STALE with the reasons
vphone-cli vm template show <id> --json
vphone-cli vm template trim myphone --tier standard   # trim a stopped VM before adopting it
vphone-cli vm template setup myphone     # the setup boot, on a stopped VM
vphone-cli vm template adopt myphone     # freeze a stopped, newly created VM into a template
vphone-cli vm template delete <id>
```

### 过期的模板

当这个 `vphone-cli` 属于另一个 bundle 系列、模板的键格式较旧、它的预设现在解析出不同的启动链补丁，或者它的补丁回执与计划不一致时，模板会被列为过期（stale）。过期的模板永远不会被使用：使用其键的 `vm create` 会失败并指出该模板。删除它，下一次 `vm create` 就会构建新的模板。

### 采纳虚拟机

`vm template adopt <vm>` 把一台已停止的虚拟机转换为模板，使用的键来自它自己的记录：`restore-info.json`、`PatchPlan.plist`、`config.plist`、磁盘映像、Launchpad 的 `launchpad.json`，以及 `vm template trim` 和 `vm template setup` 记录在其 `Template.plist` 中的步骤。该虚拟机会从 `vm list` 中消失。

请在设置启动之后立即采纳虚拟机：每个克隆都会继承客户机在那之后所做的一切。有快照的虚拟机会被拒绝；会成为过期模板的虚拟机也会被拒绝，除非指定 `--force`。

### 已冻结的模板永远不会启动

`vm launch` 和 `vphone-vm` 会拒绝已冻结的模板，DFU 模式也一样。任何虚拟机名称都无法指向 `.templates` 中的内容，因此 `vm launch`、`clone`、`export`、`rename` 和 `delete` 不会意外选中模板。冻结后又启动过的模板会把状态写入之后每个克隆都会继承的块中，而此前创建的克隆将不再与它共享这些块。

### 使用模板的虚拟机

从模板克隆的虚拟机会在 `TemplateSource.plist` 中记录该模板。对它执行 `vm clone` 会保留该记录（副本同样共享模板的块），`vm export` 则不包含它（导入的虚拟机不共享任何内容）。该记录还注明了模板的构建，因此用相同键删除并重新构建的模板不会把从旧模板克隆出的虚拟机计算在内，因为它们不共享新模板的任何块。

`vm template list` 和 `show` 会列出使用每个模板的虚拟机及其磁盘占用，`vm info` 会显示虚拟机所用的模板。当 `vm delete` 删除了从某个仍存在的模板克隆出的最后一台虚拟机时，会给出提示，但绝不会删除模板本身：

```text
note: template 3f2a91c0d4e7 (~17.40 GB) is no longer used by any machine; remove it with `vphone-cli vm template delete 3f2a91c0d4e7`
```

### 删除模板

`vm template delete <id>` 删除模板；从它克隆出的虚拟机仍可正常使用。它们与模板仍共享的块只有在这些虚拟机改动它们或被删除时才会释放，因此只要克隆还在，删除模板释放的空间就小于模板的大小。

它打印的提示会说明属于哪种情况：要么列出使用该模板的虚拟机（它们共享的块在被改动或虚拟机被删除前一直占用），要么说明当前没有虚拟机使用它，因此删除会释放其块。模板存在期间创建的本地时间机器快照可能会保留这些块，直到快照过期。`--json` 配合 `--force` 会打印同样的信息。

模板会占用磁盘空间，尽管 `vm list` 不显示它们。请查看 `~/.vphone/machines/.templates`，并注意 `du` 会把模板及其每个克隆都按完整大小计算。

## 另请参阅

- [构建与查找模板](template-building.md)
- [批量创建虚拟机](many-machines.md)
- [在虚拟机之间共享磁盘空间](sharing-disk-space.md)
- [资料库、固件与备份](library-and-backups.md)
