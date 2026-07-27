<div align="right"><strong><a href="./README_ko.md">🇰🇷한국어</a></strong> | <strong><a href="./README_ja.md">🇯🇵日本語</a></strong> | <strong>🇨🇳中文</strong> | <strong><a href="../README.md">🇬🇧English</a></strong></div>

# vphone-cli

使用 PCC 研究虚拟机基础设施，通过 Apple 的 Virtualization.framework 启动一台虚拟 iPhone。

所有操作都通过单个 `vphone-cli` 二进制文件完成——创建、打补丁、恢复、安装、启动以及管理虚拟机。构建完成后无需再使用 `make`。

![poc](./demo.jpeg)

## 测试环境

| 宿主机          | iPhone                | CloudOS         |
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

iOS ≤ 26.0.1 使用 26.1 PCC vphone600 栈，外加 CFW 阶段的 `IOMobileFramebuffer` SwapEnd 载荷大小补丁。iOS 27.0 使用 26.4 PCC vphone600 栈，外加 CFW 阶段的强制内核 `IOMobileFramebuffer` present-path 补丁以及 dyld 共享缓存 `maxSlide` 适配。

> **注意：** GPU/Metal 加速在 iOS 18.x 上无法工作——18.x 的 Metal/IOGPU 框架没有半虚拟化 GPU 实现，因此由 Metal 渲染的内容（网页、图片、壁纸）不会显示。触控、网络和应用可正常工作。

## 固件变体

五种补丁变体，安全绕过程度递增——将其中之一传给 `--variant`：

| 变体         | 引导链      | CFW       | 说明                                              |
| ------------ | ----------- | --------- | ------------------------------------------------- |
| `less`       | 4 patches   | 2 phases  | 无补丁——保持 iOS 缓解措施启用                     |
| `regular`    | 42 patches  | 10 phases | 绕过 AMFI/SSV/Img4/TXM                            |
| `dev`        | 53 patches  | 12 phases | + 绕过 TXM 授权/调试                              |
| `jb`         | 113 patches | 14 phases | + 完整越狱（首次启动时自动安装 Sileo、TrollStore）|
| `exp`        | 141 patches | 18 phases | JB 超集 + 反虚拟机检测研究补丁                    |

各组件的详细拆解见 [`research/0_binary_patch_comparison.md`](../research/0_binary_patch_comparison.md)。

## 前置条件

**宿主机：** macOS 15+（Sequoia），一台非嵌套的 Mac（Virtualization.framework 无法嵌套）。私有 PV=3 授权 + 未签名二进制的工作流需要放宽 SIP/AMFI。请从以下两条路径中选择**一条**——SIP 设置和 AMFI 设置是配套的，不要混用：

**方案 A——完全禁用 SIP，然后通过 boot-arg 禁用 AMFI（最宽松）。** 在恢复模式下（长按电源键 → 终端）：

```bash
csrutil disable
csrutil allow-research-guests enable
```

然后重启进入 macOS 并设置 AMFI boot-arg（需要 SIP 完全关闭才能生效）：

```bash
sudo nvram boot-args="amfi_get_out_of_my_way=1 -v"   # 之后重启
```

**方案 B——保持 SIP 开启（仅放宽 debug），然后用 amfidont 将二进制加入白名单**（AMFI 在系统范围内保持启用）。在恢复模式下：

```bash
csrutil enable --without debug
csrutil allow-research-guests enable
```

