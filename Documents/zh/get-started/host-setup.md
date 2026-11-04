# 宿主机设置

让 Mac 能够运行带授权的虚拟机进程 `vphone-vm`。每台 Mac 只需设置一次；每当 `vphone-vm` 的签名发生变化，都要重复允许列表这一步。

你需要一台运行 macOS 15 或更新版本的 Apple Silicon Mac。PV=3 研究客户机无法在嵌套的 macOS 虚拟机中运行。

## 检查宿主机

使用你所用 `VPhone.bundle` 中的程序运行预检：

```sh
vphone-cli host preflight
```

它会在任何虚拟机启动前检查带授权的 `vphone-vm`。如果 AMFI 拒绝 `vphone-vm`，错误信息会打印出针对该 bundle 的完整命令 `sudo .../vphone-escalator allow .../vphone-vm`。

## 选择安全配置

`vphone-vm` 带有 Apple 私有的虚拟化授权，因此 macOS 必须接受它。下面两种方式都需要在恢复环境中启用 Research Guests（研究客户机）。二选一即可。

### 方式 A：保持 SIP 启用，放宽调试限制

1. 启动进入 macOS 恢复，打开终端，运行：

   ```sh
   csrutil enable --without debug
   csrutil allow-research-guests enable
   ```

2. 重新启动进入 macOS。
3. 把当前的 `vphone-vm` 加入允许列表。使用发布版 bundle 时，运行 `vphone-cli host preflight`，再运行它打印出的命令。使用源码检出时：

   ```sh
   bundle=.build/XcodeBundle/Build/Products/Debug/VPhone.bundle
   sudo "$bundle/Contents/MacOS/vphone-escalator" allow "$bundle/Contents/MacOS/vphone-vm"
   "$bundle/Contents/MacOS/vphone-escalator" status
   "$bundle/Contents/MacOS/vphone-cli" host preflight
   ```

> [!WARNING]
> 每次构建后都要重新运行 `allow` 命令，包括只改变了签名的重新构建。允许列表记录的是 `vphone-vm` 的 cdhash，新的签名会产生新的 cdhash。

撤销允许列表：

```sh
sudo "$bundle/Contents/MacOS/vphone-escalator" off
```

`off` 只移除 `vphone-escalator` 添加的哈希，并重启 amfid。偏好设置及其中的其他值会保留。

如果其他已签名的宿主机程序需要受限授权，也可以把它们一并传给同一条 `allow` 命令。不带授权的 `vphone-cli` 不需要这样做。

### 方式 B：停用 SIP 和 AMFI

这是限制更宽松的配置。

1. 启动进入 macOS 恢复，打开终端，运行：

   ```sh
   csrutil disable
   csrutil allow-research-guests enable
   ```

2. 重新启动进入 macOS，设置启动参数，然后再次重新启动：

   ```sh
   sudo nvram boot-args="amfi_get_out_of_my_way=1 -v"
   ```

> [!WARNING]
> 这会覆盖现有的 `boot-args`。请先用 `nvram boot-args` 查看。

## 使用 Launchpad 时

Launchpad 的 bundle 预检会确认 SIP 调试限制已停用（或 SIP 已完全停用），并且 Research Guests 已启用。你不需要自己运行 `vphone-escalator`：

- 如果 AMFI 阻止已安装的 `vphone-vm`，Launchpad 的辅助程序会再次检查这些宿主机设置，验证 root 拥有的 bundle 及其记录的 cdhash，以 root 身份运行该 bundle 的 `vphone-escalator allow`，然后 Launchpad 重新预检。
- 每个新的 bundle 签名都会单独检查和允许。
- 当新版 Launchpad 带有新版辅助程序时，它会在启动时请求管理员授权以更新辅助程序。

独立使用的 `vphone-cli` 仍会报告需要手动运行的命令。

## 从源码构建

发布版 `VPhone.bundle` 在运行时不需要 Homebrew、Python 或 Xcode。从源码构建需要 Xcode 及其 iPhoneOS SDK，用于编译 `vphoned`。在源码目录中运行：

```sh
xcodebuild -workspace VPhone.xcworkspace -scheme VPhone \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/XcodeBundle build
.build/XcodeBundle/Build/Products/Debug/VPhone.bundle/Contents/MacOS/vphone-cli host preflight
```

`VPhone` scheme 会生成包含全部程序的 ad hoc 签名 bundle。使用方式 A 时，每次新构建都要加入允许列表。

## 允许列表改动了什么

`vphone-escalator allow` 会在 AMFI 代码要求偏好设置不存在时创建它。如果已经存在，就把当前 `vphone-vm` 的 cdhash 追加到其中的 `Entitlements` 要求里，保留其他 cdhash 和偏好设置键，并跳过已有的哈希。它不改动现有的 `AllowUnsafeDynamicLinking` 值，只在该键不存在时写入 `false`。它通过修改 amfid 堆中的一个字节，让 amfid 参考这项要求。

## bundle 包含的内容

- `vphone-cli` 在没有私有授权的情况下协调各项工作，并通过 `vphone-cli archive` 处理归档。
- `vphone-vm` 是已签名、带授权的虚拟机和窗口进程。
- `vphoned` 在构建时为 iOS 编译，并安装到每个新建的客户机中。

实现历史见[关于程序拆分的研究记录](../../../Research/Host/host_binary_split.md)。

## 另请参阅

- [快速开始](quick-start.md)
- [创建与运行虚拟机](../machines/create-and-run.md)
- [故障排查](../help/troubleshooting.md)
