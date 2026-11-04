# テンプレート

テンプレートは、`vm create` が新しいマシンを複製する元になる、完成済みで凍結されたマシンです。ある組み合わせのオプションで最初に作成するときにテンプレートが作られ、同じオプションでの以降の作成は数秒で終わり、何もダウンロードしません。このページでは、テンプレートの作成、軽量化、後片付けを制御する方法を説明します。

## テンプレートからマシンを作成する

`vm create` は標準でテンプレートを使います。

```sh
vphone-cli vm create phone-a --iphone-source … --cloudos-source …   # builds the template, clones phone-a
vphone-cli vm create phone-b --iphone-source … --cloudos-source …   # clones phone-b, no restore
vphone-cli vm create phone-c --template 3f2a91c0d4e7 --cpu 4 --memory 6144
```

- 一致するテンプレートがある場合、`vm create` はそこから新しいアイデンティティでマシンを複製し、指定された CPU、メモリ、ネットワークを設定して、vphoned を確認するために一度起動します。root 権限も IPSW も必要ありません。
- ない場合は、必要に応じて IPSW をダウンロードし、作業用フォルダで処理全体を実行してテンプレートを作成して凍結し、そこからマシンを複製します。
- `--template <id>` は、識別子または一意に決まる 4 桁以上の先頭部分でテンプレートを指定して複製します。IPSW のオプションは受け付けません。`--device`、`--preset`、`--disk-size`、軽量化のスイッチを指定する場合は、テンプレートの値と一致している必要があります。複製でこれらを変えることはできません。
- `--no-template` は、マシンを単独で復元し、固有の鍵を持たせます。軽量化のスイッチは受け付けません。

仮想マシンを手動でテンプレートにする方法、`vm create` が使うテンプレートを調べる方法、Launchpad がテンプレートを作る方法については、[テンプレートの作成と検索](template-building.md)をご覧ください。

## テンプレートの照合

何かを復元する前に、`vm create` はオプションと 2 つの IPSW からテンプレートキーを求めます。キーに含まれるもの：

- ゲストのデバイス
- iOS と cloudOS のバージョンとビルド
- パッチプリセットと、それが解決されるブートチェーンのパッチ。バンドルに同梱されていないプリセット（プリセットファイル、または `~/.vphone/patches_presets` にあるもの）の場合は、ゲストのパッチも含め、解決されるすべてのパッチが含まれます。このようなプリセットは同じ識別子のまま内容が変わることがあり、複製はテンプレートのゲストパッチを引き継ぐためです
- バンドルのシリーズ（2.9.x なら `2.9`）
- ディスクサイズ
- ゲストの System ボリュームから削減するもの（`--trim`）と残す言語
- 下記の軽量化のスイッチ

CPU、メモリ、画面、ネットワークはキーに含まれません。

ビルドは、IPSW がローカルのファイルであるか、すでに IPSW キャッシュにある場合はその IPSW から求めます。それ以外の場合は、[`vm template find`](template-building.md) と同じ方法で、同じ 2 つのソースで記録されたテンプレートから求めます。削除されたローカルの IPSW は、存在しないものとして扱われます。

### テンプレートの作成

一致するテンプレートがない場合、処理全体が `.templates/.building-<id>-<uuid>/` で実行されます：`cfw install`、オフラインでの削減、そしてセットアップ起動。結果は凍結され、1 回の操作で `<library>/.templates/<id>/` に名前が変更されます。

- 復元ツリーは、`--keep-artifacts` の指定にかかわらず、凍結の前に削除されます。残しておくと約 11 GB がテンプレートの存続期間中ずっと占有され、どの複製もそれを使えないためです。`--keep-artifacts` で復元ツリーが残るのは `--no-template` の場合だけです。`vm template adopt` も復元ツリーを削除します。
- 同じキーで 2 つ目の `vm create` を実行すると、2 つ目のコピーを復元せずに最初の処理を待ちます。
- 失敗した作成処理は、調査できるように作業用フォルダに残ります。

テンプレートは作成中にセットアップ起動のために一度だけ起動し、凍結された後は二度と起動しません。

## オフラインでの削減

`cfw install` の後、テンプレートの作成処理は、ゲストが必要としないシステムファイルを System ボリュームから削除します。これはボリュームをホストにマウントしてオフラインで行います。段階は `vm create` の `--trim`（標準は `standard`）と `vm template trim` の `--tier` で選びます。

| 段階 | 削除するもの | 目安 |
| --- | --- | --- |
| `none` | なし | |
| `conservative` | `usr/standalone/update` の中身（ソフトウェアアップデート用の RAM ディスク、ベースバンドのファームウェア） | 0.35 GB |
| `standard` | conservative に加え、AirPods/Beats のペアリング用アセット（`PreinstalledAssetsV2/RequiredByOs/com_apple_MobileAsset_SharingDeviceAssets`）、文字盤（`NanoTimeKit/FaceBundles`）、残さないすべての言語の `LinguisticData/RequiredAssets_*.bundle` | 1.2 GB |
| `aggressive` | 予約済み：ゲストで検証されるまでは拒否されます | |

