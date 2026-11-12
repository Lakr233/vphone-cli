# Launchpad 命令行

`vphone-launchpad-cli` 可以在终端或脚本中操作正在运行的 Launchpad：安装 bundle，创建、启动和停止虚拟机，以及与客户机通信。想要使用 Launchpad 的功能、又不想在窗口中逐项点击时，请使用它。

## 设置

CLI 位于 `vphone-launchpad.app/Contents/MacOS` 中。把它链接到你的 `PATH`：

```sh
ln -s /Applications/vphone-launchpad.app/Contents/MacOS/vphone-launchpad-cli /usr/local/bin/
vphone-launchpad-cli help
```

Launchpad 未运行时，CLI 会启动它。由 CLI 启动的 Launchpad 会隐藏打开，不会抢走前台 App 的焦点；点击它的程序坞图标，或菜单栏中的 Open Launchpad，即可显示窗口。如果想让它启动时窗口位于前台，请传入 `--foreground`（放在命令之前，或放在除 `exec` 以外任何命令的选项中）。两种方式都不会影响已经在运行的 Launchpad。

## 输出与退出状态

- 进度信息实时输出到 stderr。
- 结果是 stdout 上的一个 JSON 文档。
- 成功时退出状态为 0，失败时为 1，原因输出到 stderr。
- 中断 CLI 会取消可以取消的命令（`exec`、等待、CFW 安装）。bundle 安装和虚拟机创建属于窗口，会继续运行。

每条命令也会显示在 Launchpad 的窗口和命令历史中。

## 命令

如果两个资料库中有同名虚拟机，虚拟机命令可以用 `--root <library>` 指定资料库。

### 状态与 bundle

| 命令 | 作用 |
| --- | --- |
| `status` | 宿主机检查、辅助程序、默认 bundle、虚拟机数量 |
| `bundle list` | 已安装的版本、回执、cdhash、检查结果、绑定的虚拟机 |
| `bundle install-local <path> [--keep-default]` | 安装本地的 `VPhone.bundle` 文件夹或 `.zip` |
| `bundle install-release <version\|latest> [--keep-default]` | 下载并安装 GitHub release |
| `bundle set-default <version>` | 把某个版本设为默认。`bundle use` 是旧名称 |
| `bundle verify <version>` | 重新检查某个版本 |
| `bundle accept <version> [--off]` | 跳过未通过的检查，或用 `--off` 停止跳过 |
| `bundle remove <version>` | 删除没有虚拟机绑定的版本 |

要安装本地构建、把虚拟机迁移到该构建，或比较两个构建，请参阅 [Core Bundle 与本地构建](core-bundles.md)。

### 虚拟机

| 命令 | 作用 |
| --- | --- |
| `vm list` | 所有资料库中的虚拟机，包括运行状态、Core Bundle 和日志路径 |
| `vm start <name> [--headless] [--wait]` | 用虚拟机自己的 bundle 启动。`--wait` 等待 vphoned |
| `vm stop <name>` | 请求客户机关机（vphoned `system.shutdown`），最多等待 30 秒。无法请求客户机或客户机没有停止时，直接结束虚拟机 |
| `vm wait <name>` | 等待 vphoned |
| `vm log <name> [--lines <n>] [--kind create\|dfu\|patch]` | 读取控制台日志 |
| `vm create <name> [options]` | New Machine 流程；见下文“创建虚拟机” |
| `vm set-bundle <name> <version> [--update-environment]` | 把虚拟机绑定到另一个已安装的版本 |
| `vm leases [--release]` | 共享 NAT 网络上的 DHCP 租约及各自所属的虚拟机。`--release` 通过辅助程序释放任何资料库中都没有虚拟机使用的租约（见[旧 MAC 地址占用的地址](../networking/addresses.md)） |

说明：

