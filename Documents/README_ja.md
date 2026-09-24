<div align="right"><a href="../README.md">English</a> · <a href="README_zh.md">中文</a> · <strong>日本語</strong> · <a href="README_ko.md">한국어</a></div>

# vphone-cli

Apple の Virtualization.framework と PCC 研究用 VM 基盤を使って、仮想 iPhone を起動します。

![macOS 上の仮想 iPhone](demo.jpeg)

公開されているファームウェア構成は **JB のみ**です。必要なシステムパッチとホスト制御用の vphoned を導入します。ゲストのユーザー環境はそのままにし、パッケージマネージャー、SSH、VNC、初回起動時の bootstrap はインストールしません。

## クイックスタート

Apple Silicon、macOS 15 以降、および PV=3 研究用 VM と `vphone-vm` の権限を許可する[ホスト設定](Guides/host-setup.md)が必要です。

```sh
vphone-cli vm create myphone \
  --iphone-source /path/to/iPhone17,3_Restore.ipsw \
  --cloudos-source /path/to/cloudOS.ipsw

vphone-cli vm launch myphone
```

`vm create` は準備、JB パッチ、DFU 復元、CFW インストールを実行し、初回起動で vphoned に ping します。**確認用の起動は成功後に停止します。** 継続して使うには `vm launch` を実行してください。復元にはネットワーク接続、CFW インストールには管理者認証が必要です。

cloudOS 26.4（`23E5207q`）との組み合わせで、iPhone17,3 の iOS 26.6.2（`23G90`）と 27.0（`24A435`）がロック画面に到達し、vphoned ping に応答しました。詳細は[互換性の記録](Guides/compatibility.md)を参照してください。

## インストールとビルド

配布 `.app` の実行に Homebrew、Python、Xcode や別の実行環境は不要です。ソースからのビルドには、vphoned をコンパイルするための iPhoneOS SDK を含む Xcode が必要です。

```sh
git clone https://github.com/Lakr233/vphone-cli.git
cd vphone-cli
zsh Scripts/build.sh
.build/release/vphone-cli host preflight
```

AMFI の許可リストを使う場合、ビルドのたびに[ホストの設定手順](Guides/host-setup.md)に従って署名済み VM バイナリを再登録してください。[ドキュメント一覧](README.md)から現在の手順と研究資料に進めます。詳しいガイドは現在英語です。
