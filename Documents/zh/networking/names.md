# 网络上的名称

本页介绍两个名称：客户机自己的 `.local` 名称，让 Mac 可以按名称访问它；以及客户机解析出的这台 Mac 的 `.local` 名称。

## 客户机的名称（mDNS）

默认关闭。开启后即可按名称访问客户机：

```sh
vphone-cli vm config <name> --mdns on
ping <vm-name>.local
```

| 设置 | 作用 |
| --- | --- |
| `--mdns on` | 客户机响应 `<vm-name>.local`。虚拟机名称中字母和数字以外的字符都会变成连字符：`ipad_pro.13` 会变成 `ipad-pro-13.local`。 |
| `--mdns <name>` | 客户机响应你指定的其他名称。 |
| `--mdns off` | 恢复客户机自己的名称。 |

该名称在所有模式下都有效，包括 `none`：

| 模式 | `<name>.local` 解析为 |
| --- | --- |
| `nat` | 客户机在共享网络上的地址，以及它的 USB 链路地址 |
| `bridged` | 客户机的局域网地址（局域网中的每台设备都能解析），以及它在 Mac 上的 USB 链路地址 |
| `tunnel`、`none` | 客户机的 USB 链路地址，仅限 Mac 上 |

除了网卡之外，客户机还有一条网络链路，就像通过 USB 连接的 iPhone 提供给 Mac 的那样。它在 Mac 上显示为一个带 `169.254` 地址的 `en` 接口。这个地址是链路本地地址，但 Mac 可以直接通过它访问客户机，因此在 `tunnel` 模式下，连接 `<name>.local` 无需端口转发即可访问客户机上的服务。

注意事项：

- 如果其他设备已在使用该名称，mDNS 会为客户机改名（`name-2`）。
- `vm rename` 会重命名由 `--mdns on` 根据虚拟机名称生成的名称；你手动指定的名称保持不变。
- 用 `vm stop` 或关闭窗口停止的虚拟机无法撤回它的通告。Mac 的解析器会继续返回旧地址，直到缓存的记录过期；主机地址的过期时间为 75 分钟（TTL 4500 秒）。

每次 `vphone-vm` 连接时，vphoned 都会在客户机的网络设置中设置该名称（`LocalHostName`），客户机的 mDNSResponder 会在它的每条链路上通告该名称。

## 客户机中这台 Mac 的名称

默认开启。客户机会立即把这台 Mac 的 mDNS 名称（`scutil --get LocalHostName` 加上 `.local`）解析为它访问 Mac 所用的地址：

| 模式 | 客户机中的 `<Mac>.local` |
| --- | --- |
| `nat` | 共享网络上的 Mac，通常是 `192.168.65.1`（设置 `--nat-peers off` 时为 `192.168.64.1`） |
| `tunnel` | 网关，默认为 `192.168.127.1`。连接它会到达 Mac 的回环地址（`127.0.0.1`），就像 QEMU 和 VirtualBox 中的 `10.0.2.2` 一样 |
| `bridged` | Mac 在桥接接口上的地址 |

撤回该名称：

```sh
vphone-cli vm config <name> --mac-name off
```

查看客户机的解析器返回什么，以及每个地址能否连接：

```sh
vphone-launchpad-cli guest rpc <name> network.resolve '{"host":"<Mac>.local","family":"ipv4","port":8000}'
```

### 为什么需要它

如果只依靠 mDNS，在客户机中对 Mac 名称进行 IPv4 查询可能会失败。客户机还会在 USB 链路上收到 Mac 的响应，而 Mac 在该链路上没有 IPv4 地址，会回答“没有该记录”。哪条链路先回答就决定了查询结果，因此需要 IPv4 地址的 App 会一直收到错误，直到从另一条链路缓存了真正的答案为止。查询结果还会把 Mac 在 USB 链路上的 `169.254` 地址排在最前面；iOS 通过主接口路由 `169.254.0.0/16`，因此连接该地址的普通套接字可能会从 `en0` 发出，而那里没有任何响应，只能等到超时。

vphoned 会把该名称作为本地记录注册到客户机自己的 mDNSResponder 中，效果类似 `/etc/hosts` 中的一行：它会立即用这一个地址回答 IPv4 查询，既不询问网络，也不使用已缓存的答案。每次 `vphone-vm` 连接时它都会这样做，vphoned 启动时也会再做一次，因此重启后在 App 运行之前名称就已就绪。客户机的系统宗卷是只读的，因此不会编辑 `/etc/hosts` 本身，也不会在任何网络上进行通告。IPv6 查询仍交给 mDNS。

## 另请参阅

- [网络](overview.md)
- [MAC 与 IP 地址](addresses.md)
- [隧道模式](tunnel.md)
