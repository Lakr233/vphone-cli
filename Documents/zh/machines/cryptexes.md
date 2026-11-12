# Cryptex

Cryptex 是一个签名的磁盘映像，客户机在运行时将其挂载，并带有其中程序的信任缓存。用它可以在 `minimal` 客户机中运行你自己的程序，而无需再次恢复。

## 开始之前

- 创建机器时选择 `minimal` 预设，并在“新建机器”的“补丁”页上打开 **Trusted darwinOS environment** 选项。使用 `vphone-launchpad-cli` 时，即 `--preset minimal --allow filesystem-exp-trusted_darwinos`。该选项只在恢复时生效：要为已有的机器打开它，需要重新创建这台机器。
- 使用 iOS 26 或 iOS 18 的 IPSW。已验证 iOS 26.5 搭配 cloudOS 26.5、iOS 18.6 搭配 cloudOS 18.6 可用。iOS 27 在此环境中无法启动，所以 IPSW 为 iOS 27 时，vphone-cli 会在恢复之前拒绝该选项。
- 安装 macOS Security Research 工具（PCC Virtual Research Environment）。VM 窗口使用其中的 `/System/Library/SecurityResearch/usr/bin/cryptexctl.research` 构建 cryptex。
- 客户机需要网络。安装 cryptex 时会请求 Apple 的签名服务器为此客户机个性化它。

在此环境中，客户机强制执行 Restricted Execution Mode，运行在研究板 cloudOS（26.5 到 26.7）上的客户机无法打开开发者模式。

## 安装 cryptex

1. 把 cryptex 要包含的文件放进一个文件夹，目录结构与它们在 cryptex 中的位置相同。例如：

   ```
   mycryptex/
     usr/bin/server
     Library/LaunchDaemons/server.plist
   ```

   用每个程序所需的授权对其进行临时签名（`codesign -s - --entitlements entitlements.plist usr/bin/server`）。
2. 在 VM 窗口中选择 **Apps › Install Cryptex…**，然后选择该文件夹。

VM 窗口会为此客户机构建 cryptex 并上传，客户机随后对其进行个性化并安装。文件夹名称（去掉扩展名）即 cryptex 的标识符。它挂载在 `/private/var/DarwinDataCenterSupportImage/<identifier>`，因此对于上例中的文件夹 `mycryptex`，`usr/bin/server` 在客户机中是 `/private/var/DarwinDataCenterSupportImage/mycryptex/usr/bin/server`。安装后的提示会给出该路径。cryptex 的 `Library/LaunchDaemons` 中的启动守护进程会从 cryptex 中启动。

**Apps › List Cryptexes** 显示已安装的 cryptex 及各自的挂载点。

从虚拟机窗口安装的 cryptex 会保留到客户机重启为止；重启后需要重新安装。若要让 cryptex 在重启后保留，请通过脚本以 `persist` 安装（见下文）。

可以同时安装多个 cryptex，每个都有自己的路径。如果文件夹名称已作为 cryptex 安装，安装会被拒绝：先用 `cryptex.uninstall` 卸载该 cryptex（见下文），或重命名文件夹。

## 选择文件夹，而不是 `.cxbd`

Install Cryptex… 也接受 `.cxbd` 并按原样安装，但只限为此客户机制作的：面向 vresearch101 主板的 Cryptex1 cryptex，即 `cryptexctl.research create` 使用 `--BORD=0x90 --CHIP=0xfe01` 生成的那种。其他情况都请选择文件夹。

为 Security Research Device iPhone 构建的 cryptex 无法安装。SRD 示例及其 Makefile 使用的 `cryptexctl create --research` 生成的就是这种。Install Cryptex… 会指出这一点，并在上传前停止。请改为选择构建它所用的文件夹；如果用 Makefile 构建，通常是 `build/<identifier>.root`，即其内容被放进磁盘映像的那个文件夹。

## 通过脚本

vphoned 通过[自动化 API](automation-api.md) 提供 `cryptex.list`、`cryptex.install` 和 `cryptex.uninstall`。`cryptex.install` 接受已上传到 `/var/mobile/Documents/vphone-cryptexes` 下的 `.cxbd` 以及创建它时使用的 variant。使用 `persist: true` 时，vphoned 会在客户机每次重启后重新安装该 cryptex；若需要再次向 Apple 的签名服务器请求，客户机需要联网。`cryptex.list` 在 `persisted` 中列出这些 cryptex，`cryptex.uninstall` 会将其彻底移除。

实现细节请参阅 [`Research/Firmware/trusted_darwinos_cryptexes.md`](../../../Research/Firmware/trusted_darwinos_cryptexes.md)。
