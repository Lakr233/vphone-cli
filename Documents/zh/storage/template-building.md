# 构建与查找模板

如何手动把虚拟机制作成模板，如何查询 `vm create` 会使用哪个模板，以及 Launchpad 如何构建模板。模板是什么、它的键包括哪些内容，请先阅读[模板](templates.md)。

## 把虚拟机制作成模板

要在创建虚拟机后立即把它转换为模板，请依次停止、精简、进行设置启动，然后采纳。Launchpad 在需要构建模板时也是这样做的：

```sh
vphone-cli vm stop phone-src
vphone-cli vm template trim phone-src --tier standard   # offline, no root; frees nothing until the setup boot
vphone-cli vm template setup phone-src        # headless; --window to watch, slimming switches as for vm create
vphone-cli vm template adopt phone-src --iphone-source … --cloudos-source …   # key from its records; the sources are recorded
vphone-cli vm create phone-d --template <id> --skip-first-boot
```

### vm template setup

- 拒绝运行中的虚拟机和已冻结的模板。
- 自身不做任何精简：它沿用 `vm template trim` 记录的级别，并拒绝指定了其他级别的 `--trim`。
- 在虚拟机上运行时，如果有 vphoned 无法移除的 App，它会报告出来，并且不把该 App 写入记录的步骤中，这样采纳后的键反映的就是实际完成的操作。
- `--strict` 会让它直接失败；此时不记录任何内容，可以再次运行设置启动。如果虚拟机之后要用 `--expect` 以 `vm template find` 针对相同开关给出的键采纳，请使用此选项。
- 如果传入 `vm template list` 中的 `.building-…` 名称（设置启动失败的 `vm create`），它会按照该构建的键进行设置，从而确定精简方式；如果构建在离线精简之前就停止了，会先运行离线精简，成功后再冻结。

### vm template adopt

| 选项 | 作用 |
| --- | --- |
| `--iphone-source`、`--cloudos-source` | 像构建模板的 `vm create` 一样，把创建该虚拟机所用的 IPSW 记录到其 `Template.plist` 中。 |
| `--json` | 像 `vm template show --json` 一样打印新模板。 |
| `--expect <id>` | 除非虚拟机的记录得出的模板标识符为 `<id>`（即 `vm template find` 针对构建该虚拟机所用选项打印的 `id`），否则拒绝采纳，并保持虚拟机原样。 |

只要之后还需要再次找到某个模板，就请使用 `--expect`。如果不使用，设置启动未完全达成（有无法移除的 App）的虚拟机会以另一个键保存，之后使用这些选项的每次 `vm create` 都找不到它，于是又会构建一个新模板。

如果能推算出预期的键（库中有模板或构建具有该键，或者只有精简方式不同时可以推算），拒绝信息会列出不同的字段。否则会打印虚拟机自己的键供比较。使用 `--json` 时，拒绝信息也会打印到 stdout，命令以状态码 1 退出：

```text
{"adopted": false, "error": "unexpected_template", "id": …, "expected": …, "differences": […], …}
```

## 查找模板

`vm template find` 可以回答使用相同选项的 `vm create` 会从哪个模板克隆，而不会下载、恢复或改动任何内容：

```sh
vphone-cli vm template find --iphone-source … --cloudos-source … [--device …] [--preset …] [--disk-size …] [--block <id>] [--allow <id>] [slimming switches] --json
```

它像 `vm create` 一样推算键。如果 IPSW 是本地文件或已在 IPSW 缓存中，构建版本从 IPSW 读取；否则从记录了相同两个来源的模板中获取，因此即使 IPSW（包括本地 IPSW）已被删除，键仍然可以解析。`--block` 和 `--allow` 是按 `fw set-patches` 记录方式表示的单个补丁覆盖设置。

| JSON 字段 | 含义 |
| --- | --- |
| `resolved` | 能否推算出键 |
| `resolvedBy` | `ipsw` 或 `template` |
| `id` | 模板标识符 |
| `summary` | 键摘要 |
| `key` | 完整的键 |
| `template` | 匹配的模板，格式与 `vm template show --json` 的输出相同，可能是当前的或过期的 |
| `usable` | 模板存在且未过期 |
| `building` | 有创建任务持有其构建锁 |
| `reason` | 键无法解析时的原因 |

## 在 Launchpad 中

Launchpad 2.9 及更新版本默认从模板创建虚拟机。

### New Machine

