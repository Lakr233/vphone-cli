<div align="right"><strong><a href="./README_ko.md">🇰🇷한국어</a></strong> | <strong><a href="./README_ja.md">🇯🇵日本語</a></strong> | <strong>🇨🇳中文</strong> | <strong><a href="../README.md">🇬🇧English</a></strong></div>

# vphone-cli

通过 Apple 的 Virtualization.framework 使用 PCC 研究虚拟机基础设施引导虚拟 iPhone（iOS 26）。

![poc](./demo.jpeg)

## 测试环境

| 主机          | iPhone 系统           | CloudOS       |
| ------------- | --------------------- | ------------- |
| Mac16,12 26.3 | `17,3_26.1_23B85`     | `26.1-23B85`  |
| Mac16,12 26.3 | `17,3_26.3_23D127`    | `26.1-23B85`  |
| Mac16,12 26.3 | `17,3_26.3_23D127`    | `26.3-23D128` |
| Mac16,12 26.3 | `17,3_26.3.1_23D8133` | `26.3-23D128` |

## 固件变体

提供三种补丁变体，安全绕过级别逐步递增：

| 变体       |   启动链   | 自定义固件 | Make 目标                          |
| ---------- | :--------: | :--------: | ---------------------------------- |
| **常规版** | 41 个补丁  | 10 个阶段  | `fw_patch` + `cfw_install`         |
| **开发版** | 52 个补丁  | 12 个阶段  | `fw_patch_dev` + `cfw_install_dev` |
| **越狱版** | 112 个补丁 | 14 个阶段  | `fw_patch_jb` + `cfw_install_jb`   |

> 越狱最终配置（符号链接、Sileo、apt、TrollStore）通过 `/cores/vphone_jb_setup.sh` LaunchDaemon 在首次启动时自动运行。查看进度：`/var/log/vphone_jb_setup.log`。

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

- **方式 2：保持 SIP 大部分启用，仅禁用调试限制，使用 [`amfidont`](https://github.com/zqxwce/amfidont)**

  在恢复模式中：

  ```bash
  csrutil enable --without debug
  csrutil allow-research-guests enable
  ```

  重新启动回 macOS 后：

  ```bash
  xcrun python3 -m pip install amfidont
  sudo amfidont --path [PATH_TO_VPHONE_DIR]
  ```

**安装依赖：**

```bash
brew install ideviceinstaller wget gnu-tar openssl@3 ldid-procursus sshpass keystone autoconf automake pkg-config libtool cmake
```

**Submodules** —— 本仓库使用 git submodule 存储资源文件。克隆时请使用：

```bash
git clone --recurse-submodules https://github.com/Lakr233/vphone-cli.git
```

## 快速开始

```bash
make setup_machine            # 完全自动化完成"首次启动"流程（包含 restore/ramdisk/CFW）
# 选项：NONE_INTERACTIVE=1 SUDO_PASSWORD=...
```

## 手动设置

```bash
make setup_tools              # 安装 brew 依赖、构建 trustcache + libimobiledevice、创建 Python 虚拟环境
make build                    # 构建并签名 vphone-cli
make vm_new                   # 创建 vm/ 目录（ROM、磁盘、SEP 存储）
make fw_prepare               # 下载 IPSWs，提取、合并、生成 manifest
make fw_patch                 # 修补启动链（常规变体）
# 或：make fw_patch_dev       # 开发变体（+ TXM 权限/调试绕过）
# 或：make fw_patch_jb        # 越狱变体（+ 完整安全绕过）
```

## 恢复过程

该过程需要 **两个终端**。保持终端 1 运行，同时在终端 2 操作。

```bash
# 终端 1
make boot_dfu                 # 以 DFU 模式启动 VM（保持运行）
```

```bash
# 终端 2
make restore_get_shsh         # 获取 SHSH blob
make restore                  # 通过 idevicerestore 刷写固件
```

## 安装自定义固件

在终端 1 中停止 DFU 引导（Ctrl+C），然后再次进入 DFU，用于 ramdisk：

```bash
# 终端 1
make boot_dfu                 # 保持运行
```

```bash
# 终端 2
sudo make ramdisk_build       # 构建签名的 SSH ramdisk
make ramdisk_send             # 发送到设备
```

当 ramdisk 运行后（输出中应显示 `Running server`），打开**第三个终端**运行 iproxy 隧道，然后在终端 2 安装 CFW：

```bash
# 终端 3 —— 保持运行
iproxy 2222 22
```

```bash
# 终端 2
make cfw_install
# 或：make cfw_install_jb        # 越狱变体
```

## 首次启动

在终端 1 中停止 DFU 引导（Ctrl+C），然后：

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

在另一个终端中启动 iproxy 隧道：

```bash
iproxy 22222 22222   # SSH（dropbear）
iproxy 2222 22       # SSH（越狱版：在 Sileo 中安装 openssh-server 后）
iproxy 5901 5901     # VNC
iproxy 5910 5910     # RPC
```

连接方式：

- **SSH（越狱版）：** `ssh -p 2222 mobile@127.0.0.1`（密码：`alpine`）
- **SSH（常规版/开发版）：** `ssh -p 2222 root@127.0.0.1`（密码：`alpine`）
- **VNC：** `vnc://127.0.0.1:5901`
- [**RPC：**](http://github.com/doronz88/rpc-project) `rpcclient -p 5910 127.0.0.1`

## 常见问题（FAQ）

> **在做其他任何事情之前——先运行 `git pull` 确保你有最新版。**

**问：运行时出现 `zsh: killed ./vphone-cli`。**

AMFI/调试限制未正确绕过。选择以下任一方式：

- **方式 1（完全禁用 AMFI）：**

  ```bash
  sudo nvram boot-args="amfi_get_out_of_my_way=1 -v"
  ```

- **方式 2（仅禁用调试限制）：**
  在恢复模式中使用 `csrutil enable --without debug`（不完全禁用 SIP），然后安装/加载 [`amfidont`](https://github.com/zqxwce/amfidont)，保持 AMFI 其他功能不变。

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

## 致谢

- [wh1te4ever/super-tart-vphone-writeup](https://github.com/wh1te4ever/super-tart-vphone-writeup)
