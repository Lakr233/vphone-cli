# 创建与运行虚拟机

在终端中用 `vphone-cli` 创建、启动和停止虚拟机。不使用 Launchpad、用脚本创建虚拟机，或者需要重复执行流程中的某个阶段时，请参阅本页。

Launchpad 通过 `VPhone.bundle` 中的 `vphone-cli` 管理虚拟机；同样的命令也可以在终端中使用：

```sh
vphone-cli vm list
vphone-cli vm launch myphone
vphone-cli vm export myphone --out myphone.tzst
```

虚拟机保存在 `~/.vphone/`。运行 `vphone-cli <group> --help` 查看全部命令。

## 创建虚拟机

你需要一个 iPhone17,3 恢复 IPSW 和一个兼容的 PCC/cloudOS IPSW，可以是本地路径或 URL。[兼容性](../firmware/compatibility.md)列出了目前已验证的组合。

```sh
vphone-cli host preflight
vphone-cli vm create myphone \
  --iphone-source /path/to/iPhone17,3_Restore.ipsw \
  --cloudos-source /path/to/cloudOS.ipsw
```

创建过程依次经过以下阶段：准备、固件补丁、在线 DFU 恢复、在宿主机上装载并安装 CFW、首次图形界面启动。

- 需要联网获取恢复票据。
- 安装 CFW 需要 root 权限。bundle 不带授权对话框或提权辅助程序，因此需要你自己提供 root 权限。
- 默认虚拟磁盘为 64 GB。

成功时会以 `[+] First boot: vphoned ping succeeded.` 和 `CFW VM created; vphoned connected. Guest user environment is untouched.` 结束。之后虚拟机会停止：这次 ping 证明 vphoned 在该次启动中作出了响应，同时不会留下运行中的虚拟机。

### 选项

| 选项 | 作用 |
| --- | --- |
| `--iphone-version`、`--iphone-build` | 像 `fw prepare` 一样为 `--device`（默认为 iPhone17,3）解析 iPhone IPSW，而不必传入 `--iphone-source`。 |
| 省略 `--cloudos-source` | 使用目录为该版本推荐的 cloudOS，即 `fw catalog` 列出的那个。 |
| `--disk-size` | 虚拟磁盘大小，单位为 GB（默认 64）。 |
| `--preset` | 补丁预设名称，或预设 plist 的路径（默认 `standard`）。运行 `fw patches` 查看每个预设应用哪些补丁。 |
| `--cpu` | CPU 核心数（默认 8）。 |
| `--memory` | 内存，单位为 MB（默认 8192）。 |
| `--network` | `nat`（默认）、`bridged`、`tunnel` 或 `none`。 |
| `--unlock-at-startup` | `on` 或 `off`（默认）。 |
| `--no-template` | 单独构建虚拟机，不从模板克隆。 |
| `--skip-first-boot` | 跳过最后的启动，适用于由调用方自行启动虚拟机的情况。 |
| `--bootstrap roothide` | 在首次启动时安装软件包环境。见[软件包环境](package-environment.md)。 |
| `--keep-artifacts` | 保留体积很大的已准备恢复目录。磁盘空间紧张时不要加。 |

`--cpu`、`--memory`、`--network` 和 `--unlock-at-startup` 会为新虚拟机设置与 `vm config` 相同的配置项。

### 模板

默认情况下，流程会先构建一个[模板](../storage/templates.md)，再从模板克隆出虚拟机。之后对同一设备、同一 iOS 和 cloudOS 构建版本、同一预设和磁盘大小运行 `vm create` 时，会直接从该模板克隆，不再重新恢复。传入 `--no-template` 可单独构建虚拟机。

### 补丁与固件准备

固件流程只有一种模式。它为启动链和客户机系统打补丁，安装 vphoned，用户环境保持为空：不会安装 Sileo、apt、TrollStore、SSH 服务器或 VNC 服务器。补丁预设决定应用哪些补丁；`vphone-cli fw set-patches` 配合 `--block` 或 `--allow` 可以单独关闭或开启某个补丁。

打补丁之前，创建流程会先准备固件：一次临时的 cloudOS 恢复用于提供 GPU 驱动，不含 vphone600 组件的 cloudOS 需要重新构建 kernelcache。见[固件准备](../firmware/firmware-preparation.md)。要从一份列表创建多台虚拟机，请参阅[批量创建虚拟机](../storage/many-machines.md)。

## 启动与停止

```sh
vphone-cli vm launch myphone  # start the VM window and keep it running
vphone-cli vm stop myphone    # run from another terminal to stop it
```

`vm launch` 启动客户机时不等待 vphoned；该守护进程会在启动过程中连接。虚拟机窗口和菜单提供主屏幕键和电源键、App 安装和文件浏览。`vm launch --headless` 启动时不显示虚拟机窗口和菜单栏。

以下操作都会正常关闭客户机（vphoned `system.shutdown`）：

- 关闭虚拟机窗口
- ⌘Q
- `vm stop`
- 在运行 `vm launch` 的终端中按 Control-C

客户机停止后虚拟机即结束；如果 15 秒后仍未停止，也会结束。vphoned 无法代为响应的客户机（例如处于 DFU 或仍在启动中）会像拔掉电源一样立即关闭。再按一次 Control-C 会直接关闭，不再等待。

`vm stop` 只向虚拟机自己的进程发送信号，即 `vphone-vm` 和 Virtualization 的虚拟机服务。其他打开了磁盘的程序（例如正在计算磁盘大小的 Launchpad、聚焦或备份工具）会被列出名称，但不会被终止。

## 控制套接字

每台运行中的虚拟机在其文件夹中都有一个控制套接字 `vphone.sock`（`~/.vphone/machines/<name>/vphone.sock`）：输入一行 JSON，返回一行 JSON。多个连接可以同时处理；没有窗口的虚拟机也有这个套接字，此时 `tap` 和 `swipe` 通过 vphoned 的触摸注入实现，屏幕图像来自客户机。

除了 `tap`、`swipe`、`key` 和 `screenshot`，`rpc` 请求可以调用 [API 参考](../../../Research/vphoned_http_api.md)中的任何 vphoned 方法：

```sh
printf '%s\n' '{"t":"rpc","method":"device.info","params":{}}' | nc -U ~/.vphone/machines/myphone/vphone.sock
```

例如，`input.key` 配合 `{"name":"cmd+v"}` 可以粘贴，`input.type` 可以输入文本。这个流程不会安装 SSH 或 VNC 端点。需要 HTTP 和 WebSocket 访问时，请参阅[自动化 API](automation-api.md)。

## 手动运行各个阶段

排查问题或重复某个阶段时使用。`restore` 与虚拟机通信期间，要让 DFU 启动保持运行：

```sh
vphone-cli vm new myphone
vphone-cli fw prepare myphone \
  --iphone-source /path/to/iPhone17,3_Restore.ipsw \
  --cloudos-source /path/to/cloudOS.ipsw
vphone-cli fw patch myphone

vphone-cli vm launch myphone --dfu &
vphone-cli restore myphone
vphone-cli vm stop myphone

vphone-cli cfw install myphone
vphone-cli vm launch myphone
```

在线恢复会在进程内获取票据。离线恢复请参阅 `vphone-cli restore --help` 中的 `--get-shsh` 和 `--offline`。手动流程不会像 `vm create` 那样执行首次启动的 ping 检查。

## 另请参阅

- [模板](../storage/templates.md)
- [设备名称与时钟](device-name-and-clock.md)
- [资料库与备份](../storage/library-and-backups.md)
- [共享磁盘空间](../storage/sharing-disk-space.md)