New Machine（新建虚拟机）打开时是一个简短的页面：名称、来自固件目录的设备和 iOS 版本，以及一个 **Slim System**（精简系统）开关。下方有一行汇总其余设置，点击可打开 **Advanced Options**（高级选项），共四页：

- 硬件；
- 模板及其组成部分：精简级别和保留的语言、服务配置，以及要移除哪些系统 App；
- Core Bundle、自定义 IPSW 和补丁；
- 位置、网络和恢复选项。

这一行会统计与默认值不同的设置数量，并指出其中阻止 **Create**（创建）的内容。关闭 **Create from a template**（从模板创建）后，会像 `--no-template` 一样单独恢复虚拟机，使用它自己的密钥，且不做精简。不提供 Apple 账户选项：无论如何客户机都会拒绝登录，因此只要服务配置为精简，Launchpad 就会传入 `--accounts-off`。表单会随页面内容增高，最高 600 点，超过后可以滚动，因此在笔记本电脑屏幕上按钮也始终可见。

### 需要重建 kernelcache 的固件

在 **Firmware**（固件）下，如果某个版本也能在它自己的 cloudOS 上运行（`fw catalog` 的第三列），就会在推荐的 cloudOS 旁边提供该 cloudOS。创建时会以你的身份构建 kernelcache 组合，并由构建该版本 kernelcache 时所用的 kmutil 链接（见[固件准备](../firmware/firmware-preparation.md#链接组合的-kmutil)）。使用 Core Bundle 2.17 及更早版本时，改由辅助程序以 root 身份链接，这会请求一次授权。

对于这些组合，Launchpad 仍会显示一个 `ipsw` 工具字段，供用它来准备组合的旧版兼容 Core Bundle（2.12.0）使用。Core Bundle 2.12.1 及更新版本会原生提取，并忽略所选的路径。

iPhone XS Max 运行 iOS 18.1 到 18.7.2，每个版本都运行在各自版本的 cloudOS 上，不使用模板，默认使用 Minimal 预设；Standard 同样可用（已在 18.6 上验证）。它的组合总是需要重建 kernelcache，在任何 macOS 上都由 macOS 15 的 kmutil 链接。

### 创建流程如何使用模板

创建流程会先运行 `vm template find`。

- 如果有未过期的模板匹配，就从它克隆虚拟机（`vm create --template <id> --skip-first-boot`）并启动。
- 如果没有匹配的模板，就在同一个资料库中的一台临时虚拟机里构建模板，名称为 `template-` 加八位十六进制数字。它运行常规步骤（恢复，然后通过辅助程序执行 `cfw install`），接着运行 `vm template trim`、无界面的 `vm template setup --strict` 和 `vm template adopt --iphone-source … --cloudos-source … --expect <id>`，最后从结果中克隆虚拟机。

如果应移除的 App 仍然存在，设置启动就会失败；如果构建的键与 `find` 算出的不同，采纳就会失败。因此，构建永远不会以之后的创建找不到的 id 保存。每一项都是独立的步骤，会显示各自的耗时，失败的步骤会显示 `vphone-cli` 给出的原因。

New Machine 的 **Patch Settings**（补丁设置）中的单个补丁覆盖设置，按模板键的划分方式分为两类：

- 启动链覆盖设置属于键：模板会带着它们构建，`find` 也会查找带有它们的模板。
- 客户机补丁覆盖设置不属于键：模板构建时不包含它们。克隆之后，创建流程会用 `fw set-patches` 把它们记录到新虚拟机上，并在首次启动前通过辅助程序用 `cfw update-environment` 写入（即 **Apply guest patches** 步骤）。因此，模板永远不会把某次创建的客户机补丁选择带给另一次创建。

构建好模板后，创建流程会询问是否删除构建它所用的两个 IPSW；未经确认不会删除任何内容。

### 在 Launchpad 中管理模板

- **File > Templates…** 列出每个资料库的模板及其虚拟机、精简方式、大小和状态，并可以删除它们。
- **Guest System…**（位于虚拟机的 Actions 菜单和检查器中）可以切换运行中虚拟机的服务配置，并恢复模板移除的系统 App。
- 检查器和虚拟机列表会在每台虚拟机文件分配的空间旁显示其独占的磁盘占用：即没有其他虚拟机或模板持有、删除该虚拟机就会释放的块。在此之前创建的本地时间机器快照会保留这些块，直到快照过期。

## 另请参阅

- [模板](templates.md)
- [批量创建虚拟机](many-machines.md)
- [固件准备](../firmware/firmware-preparation.md)
- [Launchpad CLI](../launchpad/launchpad-cli.md)
