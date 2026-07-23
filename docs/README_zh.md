<div align="right"><strong><a href="./README_ko.md">🇰🇷한국어</a></strong> | <strong><a href="./README_ja.md">🇯🇵日本語</a></strong> | <strong>🇨🇳中文</strong> | <strong><a href="../README.md">🇬🇧English</a></strong></div>

# vphone-cli

通过 Apple 的 Virtualization.framework 使用 PCC 研究虚拟机基础设施引导虚拟 iPhone。

![poc](./demo.jpeg)

## 测试环境

| 主机          | iPhone 系统           | CloudOS         |
| --------------- | --------------------- | --------------- |
| Mac16,11 27.0b2 | `17,3_18.6.2_22G100`  | `26.1-23B85`    |
| Mac16,8 26.5.1  | `17,3_26.0_23A341`    | `26.1-23B85`    |
| Mac16,8 26.5.1  | `17,3_26.0.1_23A355`  | `26.1-23B85`    |
| Mac16,12 26.3   | `17,3_26.1_23B85`     | `26.1-23B85`    |
| Mac16,12 26.3   | `17,3_26.3_23D127`    | `26.1-23B85`    |
| Mac16,12 26.3   | `17,3_26.3_23D127`    | `26.3-23D128`   |
| Mac16,12 26.3   | `17,3_26.3.1_23D8133` | `26.3-23D128`   |
| Mac16,11 26.2   | `17,3_26.4_23E246`    | `26.4-23E5207q` |
| Mac16,11 26.2   | `17,3_26.5_23F77`     | `26.4-23E5207q` |
| Mac16,11 27.0b2 | `17,3_26.5.2_23F84`   | `26.4-23E5207q` |
| Mac16,6 25.4.1  | `17,3_26.6_23G71`     | `26.4-23E5207q` |
| Mac16,11 27.0b2 | `17,3_27.0_24A5380h`  | `26.4-23E5207q` |
| Mac16,6 25.4.1  | `17,3_27.0_24A5390f`  | `26.4-23E5207q` |

iOS 27.0 使用 26.4 PCC vphone600 栈，并额外应用 CFW 阶段的 force-kern `IOMobileFramebuffer` present-path 补丁与 dyld 共享缓存 `maxSlide` 适配。

**注意：** iOS 18.x 上 Metal/GPU 加速无法工作——18.x 的 Metal/IOGPU 框架缺少半虚拟化 GPU 实现，因此由 Metal 渲染的内容（网页、图片、壁纸）无法显示。触摸、网络和应用可正常使用。

## 固件变体

提供五种补丁变体，安全绕过级别逐步递增：

| 变体           | 启动链           | 自定义固件 | Make 目标                                   |
| -------------- | :--------------: | :--------: | ------------------------------------------- |
| **Patchless**  | 4 个补丁         | 2 个阶段   | `fw_patch_less` + `boot_less`              |
| **常规版**     | 42 个补丁        | 10 个阶段  | `fw_patch` + `cfw_install`                  |
| **开发版**     | 53 个补丁        | 12 个阶段  | `fw_patch_dev` + `cfw_install_dev`          |
| **越狱版**     | 113 个补丁       | 14 个阶段  | `fw_patch_jb` + `cfw_install_jb`            |
| **实验版**     | 越狱 + EXP 专属  | 越狱 + EXP | `fw_patch_exp` + `cfw_install_exp`          |

> 越狱最终配置（符号链接、Sileo、apt、TrollStore）通过 `/cores/vphone_jb_setup.sh` LaunchDaemon 在首次启动时自动运行。查看进度：`/var/log/vphone_jb_setup.log`。

> **实验版（EXP）** 是越狱版的超集，额外运行研究分支中的实验性补丁：内核 `hv_vmm_present` sysctl 重命名 + 内核内部调用者改写（`KernelEXPPatcher`）、带登录黑名单的 DSC 字节 5 改写 + slot 重新认证、watchdogd 精准 2 条指令补丁（EXP-JB-3.5）、固件补丁阶段的 8 项 DeviceTree 身份属性、还原后 DT 身份重写（EXP-JB-6）、以及通过 `SPOOF_BUILD=<id>` 可选启用的 `SystemVersion.plist` `ProductBuildVersion` 改写（EXP-JB-7）。其他变体不受影响。