`--keep-languages`（標準は `en,zh-Hans,zh`。英語は常に残ります）で、`standard` が残す言語を選びます。段階、リストのバージョン、残す言語はテンプレートキーに含まれる（`standard/1/en,zh,zh-Hans`）ため、削減の内容が異なるテンプレートが一致することはありません。

> [!WARNING]
> 削減は元に戻せません。複製でファイルを取り戻すことはできません。

削除したファイルは、最初は何も容量を解放しません。ゲストの元のシステムスナップショット（`cfw install` が残す `orig-fs.disabled.rn-*`）がまだすべてのブロックを保持しており、ホストからは root でも削除できないためです。セットアップ起動の最初の手順でこれが削除され、その時点で初めて容量が戻ります。そのため、セットアップ起動を行わないテンプレートでは削減は拒否され、削減したテンプレートはスナップショットがなくなってから初めて凍結または adopt されます。

`vm template trim` には root 権限は不要です。テンプレートから複製されていない停止中のマシン、または未完成の `.building-…` フォルダで実行でき、凍結されたテンプレートは拒否します。

## セットアップ起動と軽量化

セットアップ起動は、すべての複製が始まるべき状態にテンプレートを仕上げます。テンプレートを一度起動し、vphoned を通じて次の順に処理します。

1. `cfw install` が残した APFS スナップショット `orig-fs.disabled.rn-*` を削除します（約 20 MB を保持しており、さらに削除されるまでは System ボリュームから削減したすべてのファイルも保持しています）。
2. 設定アシスタントを省きます（`setup.skip`）。
3. 初回起動時の処理が落ち着くのを待ちます（`setup.settle`、最大 10 分）。初回起動時に installd が削除可能なシステムアプリを展開します。
4. システムアプリを削除します（`apps.remove_system`、バックアップはゲスト内に保持）。
5. サービスプロファイルを適用します（`services.profile.apply`）。これにはサインインのフォローアップ用デーモン（`followupd`、`appleidsetupd`）をオフにすることも含まれます。
6. 再起動して確認します：スナップショットが残っていないこと、セットアップが完了していること、プロファイルのサービスが 1 つも実行されていないこと、削除したアプリがないこと、vphoned が応答すること。
7. この起動のために `vphone-vm` が固定したデバイス名を消去し、ゲストを正常にシステム終了します。

各手順には期限があります。手順が失敗すると仮想マシンは停止し、何も記録されず、作成処理は凍結されないまま残ります。`vm create` は失敗した手順と再試行の方法を表示します。

| スイッチ | 標準 | 効果 |
| --- | --- | --- |
| `--slim on\|off` | on | `off` にすると何も削減せず、すべてのアプリとサービスを残します。セットアップ起動は引き続き実行され、セットアップが省かれ、スナップショットが削除されます。 |
| `--trim none\|conservative\|standard` | standard | 上記のオフラインでの削減。 |
| `--keep-languages <list>` | `en,zh-Hans,zh` | `--trim standard` が残す言語。 |
| `--service-profile trimmed\|none` | trimmed | vphoned の trimmed プロファイル：App Store のデーモンやサインインのフォローアップを含む約 140 個の launchd ジョブをオフにします。このプロファイルの iPhone は Apple Watch とペアリングできません（`Research/Guest/watch_pairing.md` をご覧ください）。 |
| `--remove-apps on\|off` | on | App Store、ホーム、TV、News、FaceTime、iTunes Store、メッセージ、ゲーム、探す、ウォレットを削除します。カメラと電話は残ります。 |
| `--keep-apps <ids>` | なし | そのリストのうち残すアプリのバンドル ID をコンマ区切りで指定します（`com.apple.findmy,com.apple.Passbook`）。 |
| `--accounts-off` | off | `akd`、`amsaccountsd`、`appleaccountd` もオフにします。ゲストは Apple アカウントにサインインできなくなります。 |

それぞれの選択はキーに含まれるため、軽量化の内容が異なるテンプレートは共存でき、それぞれを求める作成処理にだけ使われます。サービスプロファイルの制限については、[Apple Watch のペアリングに関する記録](../../../Research/Guest/watch_pairing.md)をご覧ください。

削除したアプリとプロファイルは、複製で `vphone-launchpad-cli guest rpc` または Launchpad の **Guest System** を使って元に戻せます。

- `apps.restore_system` は、バックアップからアプリを戻します。
- `services.profile.apply {"profile":"none"}` は、プロファイルがオフにしたものだけを正確にオンに戻します。

### 複製が引き継ぐもの

複製はテンプレートから次のものを引き継ぎます：完了したセットアップ、セットアップ起動が残した状態のアプリとサービス、installd とインデックス作成処理が行った初回起動時の処理、その起動時点の Data ボリューム。

デバイス名は引き継ぎません。テンプレートでの固定は消去されるため、複製は自身の仮想マシンが接続して複製の名前を固定するまで `iPhone` と表示します。また、アイデンティティが新しくなるため、Mac は再び「このコンピュータを信頼しますか?」と尋ねます。

## 共有される秘密情報

