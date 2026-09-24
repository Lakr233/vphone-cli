<div align="right"><a href="../README.md">English</a> · <strong>中文</strong> · <a href="README_ja.md">日本語</a> · <a href="README_ko.md">한국어</a></div>

# vphone-cli

用 Apple Virtualization.framework 和 PCC 研究虚拟机基础设施启动虚拟 iPhone。

![运行中的虚拟 iPhone](demo.jpeg)

目前公开的固件流程**只有 JB 一种**：打齐必要的系统补丁并安装 vphoned，方便宿主机控制。访客用户环境保持空白；本项目不会安装 Sileo、apt、TrollStore、SSH、VNC 或首次启动 bootstrap。

## 快速开始

需要 Apple Silicon Mac、macOS 15 或更新版本，以及允许 PV=3 研究虚拟机和 `vphone-vm` 私有授权的宿主机设置。先看[宿主机准备](guides/host-setup.md)。

```sh
vphone-cli vm create myphone \
  --iphone-source /path/to/iPhone17,3_Restore.ipsw \
  --cloudos-source /path/to/cloudOS.ipsw

vphone-cli vm launch myphone
```

`vm create` 会完成固件准备、JB 补丁、DFU 恢复、CFW 安装，并在首次启动时真正 ping 一次 vphoned。**验收成功后，它会关闭这次临时启动**；要继续使用，请再执行 `vm launch`。恢复阶段需要网络，CFW 安装需要管理员认证。两个 VM 请依次创建，避免磁盘与内存占用叠加。

已用 cloudOS 26.4（`23E5207q`）验证 iPhone17,3 的 iOS 26.6.2（`23G90`）和 27.0（`24A435`）：两者都到达锁屏并收到 vphoned ping。其他组合请看[兼容性记录](guides/compatibility.md)，不要把它们视为已完成同等验收。

## 安装与构建

成品 `.app` 运行时不需要 Homebrew、Python 或 Xcode，也不需要额外安装运行环境。从源码构建则需要 Xcode 的 iPhoneOS SDK，以编译 vphoned：

```sh
git clone --recurse-submodules https://github.com/Lakr233/vphone-cli.git
cd vphone-cli
zsh Scripts/build.sh
.build/release/vphone-cli host preflight
```

采用 AMFI 白名单的宿主机，每次重编译后都要按[宿主机准备](guides/host-setup.md)中的步骤重新允许签名后的 VM 程序。

## 常用命令

| 操作 | 命令 |
| --- | --- |
| 列出虚拟机 | `vphone-cli vm list` |
| 启动窗口 | `vphone-cli vm launch myphone` |
| 停止虚拟机 | `vphone-cli vm stop myphone` |
| 导出备份 | `vphone-cli vm export myphone --out myphone.tzst` |
| 导入备份 | `vphone-cli vm import myphone.tzst --name restored` |
| 查看固件配对 | `vphone-cli fw catalog` |

虚拟机和固件缓存默认位于 `~/.vphone/`。完整步骤、手动流水线和存储路径见[创建与运行指南](guides/create-and-run.md)。[文档目录](README.md)汇总其余指南；[研究目录](../research/README.md)收录补丁与实现记录。详细指南目前以英文为准。