- 在 `vm list` 中，只有持有磁盘的虚拟机进程（`vphone-vm` 或 Virtualization 的虚拟机服务）才会让虚拟机显示为 `running`。其他打开了磁盘的进程（`tail`、聚焦、备份工具）会列在 `diskOpenIn` 中（例如 `12925 tail`），虚拟机仍显示为 `stopped`。
- 与 `vphone-cli vm launch` 一样，`vm start` 不会因为某个进程只是打开了磁盘而拒绝启动；它会打印一条提示，指出该进程。
- `vm start --wait` 和 `vm wait` 也接受 `--timeout`。
- `vm set-bundle --update-environment` 还会重新部署该版本的客户机环境，并要求虚拟机处于停止状态。如果有其他进程打开了磁盘，它会在更改绑定之前拒绝执行并指出该进程。如果更新本身失败，虚拟机仍会绑定到新版本，`vm list` 仍显示旧的 `guestEnvironmentBundle`；请运行 `cfw update-environment` 完成更新。

### CFW

这些命令在已停止的虚拟机上通过 Launchpad 的辅助程序运行，使用虚拟机自己的 bundle。如果有其他进程打开了磁盘，每条命令都会拒绝执行并指出该进程（`12925 tail`）。

| 命令 | 作用 |
| --- | --- |
| `cfw install <name>` | 安装 CFW。适用时，辅助程序会把临时工作文件放在虚拟机资料库所在的外置宗卷上 |
| `cfw update-environment <name>` | 重新部署 bundle 的客户机资源（vphoned、hook dylib）；其他内容不变 |
| `cfw update-kernel <name>` | 按虚拟机当前的补丁选择重新为 kernelcache 打补丁，并替换到 Preboot 中，保留数据。这是在已安装的虚拟机上更改内核补丁且保留数据的方式；不需要恢复目录 |

### 客户机

`guest` 命令和 `--wait` 通过虚拟机的 `vphone.sock` 通信，每次启动都会提供这个套接字。2.0.9 及更早版本的 bundle 只为带窗口启动的虚拟机提供它。

| 命令 | 作用 |
| --- | --- |
| `guest send <name> <json>` | 发送一条原始的 `vphone.sock` 请求（tap、swipe、key、screenshot） |
| `guest rpc <name> <method> [params]` | 调用任意 vphoned 方法；见 [`Research/vphoned_http_api.md`](../../../Research/vphoned_http_api.md)。vphoned 拒绝时，stderr 的最后一行是 JSON 格式的错误对象（`code`、`message`、`results`、`reason` …） |
| `guest push <name> <local> <guest-path> [--mode <octal>]` | 把 Mac 上的文件拷贝到客户机。文件通过 vphoned 流式传输，因此大小不受 `guest rpc` 单行 JSON 1 MiB 的限制；适用于二进制文件和 IPA。客户机路径以 `/` 结尾时保留文件名；权限默认与 Mac 上的文件相同 |
| `guest pull <name> <guest-path> <local>` | 把客户机中的文件流式拷贝到 Mac。`local` 可以是文件夹。文件完整传输后才会替换 `local` |
| `guest unlock <name> [--passcode <code>] [--timeout <seconds>]` | 无论客户机处于什么状态，都点亮屏幕并解锁（vphoned `screen.unlock`）。只有客户机设置了密码时才需要 `--passcode` |

### 运行 vphone-cli

| 命令 | 作用 |
| --- | --- |
| `exec [--bundle <version>] <vphone-cli arguments>` | 运行默认 bundle 或指定版本中的 `vphone-cli`，并实时输出。`--bundle` 必须放在最前面 |

## 创建虚拟机

`vm create` 运行 New Machine 流程，绑定到 `--bundle <version>` 或默认 bundle。虚拟机从模板克隆，模板不存在时会先构建（2.9）；使用 `--no-template` 时则单独恢复。

```sh
vphone-launchpad-cli vm create rt-e --block system-debugserver-cfw-install
```