详见 [research/0_binary_patch_comparison.md](../research/0_binary_patch_comparison.md) 了解各组件的详细分项对比。

## 先决条件

**主机系统：** PV=3 虚拟化要求 macOS 15+（Sequoia）。

**配置 SIP/AMFI** —— 需要私有的 Virtualization.framework 权限和未签名二进制文件工作流。

重启到恢复模式（长按电源键），打开终端，选择以下任一设置方式：

- **方式 1：完全禁用 SIP + AMFI boot-arg（最宽松）**

  在恢复模式中：

  ```bash
  csrutil disable
  csrutil allow-research-guests enable
  ```

  重新启动回 macOS 后：

  ```bash
  sudo nvram boot-args="amfi_get_out_of_my_way=1 -v"
  ```

  再重启一次。

- **方式 2：保持 SIP 大部分启用，仅禁用调试限制，使用 [`amfidont`](https://github.com/zqxwce/amfidont) 或 [`amfree`](https://github.com/retX0/amfree)**

  在恢复模式中：

  ```bash
  csrutil enable --without debug
  csrutil allow-research-guests enable
  ```

  重新启动回 macOS 后：

  ```bash
  # 使用 amfidont：
  xcrun python3 -m pip install amfidont
  sudo amfidont --path [PATH_TO_VPHONE_DIR]
  
  # 或使用 amfree：
  brew install retX0/tap/amfree
  sudo amfree --path [PATH_TO_VPHONE_DIR]
  ```

  在本仓库中，可以运行 `make amfidont_allow_vphone` 一次性配置
  `amfidont` 所需的编码路径与 CDHash 允许项。

> Patchless 变体要求使用方式 1，或带 `-S` 参数的 amfidont（`sudo amfidont -S --path [PATH_TO_VPHONE_DIR]`）。

**安装依赖：**

```bash
brew install aria2 wget gnu-tar openssl@3 ldid-procursus sshpass keystone libusb ipsw zstd
```

`scripts/fw_prepare.sh` 会优先使用 `aria2c` 进行更快的多连接下载，必要时再回退到 `curl` 或 `wget`。

**Submodules** —— 本仓库通过 git submodule 管理资源、Swift 依赖以及 `scripts/repos/` 下的工具链源码。克隆时请使用：

```bash
git clone --recurse-submodules https://github.com/Lakr233/vphone-cli.git
```

## 快速开始

```bash
make setup_machine            # 完全自动化完成"首次启动"流程（包含 restore/CFW）
# 选项：NON_INTERACTIVE=1 SUDO_PASSWORD=...
# LESS=1 patchless 变体（- AMFI、SSV、Img4、TXM 绕过）
# DEV=1 开发变体（+ TXM 权限/调试绕过）
# JB=1 越狱变体（dev + 完整安全绕过）
# EXP=1 实验变体（越狱 + 研究补丁：hv_vmm 重命名、DT 身份、还原后重写）
# SPOOF_BUILD=<id> （仅 EXP）将 SystemVersion.plist 的 ProductBuildVersion 改写为 <id>，例如 23F77
```

## 手动设置

```bash
make setup_tools              # 安装 brew 依赖，构建 trustcache + insert_dylib，创建 Python 虚拟环境（含 pymobiledevice3/aria2c）
make build                    # 构建并签名 vphone-cli
make vm_new                   # 创建 VM 目录及清单文件（config.plist）
# 选项：CPU=8 MEMORY=8192 DISK_SIZE=64
make fw_prepare               # 下载 IPSWs，提取、合并、生成 manifest
make fw_patch                 # 修补启动链（常规变体）
# 或：sudo make fw_patch_less # patchless 变体（- AMFI、SSV、Img4、TXM 绕过）
# 或：make fw_patch_dev       # 开发变体（+ TXM 权限/调试绕过）
# 或：make fw_patch_jb        # 越狱变体（dev + 完整安全绕过）
# 或：make fw_patch_exp       # 实验变体（越狱 + 研究补丁栈）
```

### 清理

```bash
make clean                    # 仅删除构建/工具链产物
make clean CLEAN_VM=1         # 确认后同时删除 vm/
make clean CLEAN_IPSW=1       # 确认后同时删除 ipsws/
```

默认清理不会删除 `vm/` 或 `ipsws/`。

### VM 配置

从 v1.0 开始，VM 配置存储在 `vm/config.plist` 中。在创建 VM 时设置 CPU、内存和磁盘大小：

```bash
# 使用自定义配置创建 VM
make vm_new CPU=16 MEMORY=16384 DISK_SIZE=128

# 启动时自动从 config.plist 读取配置
make boot
```

清单文件存储所有 VM 设置（CPU、内存、屏幕、ROM、存储），并与 [security-pcc 的 VMBundle.Config 格式](https://github.com/apple/security-pcc)兼容。

## 恢复过程

该过程需要 **两个终端**。保持终端 1 运行，同时在终端 2 操作。

```bash
# 终端 1
make boot_dfu                 # 以 DFU 模式启动 VM（保持运行）
```

```bash
# 终端 2
make restore_get_shsh         # 获取 SHSH blob
make restore                  # 通过 pymobiledevice3 restore 后端刷写固件
# 或：make restore_offline    # 离线恢复（就地解密 AEA 镜像，并使用缓存的 .shsh blob）
                              # 首次运行需要联网以完成 AEA 解密
```

## 安装自定义固件

恢复完成后，在终端 1 中停止 DFU 引导（Ctrl+C），使 VM 完全关机。安装程序会在主机上挂载 VM 的 `Disk.img`，放置所有 CFW 文件，并离线切换启动快照（无需 DFU / ramdisk / SSH），因此需要对磁盘的独占访问。

```bash
# 终端 2（会自动通过 sudo 重新执行）
make cfw_install
# 或：make cfw_install_dev       # 开发变体
# 或：make cfw_install_jb        # 越狱变体
# 或：make cfw_install_exp       # 实验变体（越狱 + 研究补丁栈）
# 或：SPOOF_BUILD=23F77 make cfw_install_exp   # 同时改写 ProductBuildVersion
# 或：FORCE_DSC_MAXSLIDE=1 make cfw_install    # 在非 27 基础版本上强制 DSC maxSlide=0（所有变体；27 会自动执行）
```

## 首次启动

停止 DFU 引导并完成 CFW 安装后，正常启动 VM：

```bash
make boot
```

执行 `cfw_install_jb` 后，越狱变体在首次启动时将提供 **Sileo** 和 **TrollStore**。你可以使用 Sileo 安装 `openssh-server` 以获得 SSH 访问。

对于常规版/开发版，VM 会提供**直接控制台**。当看到 `bash-4.4#` 时，按回车并运行以下命令以初始化 shell 环境并生成 SSH 主机密钥：

```bash
export PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/bin/X11:/usr/games:/iosbinpack64/usr/local/sbin:/iosbinpack64/usr/local/bin:/iosbinpack64/usr/sbin:/iosbinpack64/usr/bin:/iosbinpack64/sbin:/iosbinpack64/bin'

mkdir -p /var/dropbear
cp /iosbinpack64/etc/profile /var/profile
cp /iosbinpack64/etc/motd /var/motd

# 生成 SSH 主机密钥（SSH 能正常工作所必需）
dropbearkey -t rsa -f /var/dropbear/dropbear_rsa_host_key
dropbearkey -t ecdsa -f /var/dropbear/dropbear_ecdsa_host_key

shutdown -h now
```

> **注意：** 若不执行主机密钥生成步骤，dropbear（SSH 服务器）会接受连接但立刻关闭，因为它没有密钥进行握手。

## 后续启动

```bash
make boot
```

在另一个终端中启动 usbmux 转发隧道：

```bash
python3 -m pymobiledevice3 usbmux forward 2222 22222    # SSH（dropbear）
python3 -m pymobiledevice3 usbmux forward 2222 22       # SSH（越狱版：在 Sileo 中安装 openssh-server 后）
python3 -m pymobiledevice3 usbmux forward 5901 5901     # VNC
python3 -m pymobiledevice3 usbmux forward 5910 5910     # RPC
```

连接方式：

- **SSH（越狱版）：** `ssh -p 2222 mobile@127.0.0.1`（密码：`alpine`）
- **SSH（常规版/开发版）：** `ssh -p 2222 root@127.0.0.1`（密码：`alpine`）
- **VNC：** `vnc://127.0.0.1:5901`
- [**RPC：**](http://github.com/doronz88/rpc-project) `rpcclient -p 5910 127.0.0.1`

## VM 备份与切换

保存并切换多个 VM 环境（例如不同的 iOS 构建版本或固件变体）。备份存储在 `vm.backups/` 下，使用 `rsync --sparse` 高效处理稀疏磁盘镜像。

```bash
make vm_backup NAME=26.1-clean    # 保存当前 VM
rm -rf vm && make vm_new          # 清空后从新构建开始
# ... fw_prepare, fw_patch, restore, cfw_install, boot
make vm_backup NAME=26.3-jb       # 保存新的 VM
make vm_list                      # 列出所有备份
make vm_switch NAME=26.1-clean    # 在不同备份之间切换
```

> **注意：** 备份/切换/恢复前请先停止 VM。

## 常见问题（FAQ）

> **在做其他任何事情之前——先运行 `git pull` 确保你有最新版。**

**问：运行时出现 `zsh: killed ./vphone-cli`。**

AMFI/调试限制未正确绕过。选择以下任一方式：

- **方式 1（完全禁用 AMFI）：**

  ```bash
  sudo nvram boot-args="amfi_get_out_of_my_way=1 -v"
  ```

- **方式 2（仅禁用调试限制）：**
  在恢复模式中使用 `csrutil enable --without debug`（不完全禁用 SIP），然后安装/加载 [`amfidont`](https://github.com/zqxwce/amfidont) 或 [`amfree`](https://github.com/retX0/amfree)，保持 AMFI 其他功能不变。
  在本仓库中，也可通过 `make amfidont_allow_vphone` 自动写入 `amfidont` 所需的编码路径与 CDHash 允许配置。

**问：`make boot` / `make boot_dfu` 启动后报错 `VZErrorDomain Code=2 "Virtualization is not available on this hardware."`。**

这是因为宿主机本身运行在 Apple 虚拟机中，无法再进行嵌套 Virtualization.framework 来启动 guest。请在非嵌套的 macOS 15+ 主机上运行。可用 `make boot_host_preflight` 检查，若显示 `Model Name: Apple Virtual Machine 1` 和 `kern.hv_vmm_present=1` 即为该情况。当前版本会在此类宿主机上通过 `boot_binary_check` 在启动前快速失败。

**问：系统应用（App Store、信息等）无法下载或安装。**

在 iOS 初始设置过程中，请**不要**选择**日本**或**欧盟地区**作为你的国家/地区。这些地区要求额外的合规检查（如侧载披露、相机快门声等），虚拟机无法满足这些要求，因此系统应用无法正常下载安装。请选择其他地区（例如美国）以避免此问题。

**问：卡在"Press home to continue"屏幕。**

通过 VNC (`vnc://127.0.0.1:5901`) 连接，并在屏幕上右键单击任意位置（在 Mac 触控板上双指点击）。这会模拟 Home 按钮按下。

**问：如何获得 SSH 访问？**

从 Sileo 安装 `openssh-server`（越狱变体首次启动后可用）。

**问：安装 openssh-server 后 SSH 无法使用。**

重启虚拟机。SSH 服务器将在下次启动时自动启动。

**问：可以安装 `.tipa` 文件吗？**

可以。安装菜单同时支持 `.ipa` 和 `.tipa` 包。拖放或使用文件选择器即可。

**问：可以升级到更新的 iOS 版本吗？**

可以。使用你想要的版本的 IPSW URL 覆盖 `fw_prepare`：

```bash
export IPHONE_SOURCE=/path/to/some_os.ipsw
export CLOUDOS_SOURCE=/path/to/some_os.ipsw
make fw_prepare
make fw_patch
```

我们的补丁是通过二进制分析（binary analysis）而非静态偏移（static offsets）应用的，因此更新的版本应该也能正常工作。如果出现问题，可以寻求 AI 的帮助。

**问：使用 `restore_offline` 后卡在设置界面。**

设备在设置过程中会尝试连接 Apple，如果你使用了 `restore_offline`，很可能当前没有联网。
你可以将设备设为 supervised，以绕过大部分设置界面：

```bash
python3 -m pymobiledevice3 profile supervise vphone
```

## 致谢

- [wh1te4ever/super-tart-vphone-writeup](https://github.com/wh1te4ever/super-tart-vphone-writeup)
