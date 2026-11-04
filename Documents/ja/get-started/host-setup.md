# ホストの設定

エンタイトルメント付きの仮想マシンプロセス `vphone-vm` を実行できるように Mac を準備します。この作業は Mac ごとに 1 回行います。許可リストの手順は、`vphone-vm` の署名が変わるたびに繰り返します。

macOS 15 以降を搭載した Apple Silicon Mac が必要です。PV=3 の研究用ゲストは、入れ子にした macOS 仮想マシンの中では動作しません。

## ホストを確認する

使用する `VPhone.bundle` の事前チェックを実行します。

```sh
vphone-cli host preflight
```

仮想マシンを起動する前に、エンタイトルメント付きの `vphone-vm` をチェックします。AMFI が `vphone-vm` を拒否した場合は、そのバンドル用の `sudo .../vphone-escalator allow .../vphone-vm` コマンドがそのままエラーに表示されます。

## セキュリティ構成を選ぶ

`vphone-vm` は Apple の非公開の仮想化エンタイトルメントを持つため、macOS がそれを受け入れる必要があります。次の 2 つのオプションのどちらでも、macOS 復旧で Research Guests を有効にする必要があります。どちらか 1 つを選んでください。

### オプション A：SIP を有効にしたままデバッグの制限を緩和する

1. macOS 復旧で起動してターミナルを開き、次のコマンドを実行します。

   ```sh
   csrutil enable --without debug
   csrutil allow-research-guests enable
   ```

2. macOS で再起動します。
3. 現在の `vphone-vm` を許可リストに追加します。配布されたバンドルの場合は、`vphone-cli host preflight` を実行し、表示されたコマンドを実行します。ソースのチェックアウトからの場合：

   ```sh
   bundle=.build/XcodeBundle/Build/Products/Debug/VPhone.bundle
   sudo "$bundle/Contents/MacOS/vphone-escalator" allow "$bundle/Contents/MacOS/vphone-vm"
   "$bundle/Contents/MacOS/vphone-escalator" status
   "$bundle/Contents/MacOS/vphone-cli" host preflight
   ```

> [!WARNING]
> `allow` コマンドは、署名だけが変わる再ビルドも含め、ビルドのたびに実行し直してください。許可リストには `vphone-vm` の cdhash が登録されており、署名が変わると cdhash も変わります。

許可リストを元に戻すには：

```sh
sudo "$bundle/Contents/MacOS/vphone-escalator" off
```

`off` は `vphone-escalator` が追加したハッシュだけを削除し、amfid を再起動します。環境設定そのものとその他の値はそのまま残ります。

制限付きのエンタイトルメントが必要な署名済みのホスト用バイナリがほかにもある場合は、同じ `allow` コマンドにまとめて渡せます。エンタイトルメントを持たない `vphone-cli` には不要です。

### オプション B：SIP と AMFI を無効にする

制限がより緩い構成です。

1. macOS 復旧で起動してターミナルを開き、次のコマンドを実行します。

   ```sh
   csrutil disable
   csrutil allow-research-guests enable
   ```

2. macOS で再起動し、ブート引数を設定して、もう一度再起動します。

   ```sh
   sudo nvram boot-args="amfi_get_out_of_my_way=1 -v"
   ```

> [!WARNING]
> このコマンドは既存の `boot-args` を置き換えます。先に `nvram boot-args` で確認してください。

## Launchpad を使う場合

Launchpad のバンドル事前チェックは、SIP のデバッグ制限が無効になっているか（または SIP 全体が無効か）、Research Guests が有効かを確認します。`vphone-escalator` を自分で実行する必要はありません。

- インストールされた `vphone-vm` を AMFI がブロックした場合、Launchpad のヘルパーがそれらのホスト設定を再確認し、root 所有のバンドルとその記録済みの cdhash を検証してから、そのバンドルの `vphone-escalator allow` を root として実行します。その後 Launchpad が事前チェックをやり直します。
- バンドルの新しい署名は、それぞれ個別にチェックされ許可されます。
- 新しい Launchpad に新しいヘルパーが含まれている場合は、起動時にヘルパーを更新するための管理者の認証を求めます。

単体の `vphone-cli` では、引き続き手動で実行するコマンドが表示されます。

## ソースからビルドする

配布される `VPhone.bundle` は、実行時に Homebrew、Python、Xcode を必要としません。ソースからビルドするには、Xcode と、`vphoned` をコンパイルするための iPhoneOS SDK が必要です。チェックアウトしたディレクトリで次を実行します。

```sh
xcodebuild -workspace VPhone.xcworkspace -scheme VPhone \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/XcodeBundle build
.build/XcodeBundle/Build/Products/Debug/VPhone.bundle/Contents/MacOS/vphone-cli host preflight
```

`VPhone` スキームは、すべてのプログラムを含むアドホック署名のバンドルを生成します。オプション A を選んだ場合は、新しくビルドするたびに許可リストに追加してください。

## 許可リストが変更する内容

`vphone-escalator allow` は、AMFI のコード要件の環境設定がなければ作成します。すでにある場合は、その `Entitlements` 要件に現在の `vphone-vm` の cdhash を追加します。ほかの cdhash や環境設定のキーは残し、登録済みのハッシュは追加しません。既存の `AllowUnsafeDynamicLinking` の値には触れず、このキーがない場合にだけ `false` を書き込みます。amfid のヒープの 1 バイトを変更することで、amfid がこの要件を参照するようにします。

## バンドルの中身

- `vphone-cli` は非公開のエンタイトルメントなしで処理全体を取りまとめ、`vphone-cli archive` でアーカイブを扱います。
- `vphone-vm` は署名済みでエンタイトルメントを持つ、仮想マシンとウィンドウのプロセスです。
- `vphoned` はビルド時に iOS 向けにコンパイルされ、作成した各ゲストにインストールされます。

実装の経緯については、[バイナリ分割に関する研究記録](../../../Research/Host/host_binary_split.md)をご覧ください。

## 関連項目

- [クイックスタート](quick-start.md)
- [仮想マシンの作成と実行](../machines/create-and-run.md)
- [トラブルシューティング](../help/troubleshooting.md)