| 选项 | 作用 |
| --- | --- |
| `--bundle <version>` | 把虚拟机绑定到这个已安装的版本，而不是默认版本 |
| `--device <product-type>` | 创建其他设备；见下文“其他设备” |
| `--preset <preset>` | 预设名称，或预设 plist 的路径（2.14），虚拟机会保留一份副本 |
| `--block <patch>`、`--allow <patch>` | 关闭或开启预设中的某个补丁；可重复使用。见下文“补丁覆盖” |
| `--no-template` | 单独恢复虚拟机，而不是从模板克隆。精简开关中只有 `--slim` 适用：`on`（默认）让这台虚拟机自己做一次初始化启动，会跳过设置助理；`off` 则从设置助理开始 |
| `--slim on\|off`、`--trim …`、`--keep-languages …`、`--service-profile …`、`--remove-apps …`、`--keep-apps …` | `vphone-cli vm create` 的精简开关。与 New Machine 中一样，Apple 账户随精简的服务配置一起关闭 |
| `--accounts-off` | 可以传入，但不会改变任何设置 |
| `--ipsw <path>` | 可选。只传给 2.12.0 bundle，它用这个文件准备 kernelcache 组合，作用与 New Machine 的 ipsw 字段相同。2.12.1 bundle 会原生提取 |
| `--kmutil-ssh <user@host>` | 通过 ssh 链接 iOS 18 客户机（`--device iPhone11,6`）kernel-first 组合的 Mac，作用与 New Machine 的 macOS 构建机字段相同。该机上 ssh 和 sudo 的密码来自客户端的 `VPHONE_KMUTIL_SSH_PASSWORD`，绝不从参数传入 |
| `--from <step>` | 使用创建开始时的选项，从某个步骤（`findTemplate` … `firstBoot`）重试 |

解析器还接受 `--iphone-source`、`--cloudos-source`、`--cpu`、`--memory`、`--disk-size`、`--network`、`--keep-artifacts` 和 `--no-wait`；见 `vphone-launchpad-cli help`。

结果会注明所用的模板、该模板是否由这次创建构建，以及所用的补丁。

### 其他设备

