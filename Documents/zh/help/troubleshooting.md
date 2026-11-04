# 故障排查

找到你看到的症状或错误信息，然后按照其下方的方法处理。网络问题请参阅[网络](../networking/overview.md)。

## `vphone-vm` 在虚拟机打开前被终止

1. 运行宿主机预检：

   ```sh
   vphone-cli host preflight
   ```

   CLI 不带授权，因此它会继续运行，并能说明 AMFI 为何拒绝与它配套的已签名 `vphone-vm`。
2. 如果你重新构建了 bundle，cdhash 就会改变。请按照[宿主机设置](../get-started/host-setup.md)中的说明，用 bundle 自带的辅助程序允许新的二进制文件。

## `Virtualization is not available on this hardware`

PV=3 客户机不能嵌套运行。请在 Apple Silicon Mac 上直接启动，而不是在另一个 macOS 虚拟机中。

## `vm create` 打印了 vphoned 成功信息，但没有虚拟机在运行

这是正常的。创建流程会临时以图形界面启动一次，发送一次真实的 ping，并在返回前停止这次启动。要使用虚拟机，请启动它：

```sh
vphone-cli vm launch <name>
```

## 停在“Press home to continue”

点击虚拟机窗口标题栏中的主屏幕按钮。当前的 JB 流程不会安装 VNC 服务器。

## App 因 `EXC_GUARD` / `GUARD_TYPE_MACH_PORT` 退出

内核补丁 `kernel-boot-thread_guard_violation` 会阻止致命的 Mach 端口守卫投递。它只适用于 iOS 18 基础系统，因为在这类系统上启动需要它，所有预设都会在这类系统上开启它。其他基础系统无法选择这个补丁，因此在 26.x 基础系统上触发这个守卫的 App 仍会退出。见 [issue #291](https://github.com/Lakr233/vphone-cli/issues/291)。

## 恢复或首次启动失败

- 在手动流程中，让虚拟机保持在 DFU 模式，直到 `restore` 退出。
- 确认在线票据请求能够访问 Apple。
- 对于完整流程，请用一个**新名称**并加上 `-v` 重新运行 `vm create`，以获取工具的详细输出。
- 内存或磁盘紧张时，避免同时创建多台虚拟机。
- 把 iPhone IPSW 与 PCC 映像组合使用之前，请查看[固件兼容性](../firmware/compatibility.md)。

## 客户机已启动，但 vphoned 在创建期间没有响应

首次启动检查会在 300 秒后超时。创建流程使用图形界面启动，因为新恢复的客户机在首次无界面启动时可能不会启动 vphoned。成功标记能证明什么，请参阅[创建与运行](../machines/create-and-run.md)。

## 另请参阅

- [宿主机设置](../get-started/host-setup.md)
- [创建与运行](../machines/create-and-run.md)
- [固件兼容性](../firmware/compatibility.md)