> [!WARNING]
> 1 つのテンプレートから複製したマシンはすべて、テンプレートと、また互いに、SEP のルートシークレット、Data ボリュームの鍵、復元とセットアップ起動で書き込まれたデータを共有します。理論上は、ある複製が別の複製の Data ボリュームを復号できます。

マルチデバイスの研究のために Apple のサービスにサインインする場合など、固有の鍵が必要なマシンは `--no-template` で作成してください。

複製は、`vm clone --new-identity` と同じく、初回起動時に新しい ECID、UDID、MAC アドレスを得ます。APFS 上では、変更されていないすべてのブロックをテンプレートと共有します。新しい複製は書き込みを始めるまでほとんど容量を使わず、軽量化したテンプレートでは初回起動時に書き込む処理も少なくなります。

## テンプレートを管理する

```sh
vphone-cli vm template list              # id, key summary, STALE with the reasons
vphone-cli vm template show <id> --json
vphone-cli vm template trim myphone --tier standard   # trim a stopped VM before adopting it
vphone-cli vm template setup myphone     # the setup boot, on a stopped VM
vphone-cli vm template adopt myphone     # freeze a stopped, newly created VM into a template
vphone-cli vm template delete <id>
```

### 古くなったテンプレート

この `vphone-cli` が別のバンドルシリーズに属する場合、キーの形式が古い場合、プリセットが別のブートチェーンのパッチに解決されるようになった場合、またはパッチの記録が計画と一致しない場合、テンプレートは古くなったもの（STALE）として表示されます。古くなったテンプレートは使われません。そのキーで `vm create` を実行すると失敗し、そのテンプレートの名前が表示されます。削除すれば、次の `vm create` で新しいテンプレートが作られます。

### 仮想マシンを adopt する

`vm template adopt <vm>` は、停止中の仮想マシンを、その記録から求められるキーでテンプレートにします。使われる記録は `restore-info.json`、`PatchPlan.plist`、`config.plist`、ディスクイメージ、Launchpad の `launchpad.json`、そして `vm template trim` と `vm template setup` が `Template.plist` に記録した手順です。その仮想マシンは `vm list` から消えます。

仮想マシンは、セットアップ起動の直後に adopt してください。それ以降にゲストで行われたことは、すべての複製に引き継がれます。スナップショットのある仮想マシンは拒否され、`--force` を指定しない限り、古くなったテンプレートになる仮想マシンも拒否されます。

### 凍結されたテンプレートは起動しない

`vm launch` と `vphone-vm` は、DFU であっても凍結されたテンプレートを拒否します。マシン名で `.templates` の中を指定することはできないため、`vm launch`、`clone`、`export`、`rename`、`delete` が誤ってテンプレートを対象にすることはありません。凍結後にテンプレートが起動すると、以降のすべての複製が引き継ぐブロックに状態が書き込まれ、それ以前に作られた複製はそれらのブロックを共有しなくなります。

### テンプレートを使っているマシン

テンプレートから複製したマシンは、そのテンプレートを `TemplateSource.plist` に記録します。そのマシンを `vm clone` するとこの記録は残り（コピーもテンプレートのブロックを共有するため）、`vm export` では含まれません（読み込んだマシンは何も共有しないため）。記録にはテンプレートのビルドも含まれるため、テンプレートを削除して同じキーで作り直した場合、古いテンプレートから複製したマシンは数に入りません。それらは新しいテンプレートのブロックを共有していないためです。

`vm template list` と `show` は、各テンプレートを使っているマシンとディスク上のサイズを表示し、`vm info` はマシンのテンプレートを表示します。まだ存在するテンプレートから複製された最後のマシンを `vm delete` で削除すると、その旨が表示されます。テンプレート自体が削除されることはありません。

```text
note: template 3f2a91c0d4e7 (~17.40 GB) is no longer used by any machine; remove it with `vphone-cli vm template delete 3f2a91c0d4e7`
```

### テンプレートを削除する

`vm template delete <id>` はテンプレートを削除します。そこから複製したマシンは引き続き動作します。それらのマシンがまだテンプレートと共有しているブロックは、マシンがそのブロックを変更するか削除されたときに初めて解放されるため、複製が残っている間は、テンプレートを削除しても解放される容量はそのサイズより少なくなります。

表示されるメモで、どちらの場合かがわかります。テンプレートを使っているマシンがあり、共有ブロックはそれらのマシンが変更するか削除されるまで割り当てられたままになる場合と、使っているマシンがなく、削除するとそのブロックが解放される場合です。テンプレートが存在していた間に作成されたローカルの Time Machine スナップショットは、期限が切れるまでそれらのブロックを保持することがあります。`--json` と `--force` を指定すると、同じ情報が出力されます。

テンプレートは `vm list` には表示されませんが、ディスク容量を使います。`~/.vphone/machines/.templates` を確認してください。また、`du` はテンプレートとその各複製をそれぞれフルサイズで数えることに注意してください。

## 関連項目

- [テンプレートの作成と検索](template-building.md)
- [複数マシンの一括作成](many-machines.md)
- [仮想マシン間でのディスク容量の共有](sharing-disk-space.md)
- [ライブラリ、ファームウェア、バックアップ](library-and-backups.md)
