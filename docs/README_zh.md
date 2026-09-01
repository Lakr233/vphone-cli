<div align="right"><strong><a href="./README_ko.md">🇰🇷한국어</a></strong> | <strong><a href="./README_ja.md">🇯🇵日本語</a></strong> | <strong>🇨🇳中文</strong> | <strong><a href="../README.md">🇬🇧English</a></strong></div>

# vphone-cli

使用 PCC 研究虚拟机基础设施，通过 Apple 的 Virtualization.framework 启动一台虚拟 iPhone。

![poc](./demo.jpeg)

## 前置条件

**宿主机：**

- Apple Silicon
- macOS 15+（Sequoia）
- Xcode + iOS SDK（用于交叉编译访客守护进程）
- [放宽 SIP/AMFI，以允许未签名二进制使用私有 PV=3 授权](#放宽-sipamfi)

**依赖：**

```bash
brew install python@3.13 aria2 wget gnu-tar openssl@3 ldid-procursus sshpass keystone cmake libusb ipsw zstd
```

## 安装

```bash
brew install zqxwce/tap/vphone-cli
```

## 构建

```bash
git clone --recurse-submodules https://github.com/Lakr233/vphone-cli.git

./scripts/setup_tools.sh      # 安装依赖、构建工具链子模块、创建 Python venv
./scripts/build.sh            # 构建并签名 vphone-cli、打包 .app、交叉编译 vphoned

cd .build/vphone-cli.app/Contents/MacOS/
vphone-cli --help
```

## 快速开始

一条命令即可端到端创建一台虚拟机（下载 → 打补丁 → DFU 恢复 → CFW 安装 → 首次启动）：

```bash
vphone-cli vm create myphone -V jb        # -V / --variant

vphone-cli vm launch myphone
```

## 命令

`vphone-cli vm create` 会运行整个流水线；下面的各个步骤让你可以手动驱动它，或重新运行某一个阶段。

### 管理

```bash
vphone-cli vm list                         # 列出虚拟机（--json 用于脚本）
vphone-cli vm info myphone                  # 显示某台虚拟机
vphone-cli vm new myphone                   # 创建一个空 bundle（cpu/内存/磁盘选项）
vphone-cli vm config myphone --cpu 8 --memory 8192
vphone-cli vm clone myphone myphone-2       # 快速 APFS 克隆，全新设备标识
vphone-cli vm export myphone --out myphone.tzst   # zstd fast by default（--max = xz -9）；--out 为目录时自动命名 <vm>.tzst/.txz；跳过 restore 目录 + 暂存文件
vphone-cli vm import myphone.tzst --name restored
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

## 固件变体

五种补丁变体，安全绕过程度递增——将其中之一传给 `--variant`：

| 变体      | 引导链      | CFW       | 说明                                              |
| --------- | ----------- | --------- | ------------------------------------------------- |
| `less`    | 4 patches   | 2 phases  | 无补丁——保持 iOS 缓解措施启用                     |
| `regular` | 42 patches  | 10 phases | 绕过 AMFI/SSV/Img4/TXM                            |
| `dev`     | 53 patches  | 12 phases | + 绕过 TXM 授权/调试                              |
| `jb`      | 113 patches | 14 phases | + 完整越狱（首次启动时自动安装 Sileo、TrollStore）|
| `exp`     | 141 patches | 18 phases | JB 超集 + 反虚拟机检测研究补丁                    |

各组件的详细拆解见 [`research/0_binary_patch_comparison.md`](../research/0_binary_patch_comparison.md)。

## 运行与连接

- **SSH（越狱）：** `ssh -p 22222 mobile@<vm-ip>`（密码 `alpine`）
- **SSH（regular/dev）：** `ssh -p 22222 root@<vm-ip>`
- **VNC：** `vnc://<vm-ip>:5901`

## 位置

vphone-cli 创建的所有内容都位于 `~/.vphone/` 下——保存在仓库和 `.app` 之外，以便签名后的包保持可移植。可用 `$VPHONE_ROOT` 重定向整个目录树：

| 路径              | 内容                                                                             |
| ----------------- | -------------------------------------------------------------------------------- |
| `~/.vphone/`      | 每用户数据根目录——用 `$VPHONE_ROOT` 覆盖整个位置。                                |
| `~/.vphone/VMs/`  | 虚拟机包——每个虚拟机一个目录。这是库；可用 `$VPHONE_LIBRARY_ROOT` 覆盖。          |
| `~/.vphone/ipsws/`| 已下载的 iPhone + cloudOS IPSW，缓存后在多个虚拟机间复用。                        |
| `~/.vphone/tools/`| `fw prepare` 期间获取的 APFS seal-volume 制品（`apfs_sealvolume_<version>`）缓存。 |
| `~/.vphone/debs/` | `jb`/`exp` CFW 安装写入客户机的 `.deb` 包缓存（Sileo、apt 等）。                   |
| `~/.vphone/venv/` | 自动配置的 Python 环境（见 [Python 运行时](#python-运行时)；可用 `$VPHONE_VENV_DIR` 覆盖）。 |

优先级：单项覆盖（`$VPHONE_LIBRARY_ROOT`、`$VPHONE_VENV_DIR`）优先于 `$VPHONE_ROOT`，`$VPHONE_ROOT` 优先于 `~/.vphone` 默认值。`ipsws/`、`tools/` 和 `debs/` 缓存始终位于当前生效的根目录之下。

## 放宽 SIP/AMFI

**方案 A——完全禁用 SIP，然后通过 boot-arg 禁用 AMFI（最宽松）。**

在恢复模式下（长按电源键 → 终端）：

```bash
csrutil disable
csrutil allow-research-guests enable
```

然后重启进入 macOS 并设置 AMFI boot-arg（需要 SIP 完全关闭才能生效）：

```bash
sudo nvram boot-args="amfi_get_out_of_my_way=1 -v"   # 之后重启
```

**方案 B——保持 SIP 开启（仅放宽 debug），然后用 amfidont 将二进制加入白名单**（AMFI 在系统范围内保持启用）。

在恢复模式下：

```bash
csrutil enable --without debug
csrutil allow-research-guests enable
```

然后重启进入 macOS 并执行：

```bash
vphone-amfidont         # 本地构建见 .build/vphone-cli.app/Contents/Resources/vphone-amfidont
```

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
| Mac16,6 26.4.1  | `17,3_26.6_23G71`     | `26.4-23E5207q` |
| Mac16,11 27.0b2 | `17,3_26.6.1_23G83`   | `26.4-23E5207q` |
| Mac16,11 27.0b2 | `17,3_27.0_24A5380h`  | `26.4-23E5207q` |
| Mac16,6 26.4.1  | `17,3_27.0_24A5390f`  | `26.4-23E5207q` |
| Mac16,6 26.6.1  | `17,3_27.0_24A5408d`  | `26.4-23E5207q` |
| Mac16,11 27.0b2 | `17,3_27.0_24A5418b`  | `26.4-23E5207q` |
| Mac16,11 27.0b2 | `17,3_27.0_24A5424a`  | `26.4-23E5207q` |
| Mac16,11 27.0b2 | `17,3_27.0_24A5430a`  | `26.4-23E5207q` |

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
