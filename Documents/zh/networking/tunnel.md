# 隧道模式

当 Mac 的流量经过 VPN 或代理 App，而客户机的流量也必须走同样的路径时，请使用 `tunnel` 模式。在 `nat` 和 `bridged` 模式下，客户机的数据包会绕过 VPN。

## 开启

停止虚拟机，然后运行：

```sh
vphone-cli vm config <name> --network tunnel
```

在 Launchpad 中，在虚拟机 Settings…（设置）的 Network（网络）部分选择 `tunnel`。bundle 必须在 `vphone-cli vm config --help` 中列出 `tunnel`；较旧的 bundle 会拒绝该设置。

## 检查是否生效

1. 启动虚拟机，等待它完成启动。
2. 读取客户机的地址：

   ```sh
   vphone-launchpad-cli guest rpc <name> device.network
   ```

   `en0` 应显示 `192.168.127.3`。如果只显示 `fe80::` 地址，说明 DHCP 尚未完成。请等几秒钟再试。
3. 在客户机中打开一个网页：

   ```sh
   vphone-launchpad-cli guest rpc <name> apps.open_url '{"url":"https://example.com"}'
   ```

4. 在 Mac 上确认这些连接属于 `vphone-vm`，并且使用的是 VPN 的地址：

   ```sh
   lsof -nP -a -i -p "$(pgrep -f 'vphone-vm.*<name>')"
   ```

## 客户机看到的网络

| 项目 | 值 |
| --- | --- |
| 客户机地址 | 由 DHCP 分配的 `192.168.127.3/24`，或[固定地址](addresses.md) |
| 网关和 DNS | `192.168.127.1`，或固定地址所在子网的第一个地址 |
| MTU | 1500 |
| DNS | 发往 `192.168.127.1` 的查询会交给 Mac 的解析器 |
| 发往网关的其他连接 | Mac 的回环地址 `127.0.0.1`（TCP 和 UDP） |

在代理 App 中，客户机会显示为一个独立的客户端，以虚拟机的名称命名，App 的规则会像对其他 App 一样应用于它。

## 限制

- **仅支持 IPv4。** 客户机不会获得 IPv6 地址，IPv6 流量会被丢弃。
- **除转发端口外，只能向外连接。** Mac 或局域网上的任何设备都无法通过这个网络访问客户机，[端口转发](port-forwarding.md)中列出的端口除外。USB 访问（`iproxy`、`ideviceinstaller`）和 `vphone.sock` 不使用客户机网络，因此仍可正常使用。`.local` 名称也能通过 USB 链路访问客户机；见[网络上的名称](names.md)。
- **ping 只能到达网关。** 发往互联网的 ICMP 不会被转发，因此即使 TCP 和 UDP 正常，在客户机中运行 `ping 1.1.1.1` 也会失败。
- **吞吐量受限于 `vphone-vm`。** 每个数据包都在该进程中处理。下载和视频都能正常使用，但不涉及 VPN 时 `nat` 更快。

## 工作原理

当 VPN 接管了 Mac 的默认路由（WireGuard、Cloudflare WARP，或者以 TUN 模式运行的代理 App，如 Surge 或 Clash）时，`nat` 和 `bridged` 通过物理接口发出的数据包会绕过 VPN。它们要么以未加密的形式发出，要么根本发不出去。

在 `tunnel` 模式下，客户机的网卡在 `vphone-vm` 内部实现。它为网关响应 DHCP、ARP 和 ping，并把客户机的每个 TCP 连接和 UDP 流转换为 Mac 上的普通套接字。这些套接字像其他 App 的套接字一样遵循 Mac 的路由表，因此会由 VPN 承载。它不需要 root 权限，不需要新的网络接口，也不需要更改 Mac 的网络设置。

## 另请参阅

- [网络](overview.md)
- [MAC 与 IP 地址](addresses.md)
- [端口转发](port-forwarding.md)
