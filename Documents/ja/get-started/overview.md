# 概要

vphone-cli は Apple Silicon Mac で仮想 iPhone を実行します。このページでは、vphone-cli でできること、Mac に必要なもの、各プログラムの役割を説明します。

> [!WARNING]
> 本プロジェクトは、暗号資産やトークンを発行したことも、その発行を許可したこともありません。また、暗号資産による支払いや寄付は受け付けていません。本プロジェクトの名をかたって発行・宣伝されるものや、本プロジェクトとの関係をうたう暗号資産・トークンは、すべて詐欺です。

![macOS 上で動作する仮想 iPhone](../../demo.jpeg)

vphone-cli は Apple の Virtualization.framework と PCC 研究用仮想マシンを使って iOS を実行します。セキュリティ研究、リバースエンジニアリング、デバッグのためのツールです。

## 機能

- **グラフィカルウィンドウ：** Mac 上で仮想 iPhone の画面を操作し、アプリとファイルを閲覧し、スクリーンショットの撮影や画面収録ができます。
- **カスタムファームウェア：** システムにはあらかじめパッチが適用されており、[パッケージ環境](../machines/package-environment.md)をインストールできます。
- **バックアップと複製：** 仮想マシンの書き出し、読み込み、複製ができます。
- **自動化 API：** 任意で有効にできる、ローカルの HTTP と WebSocket のインターフェースです。[自動化 API](../machines/automation-api.md) をご覧ください。
- **追加の依存なし：** 実行時に Xcode、Python、Homebrew は不要です。

## 必要なもの

- macOS 15 以降を搭載した物理 Apple Silicon Mac。macOS の仮想マシン上では動作しません。
- 空きディスク容量。仮想マシンごとに標準で 64 GB の仮想ディスクを使い、ファームウェアにも別途容量が必要です。
- ネットワーク接続。システムの復元時に署名チケットをオンラインで取得します。
- セキュリティ設定の変更。macOS 復旧で起動し、ターミナルで次のコマンドを実行してから再起動します。

  ```sh
  csrutil enable --without debug
  csrutil allow-research-guests enable
  ```

  SIP は有効のまま、デバッグの制限だけを緩和します。詳しくは[ホストの設定](host-setup.md)をご覧ください。

## 4 つのプログラム

| プログラム | 役割 |
| --- | --- |
| `vphone-launchpad` | `VPhone.bundle` のダウンロードとインストール、ホストの設定を行う Mac アプリです。別途配布されます。 |
| `vphone-cli` | ファームウェアの準備、パッチの適用、システムの復元、仮想マシンの管理を行います。 |
| `vphone-vm` | 仮想マシンを実行し、そのウィンドウを表示します。 |
| `vphoned` | 仮想マシン内の制御サービスです。ウィンドウの機能と API はこれを通じて動作します。 |

`vphone-cli`、`vphone-vm`、`vphoned` は `VPhone.bundle` にまとめて同梱されています。Launchpad はこのバンドル内の `vphone-cli` を使って各仮想マシンを操作します。ターミナルから `vphone-cli` を直接実行することもできます。

## 関連項目

- [クイックスタート](quick-start.md)
- [ホストの設定](host-setup.md)
- [ダウンロード](downloads.md)
- [仮想マシンの作成と実行](../machines/create-and-run.md)
