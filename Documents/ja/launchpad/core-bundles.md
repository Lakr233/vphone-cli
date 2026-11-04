# Core Bundle とローカルビルド

Launchpad の各マシンは、インストールされた 1 つの `VPhone.bundle` のバージョン、つまりその Core Bundle で動作します。このページでは、ローカルビルドをインストールする方法、マシンをそのビルドに移す方法、2 つのビルドを並べて比較する方法を説明します。

## VPhone.bundle のビルドをテストする

1. リポジトリのルートでバンドルをビルドします。

   ```sh
   xcodebuild -workspace VPhone.xcworkspace -scheme VPhone \
     -configuration Debug -destination 'platform=macOS,arch=arm64' \
     -derivedDataPath .build/XcodeBundle build
   ```

2. インストールします。バンドルは `<version>-local.<hash>` としてインストールされて標準のバンドルになり、実行ポリシーの例外が追加され、新しい `vphone-vm` の cdhash が許可され、ホストの事前チェックが実行されます。

   ```sh
   vphone-launchpad-cli bundle install-local .build/XcodeBundle/Build/Products/Debug/VPhone.bundle
   ```

   正確なバージョンは、インストールの結果と `bundle list` に表示されます。

3. 既存のマシンをそのバンドルに移します。`--update-environment` は新しい vphoned とフック用の dylib も配置し直すため、マシンを停止しておく必要があります。

   ```sh
   vphone-launchpad-cli vm set-bundle research-01 2.4.0-local.1a2b3c4d --update-environment
   ```

4. マシンを起動して確認します。

   ```sh
   vphone-launchpad-cli vm start research-01 --wait
   vphone-launchpad-cli guest rpc research-01 device.info
   vphone-launchpad-cli guest rpc research-01 apps.list '{}'
   vphone-launchpad-cli vm log research-01 --lines 100
   vphone-launchpad-cli vm stop research-01
   ```

ヘルパーの認証は 5 分間有効です。期限が切れた後、ヘルパーを必要とする最初の手順では、ウィンドウで操作した場合と同じく、Mac で管理者パスワードを求められます。

既存の仮想マシンで永続シェーダキャッシュを有効にするための、1 回限りのカーネルとゲストの更新については、[永続シェーダキャッシュ](../storage/shader-cache.md)をご覧ください。

## 2 つのビルドを比較する

標準のバンドルを変えずに両方をインストールし、それぞれに専用のマシンを用意します。

```sh
vphone-launchpad-cli bundle install-local /path/to/A/VPhone.bundle --keep-default
vphone-launchpad-cli bundle install-local /path/to/B/VPhone.bundle --keep-default
vphone-launchpad-cli bundle list        # note both versions

vphone-launchpad-cli vm create cmp-a --bundle 2.4.0-local.aaaaaaaa
vphone-launchpad-cli vm create cmp-b --bundle 2.4.0-local.bbbbbbbb
```

この方法で作成したマシンは、3 つの層すべてが異なります（下記をご覧ください）。1 つのブートチェーンでホストプログラムとゲスト環境だけを比較するには、ウィンドウでマシンを複製し、そのコピーの紐付けを変更します。

```sh
vphone-launchpad-cli vm set-bundle cmp-b 2.4.0-local.bbbbbbbb --update-environment
```

`vm list` に、各層がどのバンドルから来たかが表示されます。`bundle remove` は、マシンが紐付いているバージョンを拒否します。先にそれらのマシンの紐付けを変更するか、削除してください。

## マシンとバンドルの紐付け

各マシンは、インストールされた 1 つのバージョンに紐付いています。紐付けは作成時に選ばれ、マシンのフォルダ内の `launchpad.json` に保存されます。バンドルをインストールしても、マシンの紐付けは変わりません。

マシンは 3 つの層からなり、それぞれ異なるタイミングでバンドルから取得されます。

| 層 | 内容 | 取得元 |
| --- | --- | --- |
| Host Programs | `vphone-cli`、`vphone-vm` | コマンドのたびに、紐付いたバンドルから。新しい紐付けは次回の起動から反映されます。 |
| Guest Environment | vphoned とフック用の dylib | 作成時の `cfw install`、その後は `cfw update-environment`（停止中のマシン）。 |
| Boot Chain | パッチ済みファームウェア、復元、CFW パッチ | 作成時の `fw patch`、`restore`、`cfw install`。 |

### 後からブートチェーンのパッチを変更する

`vphone-cli fw set-patches` でパッチの選択を変更し、`vphone-cli fw patches <vm>` でまだゲストに反映されていないものを一覧表示します。Launchpad ではその数がインスペクタに表示されます。パッチの種類ごとに、ゲストに反映される方法が異なります。

| パッチ | 反映されるタイミング |
| --- | --- |
| ゲストパッチ | 次の `cfw update-environment` |
| AVPBooter | 次の `fw patch` |
| カーネルパッチ | `cfw update-kernel`（データを保持し、復元ツリーは不要） |
| ブートチェーンの残り（TXM、DeviceTree、LLB） | 復元のみ（ゲストは消去されます） |

## 標準のバンドル

**default**（標準）のバンドル（以前の名称は「active」）が決めるのは、次のことだけです。

- `--bundle` を指定しないときに `vm create` が紐付けるバージョン
- `exec` とライブラリ全体に対するコマンドが使うバージョン

`--keep-default` を指定しない限り、新しくインストールしたバンドルが標準になります。Launchpad のセッションでマシンを初めて起動するときに、そのバンドルが一度だけチェックされます（実行ポリシーの例外、AMFI、ホストの事前チェック）。

## バージョン名

ローカルビルドは `<version>-local.<hash>` としてインストールされます。ハッシュはバンドルのコード署名のシールから取られるため、同じバージョンの 2 つのビルドを並べて置けます。古いストアには、`<version>-local` や `<version>-ci.<commit>` が残っていることがあります。

## 関連項目

- [Launchpad コマンドライン](launchpad-cli.md)
- [バンドルの組み込み](bundle-integration.md)
- [ダウンロード](../get-started/downloads.md)
