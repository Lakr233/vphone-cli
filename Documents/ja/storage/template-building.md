# テンプレートの作成と検索

仮想マシンを手動でテンプレートとして仕上げる方法、`vm create` がどのテンプレートを使うかを調べる方法、Launchpad がテンプレートを作る方法を説明します。テンプレートとは何か、そのキーに何が含まれるかについては、先に[テンプレート](templates.md)をお読みください。

## 仮想マシンをテンプレートとして仕上げる

作成した直後の仮想マシンをテンプレートにするには、停止して削減し、セットアップ起動を行ってから adopt します。Launchpad がテンプレートを作る必要があるときに行う処理と同じです。

```sh
vphone-cli vm stop phone-src
vphone-cli vm template trim phone-src --tier standard   # offline, no root; frees nothing until the setup boot
vphone-cli vm template setup phone-src        # headless; --window to watch, slimming switches as for vm create
vphone-cli vm template adopt phone-src --iphone-source … --cloudos-source …   # key from its records; the sources are recorded
vphone-cli vm create phone-d --template <id> --skip-first-boot
```

### vm template setup

- 実行中の仮想マシンと凍結されたテンプレートは拒否します。
- 自身では何も削減しません。`vm template trim` が記録した段階を引き継ぎ、別の段階を指定する `--trim` は拒否します。
- 仮想マシンでは、vphoned が削除しないアプリを報告し、それを記録する手順から除くため、adopt したキーには実際に行われたことが記載されます。
- `--strict` を指定すると、代わりに失敗します。何も記録されず、セットアップ起動をやり直せます。同じスイッチで `vm template find` が示したキーで、`--expect` を付けて仮想マシンを adopt する場合に使います。
- `vm template list` に表示される `.building-…` という名前（セットアップ起動に失敗した `vm create`）を指定すると、作成処理をそのキーに合わせて設定し（これで軽量化の内容が決まります）、オフラインでの削減の前に止まっていた場合は先にそれを実行し、成功すると凍結します。

### vm template adopt

| オプション | 効果 |
| --- | --- |
| `--iphone-source`、`--cloudos-source` | テンプレートを作る `vm create` と同じく、仮想マシンの作成元の IPSW を `Template.plist` に記録します。 |
| `--json` | `vm template show --json` と同じ形式で新しいテンプレートを出力します。 |
| `--expect <id>` | 仮想マシンの記録から求められるテンプレート識別子が `<id>`（仮想マシンの作成時のオプションで `vm template find` が表示した `id`）でない限り、拒否して仮想マシンをそのままにします。 |

後でテンプレートを再び見つける必要がある場合は、必ず `--expect` を使ってください。指定しないと、セットアップ起動が不十分だった仮想マシン（削除できないアプリがあった場合など）が別のキーで保存され、同じオプションでの以降の `vm create` がすべてそれを見つけられず、別のテンプレートを作ってしまいます。

期待されるキーを求められる場合、拒否のメッセージには異なるフィールドが表示されます。ライブラリ内のテンプレートや作成処理がそのキーを持っている場合、または軽量化の内容だけが異なる場合に求められます。それ以外の場合は、比較のために仮想マシン自身のキーを表示します。`--json` を指定すると拒否の内容も stdout に出力され、コマンドは終了ステータス 1 で終了します。

```text
{"adopted": false, "error": "unexpected_template", "id": …, "expected": …, "differences": […], …}
```

## テンプレートを検索する

`vm template find` は、同じオプションの `vm create` がどのテンプレートから複製するかを、ダウンロード、復元、変更を一切行わずに答えます。

```sh
vphone-cli vm template find --iphone-source … --cloudos-source … [--device …] [--preset …] [--disk-size …] [--block <id>] [--allow <id>] [slimming switches] --json
```

キーは `vm create` と同じ方法で求めます。ビルドは、IPSW がローカルのファイルであるか、すでに IPSW キャッシュにある場合はその IPSW から、それ以外の場合は同じ 2 つのソースが記録されたテンプレートから求めます。そのため、IPSW を削除した後でも（ローカルのものも含め）キーを求められます。`--block` と `--allow` は、`fw set-patches` が記録するのと同じパッチごとの上書き設定です。

| JSON のフィールド | 意味 |
| --- | --- |
| `resolved` | キーを求められたかどうか |
| `resolvedBy` | `ipsw` または `template` |
| `id` | テンプレート識別子 |
| `summary` | キーの概要 |
| `key` | キー全体 |
| `template` | 一致するテンプレート。`vm template show --json` と同じ形式で、最新のものか古くなったものかを問いません |
| `usable` | 存在し、最新であるかどうか |
| `building` | 作成処理がそのビルドロックを保持しているかどうか |
| `reason` | キーを求められなかった場合の理由 |

## Launchpad で

Launchpad 2.9 以降は、標準でテンプレートからマシンを作成します。

### New Machine

