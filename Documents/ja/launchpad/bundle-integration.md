# VPhone バンドルの組み込み

このページは、`vphone-launchpad` のように `VPhone.bundle` を同梱したり操作したりするアプリケーションを作る人向けです。バンドルの中身と、組み込む側のアプリケーションが担う責任について説明します。

## ビルドと検証

```sh
xcodebuild -workspace VPhone.xcworkspace -scheme VPhone \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/XcodeBundle build
```

`VPhone` スキームが `VPhone.bundle` を生成し、ビルドの一部として `ValidateBundle.sh` がそれをチェックします。

## 組み込み方

- バンドルはそのままの形で保ち、`Contents/MacOS/vphone-cli` をプロセスとして起動します。バンドルは実行ファイルとリソースのコンテナであり、macOS のアプリでも動的に読み込むプラグインでもありません。CLI は、自身の実行ファイルのパスを解決して、対になる `vphone-vm` を見つけます。
- バンドル全体を、バージョン付きの 1 つの単位としてインストールし更新します。署名済みのバイナリをその場で書き換えないでください。
- `vphone-vm` が変わると cdhash も変わります。新しいビルドを起動する前に、AMFI での許可を手配してください。
- ダウンロード、リリースの検証、ホストでの実行許可、インストールと更新のポリシーは、組み込む側のアプリケーションが担います。デベロッパツールへのアクセスと AMFI の許可は、それぞれ別のホスト側の判断です。
- 仮想マシンのライブラリとキャッシュは `VPhone.bundle` の外、標準では `~/.vphone` に置かれます。ホスト側の仮想マシンの出力はモード `0777` を使うため、root で実行した作成処理の後でも、別のワークステーションプロセスからアクセスできます。`Disk.img` 内のゲストのファイルシステムのアクセス権は、独自の意味を保ちます。

## バンドルの中身

| パス | 役割 |
| --- | --- |
| `Contents/MacOS/vphone-cli` | エンタイトルメントを持たないコマンドのエントリポイント |
| `Contents/MacOS/vphone-vm` | 仮想マシンとウィンドウのプロセス。非公開の仮想化エンタイトルメントを持ちます |
| `Contents/MacOS/vphone-escalator` | 現在の仮想マシンの cdhash 用の AMFI 許可リストツール |
| `Contents/MacOS/libswiftCompatibilitySpan.vphone.dylib` | macOS 15 上の `vphone-vm` 用の Swift バックデプロイライブラリ |
| `Contents/Resources/guest-resources/vphoned` | 独自のエンタイトルメントを持つ署名済みのゲストデーモン。バンドルに未署名のコピーは含まれません |
| `Contents/Resources/guest-resources/*.dylib` | ゲストライブラリ：launchd フック、SystemHook、カメラフック、GPU コンパイラプラグイン、[`VPhoneGuestComponents`](../../../VPhoneGuestComponents/README.md) に記載された修正とデバイスアダプタ |
| `Contents/Resources/guest-resources/*.plist` | ゲストの launch daemon の構成、カメラフックと MISFix のフィルタ |
| `Contents/Resources` | ローカライズされた文字列。署名スクリプトやエンタイトルメントファイルは同梱されません |

`Contents/MacOS` には Mac 上で動作するプログラムだけが入ります。`guest-resources` にはゲストにインストールされるファイルだけが入り、その中の Mach-O はすべて iOS 向けにビルドされています。`ValidateBundle.sh` がこの 2 つの規則を強制します。

## 署名

実行可能なペイロードはすべてアドホックのコード署名を使います。非公開のエンタイトルメントを持つのは、それを必要とする子プロセスだけです。バンドルには `CFBundleExecutable`、アプリランチャー、SMJobBless ヘルパー、インストーラ、パスワード入力、自動的な root 権限の取得のいずれもありません。

## プライバシーの許可

macOS は、責任プロセスに代わってプライバシーの許可（マイク、位置情報）を求め、その許可をプロセスのコード署名に紐付けます。

- 責任を放棄した状態で `vphone-cli` を起動すると、`vphone-cli` が `vphone-vm` の責任プロセスになります。`vphone-cli` はアドホック署名なので、バンドルを新しくビルドするたびに再び許可を求められます。
- 署名が変わらないプロセスの通常の子プロセスとして、責任を放棄せずに `vphone-cli` を起動すると、許可を求められるのは一度だけです。

Launchpad は、自身の `Contents/MacOS` に含まれる `vphone-launchpad-launcher` を使って後者の方法を取っています。macOS はそこにあるツールを、それを含むアプリに帰属させるため、許可の確認、利用目的の説明、許可はそのアプリのものになります。Hardened Runtime では、アプリのメイン実行ファイルが対応するリソースエンタイトルメント（`com.apple.security.device.audio-input`、`com.apple.security.personal-information.location`）を持っている必要があります。持っていない場合、macOS は確認せずに要求を拒否します。

## バージョンの互換性

Launchpad は、`minimumBundleComponents`（[`VPhoneLaunchpad/VPhoneLaunchpadShared/VPhoneLaunchpadBundleStore.swift`](../../../VPhoneLaunchpad/VPhoneLaunchpadShared/VPhoneLaunchpadBundleStore.swift) で設定）より古いバンドルを拒否し、古いバンドルのレイアウトは読み込みません。バンドル 2.1.0 で、パッチプリセット（`fw patches`、`fw set-patches`、`fw patch --preset`）と `vphone-escalator` 実行ファイルが追加されました。

## 関連項目

- [Core Bundle とローカルビルド](core-bundles.md)
- [Launchpad コマンドライン](launchpad-cli.md)
- [ホストの設定](../get-started/host-setup.md)
