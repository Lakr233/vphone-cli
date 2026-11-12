# vphone マニュアル

vphone を初めて使う場合は、[概要](get-started/overview.md)を読んでから[クイックスタート](get-started/quick-start.md)の手順に従ってください。

## はじめに

| ページ | 内容 |
| --- | --- |
| [概要](get-started/overview.md) | vphone の概要、必要な環境、同梱されるプログラム |
| [クイックスタート](get-started/quick-start.md) | Launchpad またはコーディングエージェントで最初の仮想マシンを作る |
| [ホストの設定](get-started/host-setup.md) | Mac の SIP、AMFI、Research Guests の設定 |
| [ダウンロード](get-started/downloads.md) | 公証済みの Launchpad バージョンと対応する `VPhone.bundle` バージョン |

## マシン

| ページ | 内容 |
| --- | --- |
| [作成と実行](machines/create-and-run.md) | ターミナルでの仮想マシンの作成、起動、停止 |
| [ブート ROM](machines/boot-roms.md) | OpenAVB/OpenSEP と Apple の ROM の切り替え |
| [自動化 API](machines/automation-api.md) | 任意で有効にできるローカルの HTTP と WebSocket インターフェース |
| [デバイス名と時計](machines/device-name-and-clock.md) | ゲストが仮想マシン名と Mac の時計から受け取るもの |
| [パッケージ環境](machines/package-environment.md) | ゲストへのパッケージマネージャのインストールと削除 |
| [Cryptex](machines/cryptexes.md) | trusted darwinOS ゲストへの独自プログラムの cryptex としてのインストール |

## ファームウェアとデバイス

| ページ | 内容 |
| --- | --- |
| [互換性](firmware/compatibility.md) | 検証済みの iPhone と cloudOS のファームウェアの組み合わせ |
| [ファームウェアの準備](firmware/firmware-preparation.md) | GPU ドライバの復元、新しい cloudOS 向けの kernelcache ミックス |
| [その他の iPhone モデル](firmware/iphone-models.md) | 別の iPhone モデルの IPSW で iOS を実行する |
| [iPadOS ゲスト](firmware/ipados.md) | iOS の代わりに iPadOS を実行する |

## ストレージとバックアップ

| ページ | 内容 |
| --- | --- |
| [ライブラリとバックアップ](storage/library-and-backups.md) | 仮想マシンとキャッシュの保存場所、複製と書き出し |
| [スナップショット](storage/snapshots.md) | 停止中の仮想マシンのディスクを保存し、その状態に戻す |
| [テンプレート](storage/templates.md) | 1 回の復元を複数の仮想マシンで再利用する |
| [テンプレートの作成](storage/template-building.md) | 仮想マシンをテンプレートにする方法とテンプレートの検索 |
| [ディスク容量の共有](storage/sharing-disk-space.md) | 別々に復元した仮想マシンに使う `vm rebase` |
| [複数マシンの一括作成](storage/many-machines.md) | plist から実行する `vm create-bulk` |
| [シェーダキャッシュ](storage/shader-cache.md) | 既存の仮想マシンでの永続シェーダキャッシュ |

## ネットワーク

| ページ | 内容 |
| --- | --- |
| [ネットワークモード](networking/overview.md) | モードの選択、実行中の仮想マシンのネットワーク切断 |
| [トンネルモード](networking/tunnel.md) | VPN やプロキシアプリを使っている Mac |
| [MAC アドレスと IP アドレス](networking/addresses.md) | 保存された MAC、古いリース、固定アドレス |
| [ポート転送](networking/port-forwarding.md) | Mac のポートをゲストに転送する |
| [ネットワーク上の名前](networking/names.md) | ゲストの `.local` 名と、ゲスト内での Mac の名前 |
| [マシン同士の通信](networking/peers.md) | 1 つの共有ネットワーク上の `nat` マシン |

## Launchpad とバンドル

| ページ | 内容 |
| --- | --- |
| [Launchpad コマンドライン](launchpad/launchpad-cli.md) | `vphone-launchpad-cli` で Launchpad を操作する |
| [Core Bundle とローカルビルド](launchpad/core-bundles.md) | マシンとバンドルの紐付け、ローカルビルドのテスト |
| [バンドルの組み込み](launchpad/bundle-integration.md) | `VPhone.bundle` の中身と、アプリからの使い方 |

## ヘルプ

| ページ | 内容 |
| --- | --- |
| [トラブルシューティング](help/troubleshooting.md) | 起動の拒否、復元の失敗、ゲストの問題 |

実装メモ、パッチの記録、API の完全なリファレンスは[研究記録](../../Research/README.md)にあります（英語のみ）。
