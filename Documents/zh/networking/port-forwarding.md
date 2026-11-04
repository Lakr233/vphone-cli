# 端口转发

在 `nat` 和 `tunnel` 模式下，用 `--forward` 把 Mac 上的端口转发到客户机。`bridged` 模式下客户机以自己的地址接入局域网，因此不需要转发。

## 添加和删除转发

```sh
vphone-cli vm config <name> --forward tcp:8022:22
vphone-cli vm config <name> --forward udp:0.0.0.0:5353:53
vphone-cli vm config <name> --remove-forward 8022
vphone-cli vm config <name> --clear-forwards
```

格式为：

```text
[tcp|udp:][host-address:]host-port:guest-port
```

| 部分 | 含义 |
| --- | --- |
| `tcp` 或 `udp` | 协议 |
| `host-address` | 转发在 Mac 上监听的地址。默认为 `127.0.0.1`；设为 `0.0.0.0` 后局域网中的其他设备也能访问。 |
| `host-port` | Mac 上的端口 |
| `guest-port` | 客户机中的端口 |

要转发更多端口，请重复使用 `--forward`。在 Launchpad 中，虚拟机的 Settings…（设置）中有 Port Forwarding（端口转发）部分。

## 转发的行为

- `vphone-vm` 在虚拟机启动时打开监听器，在虚拟机停止时关闭。
- 在 `nat` 模式下，它连接到客户机的地址：[固定地址](addresses.md)，或 vphoned 报告的地址。
- 在 `tunnel` 模式下，连接到达客户机时看起来来自网关。
- 如果 Mac 上的某个端口已被占用，会在虚拟机日志中报告并跳过；其他转发仍然有效。

## 另请参阅

- [网络](overview.md)
- [隧道模式](tunnel.md)
- [MAC 与 IP 地址](addresses.md)
