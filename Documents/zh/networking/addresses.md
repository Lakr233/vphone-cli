# MAC 与 IP 地址

本页介绍客户机保存的 MAC 地址、如何释放旧 MAC 地址仍占用的 DHCP 租约，以及如何为客户机设置固定 IPv4 地址。

## MAC 地址

首次启动时，客户机的网卡会获得一个随机的本地管理 MAC 地址，并像机器标识符一样保存在 `config.plist` 中。这样客户机在多次启动之间始终保持同一个身份和同一个 DHCP 租约。

设置或更换 MAC 地址：

```sh
vphone-cli vm config <name> --mac 02:11:22:33:44:55
vphone-cli vm config <name> --mac random   # a new one now
vphone-cli vm config <name> --mac auto     # a new one at the next launch
```

克隆的虚拟机会像保留机器标识符一样保留原虚拟机的 MAC 地址。要同时运行两者，请用 `vm clone --new-identity` 克隆（这会给副本新的身份和 MAC 地址），或者为副本设置新的 MAC 地址。`--new-identity` 还会清除副本的固定地址、端口转发和 mDNS 名称。

## 旧 MAC 地址占用的地址

症状：在 `nat` 模式下，新客户机获得的地址越来越大，直到撞上你在地址范围高位设置的固定地址。

列出共享网络上的租约及各自的所有者，然后释放孤立租约（需要 `VPhone.bundle` 2.5 或更新版本）：

```sh
vphone-cli vm leases
sudo vphone-cli vm leases --release-orphans
```

通过 Launchpad：

```sh
vphone-launchpad-cli vm leases
vphone-launchpad-cli vm leases --release
```

在 Launchpad 窗口中，Host Setup（宿主机设置）会在 NAT Network 下显示孤立租约的数量，点击 Release… 并经管理员批准后即可释放。Launchpad 会与它列出的每个资料库进行比对。

孤立租约是指 iOS 或 iPadOS 客户机的租约，其 MAC 地址不属于资料库中的任何虚拟机，且租约已经过期。`--release-orphans` 会从 `/var/db/dhcpd_leases` 中删除孤立租约，并让 DHCP 服务器重新读取该文件，因此需要 root 权限。它永远不会改动：

- 虚拟机自己的租约，即使该租约在虚拟机停止期间已经过期；
- 尚未过期的租约，例如刚更换了 MAC 地址的运行中客户机的租约；
- 其他虚拟机 App 的租约，或者通过互联网共享连接的设备的租约。

其他资料库中的虚拟机只有在同时指定了该资料库时才会计入：每个资料库都要重复一次 `--library-root`。如果某个资料库中没有虚拟机，或者某台虚拟机的设置无法读取，释放操作会拒绝执行，因为此时那里的每个租约看起来都是孤立的。

原因：Mac 的 DHCP 服务器会让每个地址始终绑定到最初分配给它的 MAC 地址，即使租约已过期也是如此；只有当范围内的其他地址都已被占用时，才会把它分配给别人。删除虚拟机或更换其 MAC 地址后，它的地址仍绑定到一个不再使用的 MAC 地址；在开始保存 MAC 地址之前进行的每次启动也是如此。

## 固定地址

`--ip` 为客户机设置固定 IPv4 地址。不带前缀长度时默认为 `/24`。`--gateway` 和 `--dns` 是可选的；设为 `auto` 会恢复默认值。`--ip dhcp` 删除固定地址。

```sh
vphone-cli vm config <name> --ip 192.168.65.50
vphone-cli vm config <name> --network tunnel --ip 10.20.0.5/16 --dns 1.1.1.1
vphone-cli vm config <name> --ip dhcp
```

地址如何传给客户机取决于网络模式：

| 模式 | 地址 | 应用方式 |
| --- | --- | --- |
| `nat` | 位于 Mac 的共享 NAT 网络上：通常是 `192.168.65.0/24`，设置了 `--nat-peers off` 的虚拟机则是 `192.168.64.0/24`（见[虚拟机互访](peers.md)） | vphoned 把它写入客户机的网络设置。网关和 DNS 都是 Mac，即 `192.168.65.1` 或 `192.168.64.1`。 |
| `tunnel` | 任意私有子网 | 由隧道自己的 DHCP 分配。网关同时也是 DNS 解析器，默认为子网的第一个地址，除非 `--gateway` 指定了其他地址。 |
| `bridged` | 物理网络上的地址 | vphoned 把它写入客户机。请把 `--gateway` 和 `--dns` 设为该网络自己的值。 |

> [!TIP]
> 共享 `nat` 网络上的地址不会在 Mac 的 DHCP 服务器中预留。请在范围高位选择一个地址（例如 `.200`），这样的地址不太可能已被 DHCP 分配给其他虚拟机。

在 `nat` 模式下，地址必须位于虚拟机所加入的共享网络上：可以互访的虚拟机（默认）使用第二个网络（`192.168.65.0/24`），设置了 `--nat-peers off` 的使用第一个网络（`192.168.64.0/24`）。如果 vmnet 的 `Shared_Net_Address` 被移动过，两者都会随之变化。要使用其他子网，请使用 `tunnel`。

每次 `vphone-vm` 连接到 vphoned 时，vphoned 都会应用该地址，因此客户机中的地址如果在 Mac 不知情时被改动，也会被改回来。它只撤销自己的设置：虚拟机改回 DHCP 时，在客户机“设置”App 中手动输入的地址不会被改动。

macOS 26 可以为虚拟机提供独立的 NAT 网络，但虚拟机停止后该子网仍会被保留（测试中 40 分钟后仍被保留），在此期间所有使用它的启动都会失败，因此 vphone 不使用这一功能。

## 另请参阅

- [网络](overview.md)
- [端口转发](port-forwarding.md)
- [虚拟机互访](peers.md)