然后重启进入 macOS，用 [`amfidont`](https://github.com/zqxwce/amfidont)（或 [`amfree`](https://github.com/retX0/amfree)）将仓库加入白名单：

```bash
sudo amfidont --path <repo>
```

> `less`（无补丁）变体需要方案 A，或者搭配 `amfidont -S` 的方案 B（`sudo amfidont -S --path <repo>`）。

**依赖：**

```bash
git clone --recurse-submodules https://github.com/Lakr233/vphone-cli.git
brew install python@3.13 aria2 wget gnu-tar openssl@3 ldid-procursus sshpass keystone libusb ipsw zstd
```

（需要一个较新的 `python3`——3.11+；应用会基于它构建自己的 Python 环境，见 [Python 运行时](#python-运行时)。）

## 构建

两个一次性的引导脚本（编译后的二进制无法自行构建），之后一切都通过 `vphone-cli` 完成：

```bash
./scripts/setup_tools.sh      # 安装依赖、构建工具链子模块、创建 Python venv
./scripts/build.sh            # 构建并签名 vphone-cli、打包 .app、交叉编译 vphoned
```

把二进制加入你的 `PATH`，这样下面的示例就能原样运行：

```bash
cd .build/release
vphone-cli --help
```

## 快速开始

一条命令即可端到端创建一台虚拟机（下载 → 打补丁 → DFU 恢复 → CFW 安装 → 首次启动）：

```bash
vphone-cli vm create myphone -V jb        # -V / --variant
```

不带源标志时，它会下载一对默认的、经过测试的 iPhone + cloudOS 固件。要选择特定固件，请传入 **`-i`/`--iphone-source`** 和 **`-c`/`--cloudos-source`**——每个都接受 **URL** 或**本地 `.ipsw` 路径**（已验证可用的固件对见[测试环境](#测试环境)）：

```bash
# 使用本地 IPSW
vphone-cli vm create myphone -V jb \
  -i ~/ipsws/iPhone17,3_26.1_23B85_Restore.ipsw \
  -c ~/ipsws/cloudOS_26.1-23B85.ipsw

# 或使用 URL——下载后缓存到 ~/.vphone/ipsws
vphone-cli vm create myphone -V jb \
  -i "https://updates.cdn-apple.com/.../iPhone17,3_26.1_23B85_Restore.ipsw" \
  -c "https://updates.cdn-apple.com/private-cloud-compute/<id>"
```

CFW 安装阶段需要 root 权限（挂载宿主机磁盘），并会提示输入 `sudo`；传入 `-s <pw>`（`--sudo-password`）可无人值守运行。加上 `-v` 可观看恢复过程（pmd3 日志，带颜色），`-vv` 显示 pmd3 调试细节，`-vvv` 显示 vphone-cli 的内部跟踪。然后启动它：

```bash
vphone-cli vm launch myphone
```

虚拟机存放在位于 `~/.vphone/VMs/` 的**库**中（任何命令都可用 `--library-root <dir>` 覆盖）。运行任何虚拟机命令时不带名称（例如 `vphone-cli vm launch`），即可从你的虚拟机菜单中选择。

## 命令

`vphone-cli vm create` 会运行整个流水线；下面的各个步骤让你可以手动驱动它，或重新运行某一个阶段。

### 管理

```bash
vphone-cli vm list                         # 列出虚拟机（--json 用于脚本）
vphone-cli vm info myphone                  # 显示某台虚拟机
vphone-cli vm new myphone                   # 创建一个空 bundle（cpu/内存/磁盘选项）
vphone-cli vm config myphone --cpu 8 --memory 8192
vphone-cli vm clone myphone myphone-2       # 快速 APFS 克隆，全新设备标识
vphone-cli vm export myphone --out myphone.tar.xz   # xz -9；跳过 restore 目录 + 暂存文件
vphone-cli vm import --in myphone.tar.xz --name restored
vphone-cli vm rename myphone iphone16
vphone-cli vm delete iphone16
```

### 手动构建虚拟机（`vm create` 自动化的流程）

```bash
vphone-cli vm new myphone                              # 1. 空 bundle
vphone-cli fw prepare myphone --iphone-version 26.1     # 2. 下载并合并 IPSW
vphone-cli fw patch myphone --variant jb                # 3. 给引导链打补丁

vphone-cli vm launch myphone --dfu &                    # 4. 启动进入 DFU（后台）
vphone-cli restore myphone --get-shsh                   #    获取 SHSH
vphone-cli restore myphone                              #    DFU 恢复
vphone-cli vm stop myphone                              #    停止 DFU 引导

vphone-cli cfw install myphone --variant jb             # 5. 安装 CFW（宿主机挂载；会请求 sudo）
vphone-cli vm launch myphone                            # 6. 首次启动
```

要升级到更新的 iOS，把 `fw prepare` 指向一个 IPSW：`--iphone-source /path/to.ipsw --cloudos-source /path/to.ipsw`。

## 运行与连接

`vphone-cli vm launch <name>` 会打开虚拟机窗口；`vphone-cli vm stop <name>` 会将其关闭。客户机在端口 `22222` 上运行 SSH 服务器（dropbear），在 `5901` 上运行 VNC，可通过虚拟机的 NAT IP 访问（在 `bridge100` 上用 `arp -a` 查找）：

- **SSH（越狱）：** `ssh -p 22222 mobile@<vm-ip>`（密码 `alpine`）
- **SSH（regular/dev）：** `ssh -p 22222 root@<vm-ip>`
- **VNC：** `vnc://<vm-ip>:5901`

对于 `jb`/`exp` 变体，Sileo 和 TrollStore 会在首次启动时自动安装（可监控 `/var/log/vphone_jb_setup.log`）。

## Python 运行时

有几个步骤（DFU 恢复、IPSW 处理）通过 Python 运行。首次使用时，vphone-cli 会基于宿主机上较新的 `python3`（3.11+）并使用捆绑的 `requirements.txt`，在 `~/.vphone/venv` 处配置一个自包含的 venv——因此签名后的 `.app` 是**可移植的**：把它复制到任何地方（例如 `/Applications`），无需仓库即可运行。配置是自动进行的；运行 `vphone-cli setup` 可提前完成配置。用 `VPHONE_PYTHON=/path/to/python3` 指定特定的解释器，或用 `VPHONE_VENV_DIR=/path` 迁移 venv。

## 常见问题

**`zsh: killed ./vphone-cli`** —— AMFI/debug 限制未被绕过；见[前置条件](#前置条件)（`amfi_get_out_of_my_way=1` 或 `amfidont`）。

**`Virtualization is not available on this hardware`** —— 你的 Mac 本身就是一台虚拟机；PV=3 客户机启动无法嵌套。请使用非嵌套的 macOS 15+ 宿主机。

**卡在 “Press home to continue”** —— 通过 VNC 连接，然后右键点击（双指点击）来模拟 home 键。

**系统应用无法安装** —— 在 iOS 设置过程中，不要选择日本或欧盟作为你的地区（会有额外的监管检查，虚拟机无法满足）；请选择例如美国。

**应用启动时崩溃并报 `EXC_GUARD` / `GUARD_TYPE_MACH_PORT`** —— 用 `vphone-cli fw patch <name> --variant <v> --force-exc-guard` 重新打补丁，然后重新恢复/安装（[#291](https://github.com/Lakr233/vphone-cli/issues/291)）。对于 iOS 18 基础版本始终启用。

**安装 `.ipa`/`.tipa`** —— 使用运行中虚拟机的 Install 菜单（拖放或文件选择器）。

## 自动化

`vphone-cli` 暴露了一个宿主控制套接字（`<bundle>/vphone.sock`）用于程序化控制——截图、触控、滑动、硬件按键、剪贴板——每个动作都会返回一张内联截图，用于 AI 驱动的端到端测试。包装它的 MCP 服务器见 [vphone-mcp](https://github.com/pluginslab/vphone-mcp)。

## 致谢

- [wh1te4ever/super-tart-vphone-writeup](https://github.com/wh1te4ever/super-tart-vphone-writeup)
