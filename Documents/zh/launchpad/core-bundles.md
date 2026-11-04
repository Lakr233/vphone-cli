# Core Bundle 与本地构建

每台 Launchpad 虚拟机都使用一个已安装的 `VPhone.bundle` 版本运行，即它的 Core Bundle。本页介绍如何安装本地构建、把虚拟机迁移到该构建，以及如何并排比较两个构建。

## 测试 VPhone.bundle 构建

1. 在仓库根目录构建 bundle：

   ```sh
   xcodebuild -workspace VPhone.xcworkspace -scheme VPhone \
     -configuration Debug -destination 'platform=macOS,arch=arm64' \
     -derivedDataPath .build/XcodeBundle build
   ```

2. 安装。它会以 `<version>-local.<hash>` 安装并成为默认版本，获得执行策略例外，新的 `vphone-vm` cdhash 会被允许，然后运行宿主机预检：

   ```sh
   vphone-launchpad-cli bundle install-local .build/XcodeBundle/Build/Products/Debug/VPhone.bundle
   ```

   确切的版本号见安装结果和 `bundle list`。

3. 把现有虚拟机迁移到该版本。`--update-environment` 还会重新部署新的 vphoned 和 hook dylib，并要求虚拟机处于停止状态：

   ```sh
   vphone-launchpad-cli vm set-bundle research-01 2.4.0-local.1a2b3c4d --update-environment
   ```

4. 启动虚拟机并检查：

   ```sh
   vphone-launchpad-cli vm start research-01 --wait
   vphone-launchpad-cli guest rpc research-01 device.info
   vphone-launchpad-cli guest rpc research-01 apps.list '{}'
   vphone-launchpad-cli vm log research-01 --lines 100
   vphone-launchpad-cli vm stop research-01
   ```

辅助程序的授权有效期为五分钟。授权过期后，第一个需要辅助程序的步骤会像窗口中一样，在 Mac 上要求输入管理员密码。

要为现有虚拟机进行一次性的内核和客户机更新以启用持久着色器缓存，请参阅[持久着色器缓存](../storage/shader-cache.md)。

## 比较两个构建

安装两个构建但不改变默认版本，然后分别为它们创建虚拟机：

```sh
vphone-launchpad-cli bundle install-local /path/to/A/VPhone.bundle --keep-default
vphone-launchpad-cli bundle install-local /path/to/B/VPhone.bundle --keep-default
vphone-launchpad-cli bundle list        # note both versions

vphone-launchpad-cli vm create cmp-a --bundle 2.4.0-local.aaaaaaaa
vphone-launchpad-cli vm create cmp-b --bundle 2.4.0-local.bbbbbbbb
```

这样创建的虚拟机在全部三层上都不同（见下文）。如果只想在同一条启动链上比较宿主机程序和客户机环境，请在窗口中克隆一台虚拟机，然后重新绑定副本：

```sh
vphone-launchpad-cli vm set-bundle cmp-b 2.4.0-local.bbbbbbbb --update-environment
```

`vm list` 会显示每一层来自哪个 bundle。有虚拟机绑定到某个版本时，`bundle remove` 会拒绝删除该版本；请先重新绑定或删除这些虚拟机。

## 虚拟机如何绑定到 bundle

每台虚拟机都绑定到一个已安装的版本，在创建时选定，并保存在虚拟机文件夹的 `launchpad.json` 中。安装 bundle 永远不会改变虚拟机的绑定。

一台虚拟机由三层组成，每一层在不同时间取自 bundle：

| 层 | 内容 | 来源 |
| --- | --- | --- |
| Host Programs（宿主机程序） | `vphone-cli`、`vphone-vm` | 每条命令都取自绑定的 bundle。新的绑定在下次启动时生效。 |
| Guest Environment（客户机环境） | vphoned 和 hook dylib | 创建时由 `cfw install` 安装，之后由 `cfw update-environment`（虚拟机须停止）更新。 |
| Boot Chain（启动链） | 打过补丁的固件、恢复、CFW 补丁 | 创建时由 `fw patch`、`restore` 和 `cfw install` 生成。 |

### 之后更改启动链补丁

`vphone-cli fw set-patches` 更改补丁选择，`vphone-cli fw patches <vm>` 列出尚未应用到客户机的补丁。Launchpad 会在检查器中显示数量。每类补丁应用到客户机的方式不同：

| 补丁 | 应用方式 |
| --- | --- |
| 客户机补丁 | 下一次 `cfw update-environment` |
| AVPBooter | 下一次 `fw patch` |
| 内核补丁 | `cfw update-kernel`（保留数据，不需要恢复目录） |
| 启动链的其余部分（TXM、DeviceTree、LLB） | 只能重新恢复，这会抹掉客户机 |

## 默认 bundle

**默认** bundle（以前称为“active”）只决定：

- 未指定 `--bundle` 时，`vm create` 绑定哪个版本；
- `exec` 和作用于整个资料库的命令使用哪个版本运行。

新安装的版本会成为默认版本，除非传入 `--keep-default`。在一个 Launchpad 会话中首次启动某台虚拟机时，会检查一次它的 bundle（执行策略例外、AMFI、宿主机预检）。

## 版本名称

本地构建以 `<version>-local.<hash>` 安装，哈希取自 bundle 的代码签名封印，因此同一版本的两个构建可以并存。较旧的存储中可能仍有 `<version>-local` 或 `<version>-ci.<commit>`。

## 另请参阅

- [Launchpad 命令行](launchpad-cli.md)
- [Bundle 集成](bundle-integration.md)
- [下载](../get-started/downloads.md)
