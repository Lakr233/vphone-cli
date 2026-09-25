<div align="right"><a href="../README.md">English</a> · <a href="README_zh.md">中文</a> · <strong>日本語</strong> · <a href="README_ko.md">한국어</a></div>

# vphone-cli

> 旧バージョンの vphone-cli 1.x をお探しの場合は、[1.0.14 のリリース](https://github.com/Lakr233/vphone-cli/releases/tag/1.0.14)をご覧ください。

Apple Silicon Mac 上で仮想 iPhone を作成・実行します。vphone-cli は Apple の Virtualization.framework と PCC 研究用 VM 基盤を使用します。

![macOS 上で動作する仮想 iPhone](demo.jpeg)

バージョン 2.x では、以前 EXP として提供していた変更を含む、ファームウェアの完全なパッチセットを適用します。パッチ構成は選択できません。自己完結した `VPhone.bundle` がファームウェアの準備、復元、VM の制御を担い、`vphone-launchpad` が bundle のインストールと VM の作成・起動を案内します。

推奨するホスト設定では、macOS 復旧環境で `csrutil enable --without debug` と `csrutil allow-research-guests enable` を実行します。SIP を有効に保ちつつ、デバッグの制限を緩和します。Launchpad はホストを確認し、特権ヘルパーを使用して検証済みの VM バイナリを AMFI に許可します。詳しくは[ホストの設定](Guides/host-setup.md)をご覧ください。

## はじめに

macOS 15 以降を搭載した物理 Apple Silicon Mac では、公証済みの [vphone-launchpad 2.0.6](https://github.com/Lakr233/vphone-cli/releases/download/2.0.6/vphone-launchpad-2.0.6-notarized.zip) を使用してください。リリース版の実行に Xcode、Python、Homebrew は不要です。

1. macOS 復旧環境で `csrutil enable --without debug` と `csrutil allow-research-guests enable` を実行し、再起動します。詳しくは[ホストの設定](Guides/host-setup.md)をご覧ください。
2. アーカイブを展開してアプリを開きます。**Host Setup** の案内に従い、開発者ツールへのアクセスを許可して特権ヘルパーをインストールします。
3. **Core Bundle** で **Download and Install** を選び、最新の `VPhone.bundle` をインストールします。Launchpad はダウンロードを検証し、VM バイナリをホストで使用できるようにします。
4. **Machines** で **New Machine** を選び、カタログからファームウェアの組み合わせを選択して **Create** をクリックします。Launchpad が初回起動を確認した後も、VM は実行されたままです。

カタログの組み合わせを選ぶと、ファームウェアがダウンロードされます。ローカルの IPSW を使う場合も、VM の作成には復元チケット取得のためのネットワーク接続と十分な空き容量が必要です。互換性のある iPhone と cloudOS の IPSW を自分で指定することもできます。検証済みの組み合わせは[互換性ガイド](Guides/compatibility.md)をご覧ください。ソースからのビルドとターミナルでの操作は[ホストの設定](Guides/host-setup.md)と[作成と起動のガイド](Guides/create-and-run.md)を参照してください。

2.x 版で起動できるのは `schemaVersion=2` 形式で作成された VM だけです。旧版の VM は作り直す必要があります。

## カスタムファームウェアの Bootstrap

VM を起動したら、macOS のメニューバーで **Guest > Install Bootstrap…** を選び、環境のレイアウトを選択します。これによりゲスト内に Irisin がインストールされます。
Option キーを押しながらこのメニューを開くと、ローカルの Irisin `.deb` を選択できます。**Uninstall Bootstrap…** の Option メニューは rootless と RootHide の両環境を削除し、ゲストを再起動しません。通常の削除では再起動します。

初回の環境準備では、Irisin で `apt` と `bash` を選択します。**Install** ボタンを長押しし、**Bootstrap Install** を選んでください。このモードでは、今回のインストールに含まれるすべてのパッケージを先に展開してからインストール処理を再実行します。これにより、`debianutils` には `bash` が必要で、`bash` には設定済みの `debianutils` が必要という初期段階の依存関係を回避できます。初回の準備後は通常のインストールを使用できます。

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
