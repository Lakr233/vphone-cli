# 自定义 CA 证书

`vm ca` 命令用于在运行中客户机的 TrustStore 里安装、列出和删除受信任的根 CA 证书。当客户机需要信任系统未自带的证书时使用它们，例如要让客户机信任某个拦截 HTTPS 流量的代理的根证书。

这三个命令都与运行中的虚拟机通信，因此请先用 `vm launch` 启动虚拟机。请像下面的示例那样显式传入虚拟机名称；必需的参数在前，虚拟机名称在后。如果省略名称，会出现一个交互式选择器，列出库中的所有虚拟机（无论是否在运行，即使只有一台），并要求你选择。在没有终端的环境（脚本、CI）中，命令会以 `No VM name given, and this is not an interactive terminal` 报错失败，因此自动化中请始终指定名称。

## 安装

```sh
vphone-cli vm ca install <pem-file> <vm-name> [--admin] [--json]
```

把一个仅含单张证书的 PEM 文件（最大 64 KiB）作为受信任的根 CA 安装到客户机。它输出一行：

```text
sha256<TAB>subject
```

| 选项 | 含义 |
| --- | --- |
| `--admin` | 安装到管理员（admin）信任域，而不是默认的用户域。 |
| `--json` | 不输出单行，而是以键已排序的美化 JSON 输出 `{sha256, subject, domain}`。 |

## 列出

```sh
vphone-cli vm ca list <vm-name>
```

列出已安装的锚点，每行一个，格式为 `sha256<TAB>subject`，按 sha256 排序。

## 删除

```sh
vphone-cli vm ca remove <sha256> <vm-name>
```

按 `list` 中显示的 64 位十六进制 sha256，删除对应的锚点。

## 示例

让客户机信任某个拦截 HTTPS 流量的代理的根证书，确认已生效，完成后再删除它：

```sh
vphone-cli vm ca install proxy-ca.pem my-vm
vphone-cli vm ca list my-vm
vphone-cli vm ca remove 9f2b8c1d4e6a0f3b5c7d9e1a2b4c6d8e0f1a2b3c4d5e6f708192a3b4c5d6e7f8 my-vm
```

## 另请参阅

- [网络](overview.md)
- [隧道模式](tunnel.md)
