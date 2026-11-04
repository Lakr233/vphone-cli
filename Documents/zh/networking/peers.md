# 虚拟机互访

同一台 Mac 上的 `nat` 虚拟机可以直接互相访问，包括 Bonjour。虚拟 Apple Watch 就是这样与虚拟 iPhone 配对的。本页介绍如何把某台虚拟机隔离开。

## 隔离虚拟机

```sh
vphone-cli vm config <name> --nat-peers off   # isolate this guest again
vphone-cli vm config <name> --nat-peers on    # the default
```

在 Launchpad 中，对应虚拟机 Network（网络）设置中的“Reach other NAT machines”。更改在下次启动时生效。

被隔离的客户机可以访问 Mac 和互联网，但无法访问其他虚拟机。隔离是每台虚拟机自身网络连接的设置，因此选择退出的虚拟机无论其他虚拟机如何设置，都会保持隔离。

## 虚拟机所在的网络

| 设置 | 共享网络 | Mac 的地址 |
| --- | --- | --- |
| `--nat-peers on`（默认） | `192.168.65.0/24` | `192.168.65.1` |
| `--nat-peers off` | `192.168.64.0/24` | `192.168.64.1` |

[固定地址](addresses.md)（`--ip`）必须位于虚拟机所加入的网络上。固定地址在第一个网络（`192.168.64.0/24`）上的虚拟机会保持隔离，除非它请求与其他虚拟机互访，此时它需要第二个网络上的地址。

## 背景

默认情况下，Virtualization.framework 会在 Mac 的共享网络上把每个 `nat` 客户机与其他客户机隔离开。vphone 关闭了这种隔离，vmnet 随后会把可以互访的虚拟机放到第二个共享网络上，即紧接在第一个网络之后的地址块。这个开关是 Virtualization.framework 的私有接口；不支持它的版本会让所有客户机保持隔离，并在虚拟机启动时给出提示。

## 另请参阅

- [网络](overview.md)
- [MAC 与 IP 地址](addresses.md)
- [网络上的名称](names.md)
