# ネットワーク

各仮想マシンには 1 つのネットワークモードがあります。このページでは、モードの選び方と、実行中の仮想マシンのネットワークを切断する方法を説明します。このセクションのほかのページでは、トンネルモード、アドレス、ポート転送、名前、マシン同士の通信を扱います。

## ネットワークモード

| モード | ゲストがインターネットに接続する方法 | 使う場面 |
| --- | --- | --- |
| `nat` | Virtualization.framework に組み込まれた NAT | 標準です。Mac で VPN を使っていない場合、または VPN でゲストの通信を運ぶ必要がない場合。 |
| `bridged` | Mac の物理インターフェースに直接つながり、そのネットワーク上に独自のアドレスを持つ | LAN 上のほかのマシンからゲストに到達できる必要がある場合。 |
| [`tunnel`](tunnel.md) | `vphone-vm` が Mac 上で開く通常の接続を通じて | Mac の通信が VPN やプロキシアプリを経由していて、ゲストの通信もそれに従う必要がある場合。 |
| `none` | ネットワークデバイスなし | ゲストをオフラインのままにする必要がある場合。 |

モードは仮想マシンの `config.plist` に保存され、仮想マシンの起動時に読み込まれるため、変更は次回の起動から反映されます。

## モードを選ぶ

Launchpad では：

1. マシンを停止します。
2. `⋯` メニューまたは右クリックメニューから Settings… を選びます。
3. Network セクションでモードを選びます。

New Machine では、Advanced Options でモードを設定します。マシンを 1 台選択している場合、Settings… には Address と Port Forwarding のセクションもあります。

コマンドラインでは：

```sh
vphone-cli vm config <name> --network tunnel
# or through Launchpad
vphone-launchpad-cli exec vm config <name> --network tunnel
```

`tunnel` を使うには、`vphone-cli vm config --help` に `tunnel` が表示される `VPhone.bundle` が必要です。古いバンドルはこの設定を拒否します。

## 実行中の仮想マシンのネットワークを切断する

`vm network` は実行中の仮想マシンに対して動作し、その操作は何も保存されません。

```sh
vphone-cli vm network <name>               # state of the NIC
vphone-cli vm network <name> --link down   # unplug the cable
vphone-cli vm network <name> --link up     # plug it back in
```

ゲストからは、リンクが切れて再びつながったように見えます。同じリクエストは、`vphone.sock` でも `{"t":"network"}` に `"link":"down"` または `"link":"up"` を付けて送れます。

> [!NOTE]
> 実行中の仮想マシンを別のネットワークに移すことはできません。Virtualization はその変更を受け付けた後、内部エラーで仮想マシンを停止してしまうため、`vm network` は仮想マシンが起動時に使っていたネットワークにつなぎ直すことしかできません。モードを変更するには、`vm config` を使って仮想マシンを再起動してください。

## 関連項目

- [トンネルモード](tunnel.md)：VPN やプロキシアプリを使っている Mac
- [MAC アドレスと IP アドレス](addresses.md)：保存された MAC、古い MAC が保持するリース、固定アドレス
- [ポート転送](port-forwarding.md)：Mac のポートをゲストに転送する
- [ネットワーク上の名前](names.md)と[マシン同士の通信](peers.md)
