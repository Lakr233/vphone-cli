# VPhone bundle 集成

如果你开发的应用程序需要分发或驱动 `VPhone.bundle`（就像 `vphone-launchpad` 那样），请阅读本页。本页介绍 bundle 包含哪些内容，以及集成它的应用程序需要负责哪些工作。

## 构建与验证

```sh
xcodebuild -workspace VPhone.xcworkspace -scheme VPhone \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/XcodeBundle build
```

`VPhone` scheme 会生成 `VPhone.bundle`，`ValidateBundle.sh` 会在构建过程中检查它。

## 如何集成

- 保持 bundle 完整，以进程方式启动 `Contents/MacOS/vphone-cli`。bundle 是可执行文件和资源的容器，不是 macOS App，也不是动态载入的插件。CLI 通过解析自己的可执行文件路径来找到与它配套的 `vphone-vm`。
- 把整个 bundle 作为一个带版本的单元来安装和更新。不要原地改写已签名的二进制文件。
- `vphone-vm` 改变时，它的 cdhash 也会改变。启动新构建之前，请先为它安排 AMFI 准入。
- 下载、版本验证、宿主机授权、安装和更新策略都由你的应用程序负责。开发者工具权限和 AMFI 授权是宿主机上两项独立的决定。
- 虚拟机资料库和缓存位于 `VPhone.bundle` 之外，默认在 `~/.vphone` 下。宿主机上的虚拟机输出使用 `0777` 权限，以便独立的工作站进程访问，包括以 root 身份创建之后。`Disk.img` 内客户机文件系统的权限保持其自身的语义。

## bundle 内容

| 路径 | 作用 |
| --- | --- |
| `Contents/MacOS/vphone-cli` | 不带授权的命令入口 |
| `Contents/MacOS/vphone-vm` | 虚拟机和窗口进程；带有私有虚拟化授权 |
| `Contents/MacOS/vphone-escalator` | 针对当前虚拟机 cdhash 的 AMFI 允许列表工具 |
| `Contents/MacOS/libswiftCompatibilitySpan.vphone.dylib` | `vphone-vm` 在 macOS 15 上使用的 Swift 向后部署库 |
| `Contents/Resources/guest-resources/vphoned` | 预先签名、带有自己授权的客户机守护进程；bundle 中没有未签名的副本 |
| `Contents/Resources/guest-resources/*.dylib` | 客户机库：launchd hook、SystemHook、相机 hook、GPU 编译器插件，以及 [`VPhoneGuestComponents`](../../../VPhoneGuestComponents/README.md) 中列出的修复和设备适配 |
| `Contents/Resources/guest-resources/*.plist` | 客户机启动守护进程配置、相机 hook 和 MISFix 过滤规则 |
| `Contents/Resources` | 本地化字符串；不附带签名脚本或授权文件 |

`Contents/MacOS` 只包含在 Mac 上运行的程序。`guest-resources` 只包含安装到客户机中的文件，其中每个 Mach-O 都是为 iOS 构建的。`ValidateBundle.sh` 会强制执行这两条规则。

## 签名

所有可执行内容都使用 ad hoc 代码签名。只有需要私有授权的子进程才带有私有授权。bundle 没有 `CFBundleExecutable`、App 启动器、SMJobBless 辅助程序、安装器、密码提示，也不会自动获取 root 权限。

## 隐私权限

macOS 会代表负责进程请求隐私权限（麦克风、定位），并把授权与该进程的代码签名绑定。

- 如果你在放弃责任的情况下启动 `vphone-cli`，它就会成为 `vphone-vm` 的负责进程。它是 ad hoc 签名的，因此每个新的 bundle 构建都会再次请求权限。
- 如果你把 `vphone-cli` 作为签名稳定的进程的普通子进程启动，且不放弃责任，权限只会请求一次。

Launchpad 采用第二种方式，使用它自己 `Contents/MacOS` 中的 `vphone-launchpad-launcher`。macOS 会把那里的工具归属到外层 App，因此提示、用途说明和授权都属于该 App。在强化运行时下，App 的主可执行文件必须带有对应的资源授权（`com.apple.security.device.audio-input`、`com.apple.security.personal-information.location`）；否则 macOS 会直接拒绝请求，不会询问用户。

## 版本兼容性

Launchpad 会拒绝早于 `minimumBundleComponents`（在 [`VPhoneLaunchpad/VPhoneLaunchpadShared/VPhoneLaunchpadBundleStore.swift`](../../../VPhoneLaunchpad/VPhoneLaunchpadShared/VPhoneLaunchpadBundleStore.swift) 中设置）的 bundle，也不会载入旧的 bundle 布局。bundle 2.1.0 加入了补丁预设（`fw patches`、`fw set-patches`、`fw patch --preset`）和 `vphone-escalator` 可执行文件。

## 另请参阅

- [Core Bundle 与本地构建](core-bundles.md)
- [Launchpad 命令行](launchpad-cli.md)
- [宿主机设置](../get-started/host-setup.md)
