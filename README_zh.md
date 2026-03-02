# vphone-cli（中文版）

通过 Apple 的 Virtualization.framework 使用 PCC 研究虚拟机基础设施引导虚拟 iPhone（iOS 26）。

![poc](./demo.png)

## 测试环境

| 主机 | iPhone 系统 | CloudOS |
|------|-------------|---------|
| Mac16,12 26.3 | `17,3_26.1_23B85` | `26.1-23B85` |
| Mac16,12 26.3 | `17,3_26.3_23D127` | `26.1-23B85` |
| Mac16,12 26.3 | `17,3_26.3_23D127` | `26.3-23D128` |

## 先决条件

**禁用 SIP 和 AMFI** —— 需要私有的 Virtualization.framework 权限。

重启到恢复模式（长按电源键），打开终端：

```bash
csrutil disable
csrutil allow-research-guests enable
```

重新启动回 macOS 后：

```bash
sudo nvram boot-args="amfi_get_out_of_my_way=1 -v"
```

再重启一次。

**安装依赖：**

```bash
brew install gnu-tar sshpass keystone autoconf automake pkg-config libtool
```

## 第一次设置

```bash
make setup_machine            # 完全自动化完成“首次启动”流程（包含 restore/ramdisk/CFW）

# 等价的手动步骤：
make setup_libimobiledevice   # 构建 libimobiledevice 工具链
make setup_venv               # 创建 Python 虚拟环境
source .venv/bin/activate
```

`make setup_machine` 仍然要求手动在恢复模式下配置 SIP/research-guest，并在其打印的首次启动命令中使用交互式 VM 控制台。脚本不会验证这些安全设置。

## 快速开始

```bash
make build                    # 构建并签名 vphone-cli
make vm_new                   # 创建 vm/ 目录（ROM、磁盘、SEP 存储）
make fw_prepare               # 下载 IPSWs，提取、合并、生成 manifest
make fw_patch                 # 修补启动链（6 个组件，41+ 处修改）
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

## Ramdisk 与 CFW

在终端 1 中停止 DFU 引导（Ctrl+C），然后再次进入 DFU，用于 ramdisk：

```bash
# 终端 1
make boot_dfu                 # 保持运行
```

```bash
# 终端 2
make ramdisk_build            # 构建签名的 SSH ramdisk
make ramdisk_send             # 发送到设备
```

连接成功后，安装 CFW：

```bash
# 终端 2
iproxy 2222 22
make cfw_install
```

## 首次启动

在终端 1 中停止 DFU 引导（Ctrl+C），然后：

```bash
make boot
```

这会为你提供 VM 的**直接控制台**。当看到 `bash-4.4#` 时，按回车并运行以下命令以初始化 shell 环境并生成 SSH 主机密钥：

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
iproxy 22222 22222   # SSH
iproxy 5901 5901     # VNC
```

连接方式：

- **SSH：** `ssh -p 22222 root@127.0.0.1`（密码：`alpine`）
- **VNC：** `vnc://127.0.0.1:5901`

## 所有 Make 目标

运行 `make help` 获取完整列表。关键目标：

| 目标 | 描述 |
|------|------|
| `build` | 构建并签名 vphone-cli |
| `vm_new` | 创建 VM 目录 |
| `fw_prepare` | 下载/合并 IPSWs |
| `fw_patch` | 修补启动链 |
| `boot` / `boot_dfu` | 启动 VM（GUI / 无头 DFU） |
| `restore_get_shsh` | 获取 SHSH blob |
| `restore` | 刷写固件 |
| `ramdisk_build` | 构建 SSH ramdisk |
| `ramdisk_send` | 发送 ramdisk 到设备 |
| `cfw_install` | 安装 CFW 修改 |
| `clean` | 删除构建产物 |

## 常见问题（FAQ）

> **在做其他任何事情之前——先运行 `git pull` 确保你有最新版。**

**问：运行时出现 `zsh: killed ./vphone-cli`。**

AMFI 未禁用。设置 boot-arg 并重启：

```bash
sudo nvram boot-args="amfi_get_out_of_my_way=1 -v"
```

**问：卡在“Press home to continue”屏幕。**

通过 VNC (`vnc://127.0.0.1:5901`) 连接，并在屏幕上右键单击任意位置（在 Mac 触控板上双指点击）。这会模拟 Home 按钮按下。

**问：SSH 连接后立即关闭（`Connection closed by 127.0.0.1`）。**

首次启动时未生成 dropbear 主机密钥。通过 VNC 或 `make boot` 控制台连接并运行：

```bash
export PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/bin/X11:/usr/games:/iosbinpack64/usr/local/sbin:/iosbinpack64/usr/local/bin:/iosbinpack64/usr/sbin:/iosbinpack64/usr/bin:/iosbinpack64/sbin:/iosbinpack64/bin'
mkdir -p /var/dropbear
dropbearkey -t rsa -f /var/dropbear/dropbear_rsa_host_key
dropbearkey -t ecdsa -f /var/dropbear/dropbear_ecdsa_host_key
killall dropbear
dropbear -R -p 22222
```

**问：可以升级到更新的 iOS 版本吗？**

可以。使用你想要的版本的 IPSW URL 覆盖 `fw_prepare`：

```bash
export IPHONE_SOURCE=/path/to/some_os.ipsw
export CLOUDOS_SOURCE=/path/to/some_os.ipsw
make fw_prepare
make fw_patch
```