| `--device` | 客户机 | 说明 |
| --- | --- | --- |
| iPad 产品类型 | iPadOS | 见 [iPadOS 客户机](../firmware/ipados.md) |
| `AppleTV5,3` | Apple TV HD | 始终单独恢复，不做精简；除非 `--preset` 指定了其他预设，否则使用 `tvos` 预设 |
| `AppleTV14,1` | Apple TV 4K（第 3 代） | 同上，使用 `tvos-4k` 预设，用户空间来自目录中的 OTA |
| `AppleTV18,1` | Apple TV 4K（第 4 代） | 需要 Launchpad 和 Core Bundle 2.13。选择 `tvos-4k`，单独恢复且不做精简，并使用叠加在 Apple TV HD 基础之上的完整 OTA 中的 tvOS 27.2 beta（`24K120`）。创建需要 macOS 27。实际启动测试尚未完成；见[适配记录](../../../Research/Firmware/tvos_support.md#apple-tv-4k-4th-generation) |

另有两种情况会通过辅助程序以 root 身份运行某些步骤：

- `--preset minimal`（Minimal：原装的启动链、内核和 TXM，在恢复前定制系统）也会单独恢复且不做精简，它的 `fw patch` 通过辅助程序以 root 身份运行。它的用户空间调试选项（`vphone-cli fw patches` 中 Features 下的 `userspace-debugging`）相当于对其列出的每个补丁使用 `--allow`。它的 Trusted darwinOS environment 选项（`trusted-darwinos`，即 `--allow filesystem-exp-trusted_darwinos`）会把 iPhone 或 iPad 以 trusted darwinOS 环境恢复，并加入 cloudOS 的 cryptexctl，这样就能在客体运行时安装 cryptex（VM 窗口中的 Apps › Install Cryptex…，参阅 [Cryptex](../machines/cryptexes.md)），选项下方的说明列出了它的影响。此后客体会强制执行 Restricted Execution Mode，研究板客体（cloudOS 26.5 至 26.7）无法打开开发者模式；更改此选项只有在重新恢复后才会生效。
- 对于 cloudOS 不含 vphone600 组件的虚拟机（使用其版本自己的 cloudOS、手表、iOS 18 客户机），kernelcache 组合由 `fw kernelcache` 准备，再由辅助程序以 root 身份链接。

### 补丁覆盖

`--block <patch>` 和 `--allow <patch>` 接受 `vphone-cli fw patches` 列出的标识符，每个补丁用一次：

```sh
vphone-launchpad-cli exec fw patches --preset <preset>
```

Launchpad 从这次创建所用的 bundle 中读取该目录，拒绝没有任何补丁集声明的标识符以及同时被阻止和允许的标识符，并像 `fw set-patches` 一样只保留与预设不同的部分。然后它按照 New Machine 的方式把它们分为两类：

- **启动链补丁**（AVPBooter、iBSS、iBEC、LLB、TXM、kernelcache、DeviceTree …）属于模板的键。Find Template 会查找带有这些补丁构建的模板，模板构建会在 `fw patch` 之前用 `fw set-patches` 记录它们。
- **客户机补丁**不属于模板。克隆会用 `fw set-patches` 记录它们，Apply Guest Patches 步骤会在首次启动前通过辅助程序用 `cfw update-environment` 写入。因此，只有客户机覆盖设置时会复用普通模板。

结果中的 `patches` 对象包含预设、`blocked` 和 `allowed` 覆盖设置，以及应用到克隆上的 `guest` 覆盖设置。使用 `--no-template` 时，所有覆盖设置都会进入虚拟机自己的恢复。`--from` 不接受 `--block` 和 `--allow`：重试会沿用这次创建的补丁。

## 结果中的 bundle 字段

| 命令 | 字段 | 含义 |
| --- | --- | --- |
| `status` | `defaultBundle` | 默认版本。`activeBundle` 为旧脚本保留相同的值 |
| `bundle list` | `default` | 该版本是默认版本。`active` 为旧脚本保留相同的值 |
| `bundle list` | `machines` | 绑定到该版本的虚拟机名称 |
| `vm list` | `bundle` | 虚拟机的宿主机程序所用的版本 |
| `vm list` | `guestEnvironmentBundle` | 最近一次安装客户机环境所用的版本；未知时为 `null` |
| `vm list` | `bootChainBundle` | 构建启动链所用的版本；在 Launchpad 开始记录之前创建的虚拟机为 `null` |
| `vm create`、`cfw …`、`exec` | `bundle` | 命令运行所用的版本 |

当 `guestEnvironmentBundle` 与 `bundle` 不同时，宿主机和客户机来自不同的构建；运行 `cfw update-environment` 可以让客户机与之保持一致。

## 触摸坐标与显示几何

`guest send` 的触摸坐标以 `t:screenshot` 返回的**完整竖直截图**为准：旋转四分之一圈后，宽度和高度会互换。无论是图形界面启动还是无界面启动，宿主机都会把该点转换为固定面板的 HID 坐标。滑动会沿用开始时采样的几何信息。如果截图期间几何信息发生变化，你会收到错误，而不是一张输入坐标含义不明确的图像。

要诊断旋转后坐标不匹配的问题，请读取几何信息：

```sh
vphone-launchpad-cli guest send <name> '{"t":"display.geometry"}'
```

它会返回宿主机配置的和实际捕获的像素尺寸，以及当前显示视图的边界、旋转、等比适配的绘制区域和指针/触摸路径，不会改变任何输入或显示状态。`capture_pixels` 是宿主机的原始帧；`screenshot_pixels` 和 `input_orientation` 描述输入坐标。请将其与 `device.screen`、`display.orientation` 以及客户机实际收到的事件进行比较。

## 连接方式

CLI 通过 `~/Library/Application Support/vphone-launchpad/control.sock` 上的 Unix 套接字（权限 0600，只为同一用户提供服务）与正在运行的 Launchpad 通信。它没有任何特权，也没有自己的状态：bundle 通过 Launchpad 的辅助程序安装，每台虚拟机都通过它自己 Core Bundle 中的 `vphone-cli` 运行。没有任何东西在网络上监听；要从其他机器使用它，请通过 ssh 连接。

## 另请参阅

- [Core Bundle 与本地构建](core-bundles.md)
- [Bundle 集成](bundle-integration.md)
- [创建与运行](../machines/create-and-run.md)
