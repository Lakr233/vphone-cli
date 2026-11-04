# 软件包环境

在虚拟机中安装或删除软件包管理器。新建的虚拟机没有软件包管理器；需要在客户机中使用 `apt`、shell、SSH 或其他命令行工具时，请按本页操作。

## 安装

1. 在虚拟机窗口的菜单栏中选择 **Apps > Install Bootstrap…**，布局选择 **roothide**（**rootless** 已弃用）。这会在虚拟机中安装 Irisin。
2. 在 Irisin 中打开 **OwnGoal Packages** 软件源，找到 **OwnGoal Bootstrap for vphone**（`owngoal-bootstrap-vphone`），用 **Bootstrap Install** 安装。
3. 首次安装完成后，其余软件包按普通方式安装即可。

`owngoal-bootstrap-vphone` 会一次装好虚拟机需要的全部内容：`apt` 和 `dpkg`、`bash`、`zsh` 和 `dash`、`sudo`、核心命令行工具、`openssh-server`、`curl`、`wget`、`vim`、`git`、`uikittools`、`launchctl`，以及 OwnGoal 的几个 App。

> [!WARNING]
> 不要逐个安装这些软件包。其中一些相互依赖，`openssh-server` 的部分依赖声明还存在循环，分别安装可能在中途失败。

如果首次安装失败，不要在原环境上修复。请选择 **Apps > Uninstall Bootstrap…**，然后从第 1 步重新开始。

### 在创建虚拟机时安装

```sh
vphone-cli vm create myphone --bootstrap roothide ...
```

`--bootstrap roothide` 会在新虚拟机首次启动时完成第 1 步和第 2 步：先安装 Irisin，再通过 `irisin-cli` 从 Irisin 推荐的软件源以 Bootstrap Install 方式安装 `owngoal-bootstrap-vphone`。第 2 步要求 Irisin 的 `irisin-cli install` 支持 `--repository` 和 `--bootstrap-install`。

## 删除

选择 **Apps > Uninstall Bootstrap…**。删除后虚拟机会重启。

Irisin 把自己的数据（下载内容、日志、设置）保存在其主目录下的 `Documents/wiki.qaq.irisin` 中：

| 布局 | Irisin 的主目录 | 卸载后 |
| --- | --- | --- |
| roothide | 环境自己的 `/var/mobile` | 数据随其他内容一起删除。 |
| rootless | 系统的 `/var/mobile` | 数据会保留。 |

## 更多选项

按住 Option 键打开 **Apps** 菜单，会多出两个选项：

- **Install Bootstrap from File…**：使用本地的 Irisin `.deb` 安装。
- **Uninstall Bootstrap Without Restarting…**：删除环境，但不重启虚拟机。

自动化 API 也提供同样的操作（`bootstrap.install`、`bootstrap.status`）。见 [API 参考](../../../Research/vphoned_http_api.md)。

## 另请参阅

- [创建与运行虚拟机](create-and-run.md)
- [自动化 API](automation-api.md)
- [故障排查](../help/troubleshooting.md)