New Machine は短いページで開きます：名前、ファームウェアカタログから選ぶデバイスと iOS のバージョン、**Slim System** スイッチ。その下の行にそれ以外の設定の概要が表示され、そこから **Advanced Options** を開けます。Advanced Options は次の 4 つのページです。

- ハードウェア
- テンプレートとその構成要素：削減の段階と残す言語、サービスプロファイル、削除するシステムアプリ
- Core Bundle、カスタム IPSW、パッチ
- 保存場所、ネットワーク、復元のオプション

この行には、標準と異なる設定の数と、**Create** を妨げている項目が表示されます。**Create from a template** をオフにすると、`--no-template` と同じく、軽量化せずに固有の鍵でマシンを単独で復元します。Apple アカウントは選択肢にありません。どちらにしてもゲストはサインインを拒否するため、サービスプロファイルが trimmed の場合、Launchpad は常に `--accounts-off` を渡します。シートはページに合わせて 600 ポイントまで大きくなり、それを超えるとスクロールするため、ノートパソコンの画面でもボタンが画面内に収まります。

### kernelcache を作り直すファームウェア

**Firmware** では、そのリリース自身の cloudOS でも動作するリリース（`fw catalog` の 3 列目）について、推奨の cloudOS と並べてその cloudOS が選べます。作成処理では、kernelcache ミックスをあなたのユーザ権限で作成し、そのリリースの kernelcache のビルドに使われた kmutil でリンクします（[ファームウェアの準備](../firmware/firmware-preparation.md#ミックスをリンクする-kmutil)をご覧ください）。Core Bundle 2.17 以前では、代わりにヘルパーが root としてリンクし、その際に一度だけ認証を求めます。

これらの組み合わせでは、ミックスの準備に `ipsw` ツールを使う古い互換の Core Bundle（2.12.0）のために、Launchpad は引き続き `ipsw` ツールの欄を表示します。Core Bundle 2.12.1 以降はネイティブで展開し、選択したパスは無視します。

iPhone XS Max は iOS 18.1〜18.7.2 を、それぞれのリリース自身の cloudOS 上で、テンプレートなしで、既定では Minimal プリセットで実行します。Standard も動作します（18.6 で確認）。これらの組み合わせでは常に kernelcache を作り直し、どの macOS 上でも macOS 15 の kmutil でリンクします。

### 作成処理でのテンプレートの使い方

作成処理は、最初に `vm template find` を実行します。

- 最新のテンプレートが一致する場合は、マシンを複製し（`vm create --template <id> --skip-first-boot`）、起動します。
- 一致しない場合は、同じライブラリ内の一時的なマシン（`template-` と 8 桁の 16 進数の名前）でテンプレートを作ります。通常の手順（復元、ヘルパーを通じた `cfw install`）の後、`vm template trim`、ヘッドレスの `vm template setup --strict`、`vm template adopt --iphone-source … --cloudos-source … --expect <id>` を実行し、その結果からマシンを複製します。

削除すべきアプリが残るとセットアップ起動が失敗し、作成処理のキーが `find` の求めたキーと異なると adopt が失敗するため、以降の作成処理が見つけられない ID で作成結果が保存されることはありません。それぞれが所要時間付きの独立した手順として表示され、失敗した手順には `vphone-cli` が示した理由が表示されます。

New Machine の **Patch Settings** でのパッチごとの上書き設定は、テンプレートキーと同じ方法で分けられます。

- ブートチェーンの上書き設定はキーに含まれます。テンプレートはそれを適用して作られ、`find` もそれを含むテンプレートを探します。
- ゲストパッチの上書き設定は含まれません。テンプレートはそれを適用せずに作られます。複製の後、作成処理は `fw set-patches` で新しいマシンにそれを記録し、初回起動の前にヘルパーを通じて `cfw update-environment` で書き込みます（**Apply guest patches** の手順）。そのため、ある作成処理でのゲストパッチの選択が、テンプレートを通じて別の作成処理に引き継がれることはありません。

テンプレートを作った後、作成処理はその元になった 2 つの IPSW を削除するかどうかを尋ねます。確認なしに削除されることはありません。

### Launchpad でテンプレートを管理する

- **File > Templates…** には、すべてのライブラリのテンプレートが、そのマシン、軽量化の内容、サイズ、状態とともに表示され、削除もできます。
- **Guest System…**（マシンのアクションメニューとインスペクタにあります）では、実行中のマシンのサービスプロファイルを切り替えたり、テンプレートが削除したシステムアプリを戻したりできます。
- インスペクタとマシンの一覧には、各マシンが単独で使っているディスク容量が、そのファイルの割り当て量と並べて表示されます。これは、ほかのどのマシンやテンプレートも保持していないブロックで、そのマシンを削除すると解放されます。それ以前に作成されたローカルの Time Machine スナップショットは、期限が切れるまでそれらのブロックを保持します。

## 関連項目

- [テンプレート](templates.md)
- [複数マシンの一括作成](many-machines.md)
- [ファームウェアの準備](../firmware/firmware-preparation.md)
- [Launchpad CLI](../launchpad/launchpad-cli.md)
