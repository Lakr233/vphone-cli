<div align="right"><a href="../README.md">English</a> · <a href="README_zh.md">中文</a> · <strong>日本語</strong> · <a href="README_ko.md">한국어</a></div>

# vphone-cli

> [!WARNING]
> バージョン 2.0 は開発中です。安定版が必要な場合は [1.0.14](https://github.com/Lakr233/vphone-cli/tree/1.0.14) を使用してください。

Apple Silicon Mac 上で仮想 iPhone を作成・実行します。vphone-cli は Apple の Virtualization.framework と PCC 研究用 VM 基盤を使用します。

![macOS 上で動作する仮想 iPhone](demo.jpeg)

バージョン 2.0 では、1.0 の負担が大きく複雑なホスト設定を大幅に減らし、カスタムファームウェアに必要なシステム修正を整理しました。基本の流れが安定してきたため、構成は **JB の 1 種類**に絞っています。自己完結した `VPhone.bundle` の CLI から、ファームウェアのダウンロード、インストール、起動まで行えます。

現時点で推奨するホスト設定は、macOS 復旧環境で `csrutil enable --without debug` と `csrutil allow-research-guests enable` を実行する方法です。SIP は有効のまま、デバッグの制限を緩和します。AMFI に VM バイナリを許可させるには root 権限が必要です。手順は[ホストの設定](Guides/host-setup.md)、仕組みは [amfi-allow の研究資料](https://github.com/Lakr233/amfi-allow)を参照してください。今後の `vphone-ui.app` ではセットアップを簡単にし、インストール時の修正を切り替えられるようにする予定です。

## はじめに

macOS 15 以降の Apple Silicon Mac、ソースからのビルドに使う Xcode、iPhone の復元 IPSW、互換性のある cloudOS IPSW が必要です。[ホストの設定](Guides/host-setup.md)で VM に必要なプライベート権限を許可し、[検証済みのファームウェアの組み合わせ](Guides/compatibility.md)を確認してください。macOS VM の中でゲストを動かすことはできません。

```sh
git clone https://github.com/Lakr233/vphone-cli.git
cd vphone-cli
xcodebuild -workspace VPhone.xcworkspace -scheme VPhone \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/XcodeBundle build
export PATH="$PWD/.build/XcodeBundle/Build/Products/Debug/VPhone.bundle/Contents/MacOS:$PATH"

vphone-cli host preflight
vphone-cli vm create myphone \
  --iphone-source /path/to/iPhone17,3_Restore.ipsw \
  --cloudos-source /path/to/cloudOS.ipsw
vphone-cli vm launch myphone
```

`vm create` はゲストの準備と復元、JB システム変更の導入、`vphoned` の応答確認を行います。確認用の起動は完了後に停止します。使用するには `vm launch` で VM ウィンドウを開いてください。作成にはネットワーク接続、CFW のインストールには管理者権限が必要です。詳しくは[作成と起動のガイド](Guides/create-and-run.md)を参照してください。

2.x 版で起動できるのは `schemaVersion=2` 形式で作成された VM だけです。旧版の VM は作り直す必要があります。

## カスタムファームウェアの Bootstrap

VM を起動したら、macOS のメニューバーで **Guest > Install Bootstrap…** を選び、環境のレイアウトを選択します。これによりゲスト内に Irisin がインストールされます。

初回の環境準備では、Irisin で `coreutils`、`debianutils`、`dash` などの基本パッケージを選択します。**Install** ボタンを長押しし、**Bootstrap Install** を選んでください。このモードでは、選択したすべてのパッケージを先に展開してからインストール処理を再実行します。これにより、`debianutils` には `bash` が必要で、`bash` には設定済みの `debianutils` が必要という初期段階の依存関係を回避できます。基本パッケージの導入後は通常のインストールを使用できます。

## 日常の操作

VM ウィンドウにはアプリとファイルの閲覧、クリップボードと設定の操作、スクリーンショット、録画、診断機能があります。ローカルの自動化には `--api-listen 127.0.0.1:8765` を指定して起動します。詳しくは[ゲスト API](../Research/vphoned_http_api.md)を参照してください。

| 操作 | コマンド |
| --- | --- |
| VM の一覧 | `vphone-cli vm list` |
| VM の情報 | `vphone-cli vm info myphone` |
| VM ウィンドウの起動 | `vphone-cli vm launch myphone` |
| VM の停止 | `vphone-cli vm stop myphone` |
| バックアップの書き出し | `vphone-cli vm export myphone --out myphone.tzst` |
| バックアップの読み込み | `vphone-cli vm import myphone.tzst --name restored` |

VM は標準で `~/.vphone/` に保存されます。その他のコマンドは `vphone-cli <group> --help` で確認できます。

## 構成

`vphone-cli` はファームウェアの準備、VM の復元と管理を担当します。bundle 内の `vphone-vm` がゲストを実行し、macOS ウィンドウを管理します。ゲスト内の `vphoned` はウィンドウ操作と、任意で公開する HTTP・WebSocket API を提供します。Xcode の `VPhone` scheme は自己完結した `VPhone.bundle` をビルドして検証します。

## リポジトリ案内

| パス | 内容 |
| --- | --- |
| [`VPhoneExecutable/`](../VPhoneExecutable/) | CLI、VM プロセス、ファームウェアパッチ、復元処理 |
| [`VPhoneKit/`](../VPhoneKit/) | ホスト側の共通ライブラリと API クライアント |
| [`VPhoneDaemon/`](../VPhoneDaemon/) | ゲスト制御デーモン `vphoned` |
| [`VPhoneGuestComponents/`](../VPhoneGuestComponents/) | ゲスト用フックと補助バイナリ |
| [`Documents/`](README.md) | 設定、使用方法、互換性、トラブルシューティング |
| [`Research/`](../Research/README.md) | パッチと実装に関する研究記録 |

## 謝辞

- [wh1te4ever/super-tart-vphone-writeup](https://github.com/wh1te4ever/super-tart-vphone-writeup)
