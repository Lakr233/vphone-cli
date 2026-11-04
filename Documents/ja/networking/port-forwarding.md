# ポート転送

`nat` モードと `tunnel` モードで Mac のポートをゲストに転送するには、`--forward` を使います。`bridged` ではゲストが独自のアドレスで LAN に参加するため、転送は必要ありません。

## 転送の追加と削除

```sh
vphone-cli vm config <name> --forward tcp:8022:22
vphone-cli vm config <name> --forward udp:0.0.0.0:5353:53
vphone-cli vm config <name> --remove-forward 8022
vphone-cli vm config <name> --clear-forwards
```

形式は次のとおりです。

```text
[tcp|udp:][host-address:]host-port:guest-port
```

| 要素 | 意味 |
| --- | --- |
| `tcp` または `udp` | プロトコル |
| `host-address` | Mac 上で転送がリッスンするアドレス。標準は `127.0.0.1` です。`0.0.0.0` にすると LAN 上のほかのデバイスから到達できるようになります。 |
| `host-port` | Mac 上のポート |
| `guest-port` | ゲスト内のポート |

複数のポートを転送するには、`--forward` を繰り返します。Launchpad では、マシンの Settings… に Port Forwarding セクションがあります。

## 転送の動作

- `vphone-vm` は、仮想マシンの起動時にリスナーを開き、停止時に閉じます。
- `nat` モードでは、ゲストのアドレス（[固定アドレス](addresses.md)、または vphoned が報告するアドレス）に接続します。
- `tunnel` モードでは、接続はゲートウェイから来たものとしてゲストに届きます。
- Mac ですでに使われているポートは仮想マシンのログに記録されてスキップされ、ほかの転送は引き続き動作します。

## 関連項目

- [ネットワーク](overview.md)
- [トンネルモード](tunnel.md)
- [MAC アドレスと IP アドレス](addresses.md)
