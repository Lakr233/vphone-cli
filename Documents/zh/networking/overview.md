# 网络

每台虚拟机有一种网络模式。本页介绍如何选择网络模式，以及如何为运行中的虚拟机断开网络；本节的其他页面介绍隧道模式、地址、端口转发、名称以及虚拟机互访。

## 网络模式

| 模式 | 客户机如何访问互联网 | 适用情况 |
| --- | --- | --- |
| `nat` | Virtualization.framework 内置的 NAT | 默认模式。Mac 没有使用 VPN，或者 VPN 不需要承载客户机的流量。 |
| `bridged` | 直接接入 Mac 的某个物理接口，在该网络上拥有自己的地址 | 客户机需要能被局域网中的其他机器访问。 |
| [`tunnel`](tunnel.md) | 通过 `vphone-vm` 在 Mac 上建立的普通连接 | Mac 的流量经过 VPN 或代理 App，客户机的流量也必须同样经过它。 |
| `none` | 没有网络设备 | 客户机必须保持离线。 |

网络模式保存在虚拟机的 `config.plist` 中，在虚拟机启动时读取，因此更改会在下次启动时生效。

## 选择模式

在 Launchpad 中：

1. 停止虚拟机。
2. 在 `⋯` 菜单或右键菜单中选择 Settings…（设置）。
3. 在 Network（网络）部分选择模式。

New Machine（新建虚拟机）在 Advanced Options（高级选项）中设置模式。选中一台虚拟机时，Settings… 中还有 Address（地址）和 Port Forwarding（端口转发）部分。

在命令行中：

```sh
vphone-cli vm config <name> --network tunnel
# or through Launchpad
vphone-launchpad-cli exec vm config <name> --network tunnel
```

`tunnel` 需要在 `vphone-cli vm config --help` 中列出了该模式的 `VPhone.bundle`。较旧的 bundle 会拒绝这项设置。

## 为运行中的虚拟机断开网络

`vm network` 作用于运行中的虚拟机，它所做的一切都不会被保存：

```sh
vphone-cli vm network <name>               # state of the NIC
vphone-cli vm network <name> --link down   # unplug the cable
vphone-cli vm network <name> --link up     # plug it back in
```

客户机会看到链路断开后又恢复。同样的请求也可以通过 `vphone.sock` 以 `{"t":"network"}` 发送，并附带 `"link":"down"` 或 `"link":"up"`。

> [!NOTE]
> 运行中的虚拟机无法切换到其他网络。Virtualization 会接受这项更改，然后以内部错误停止虚拟机，因此 `vm network` 只会恢复虚拟机启动时所用的网络。要更改模式，请使用 `vm config` 并重新启动虚拟机。

## 另请参阅

- [隧道模式](tunnel.md)：Mac 使用 VPN 或代理 App 时
- [MAC 与 IP 地址](addresses.md)：保存的 MAC 地址、旧 MAC 地址占用的租约、固定地址
- [端口转发](port-forwarding.md)：把 Mac 上的端口转发到客户机
- [网络上的名称](names.md)和[虚拟机互访](peers.md)
