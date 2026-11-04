# 仮想マシンの作成と実行

ターミナルで `vphone-cli` を使って仮想マシンを作成、起動、停止します。Launchpad を使わずに作業する場合、仮想マシンの作成をスクリプト化する場合、処理の一部の段階だけをやり直す場合にこのページを使います。

Launchpad は `VPhone.bundle` 内の `vphone-cli` を使って仮想マシンを操作しています。同じコマンドはターミナルでも使えます。

```sh
vphone-cli vm list
vphone-cli vm launch myphone
vphone-cli vm export myphone --out myphone.tzst
```

仮想マシンは `~/.vphone/` に保存されます。すべてのコマンドは `vphone-cli <group> --help` で確認できます。

## 仮想マシンを作成する

iPhone17,3 の復元用 IPSW と、互換性のある PCC/cloudOS の IPSW が必要です。ローカルのパスでも URL でも指定できます。これまでに検証された組み合わせは[互換性](../firmware/compatibility.md)に記載されています。

```sh
vphone-cli host preflight
vphone-cli vm create myphone \
  --iphone-source /path/to/iPhone17,3_Restore.ipsw \
  --cloudos-source /path/to/cloudOS.ipsw
```

作成は次の段階で進みます：準備、ファームウェアへのパッチ適用、オンラインでの DFU 復元、ホスト側でマウントしての CFW インストール、GUI での初回起動。

- 復元チケットを取得するためにネットワーク接続が必要です。
- CFW のインストールには root 権限が必要です。バンドルには認証ダイアログも権限昇格用のヘルパーもないため、root 権限は自分で用意してください。
- 仮想ディスクの標準サイズは 64 GB です。

成功すると、最後に `[+] First boot: vphoned ping succeeded.` と `CFW VM created; vphoned connected. Guest user environment is untouched.` が表示されます。その後、仮想マシンは停止します。ping はその起動中に vphoned が応答したことを確かめるもので、実行中の仮想マシンは残りません。

### オプション

| オプション | 効果 |
| --- | --- |
| `--iphone-version`、`--iphone-build` | `--iphone-source` を渡す代わりに、`fw prepare` と同じ方法で `--device`（標準は iPhone17,3）向けの iPhone IPSW を特定します。 |
| `--cloudos-source` を省略 | `fw catalog` が示す、そのリリースに推奨される cloudOS を使います。 |
| `--disk-size` | 仮想ディスクのサイズ（GB、標準は 64）。 |
| `--preset` | パッチプリセットの名前、またはプリセットの plist のパス（標準は `standard`）。各プリセットが適用するパッチは `fw patches` で確認できます。 |
| `--cpu` | CPU コア数（標準は 8）。 |
| `--memory` | メモリ（MB、標準は 8192）。 |
| `--network` | `nat`（標準）、`bridged`、`tunnel`、`none` のいずれか。 |
| `--unlock-at-startup` | `on` または `off`（標準）。 |
| `--no-template` | テンプレートから複製せず、仮想マシンを単独で作成します。 |
| `--skip-first-boot` | 最後の起動を省きます。呼び出し側が自分で仮想マシンを起動する場合に使います。 |
| `--bootstrap roothide` | 初回起動中にパッケージ環境をインストールします。[パッケージ環境](package-environment.md)をご覧ください。 |
| `--keep-artifacts` | 準備した大きな復元ツリーを残します。ディスク容量が気になる場合は指定しないでください。 |

`--cpu`、`--memory`、`--network`、`--unlock-at-startup` は、新しい仮想マシンに `vm config` の同じ設定を行います。

### テンプレート

標準では、作成処理は[テンプレート](../storage/templates.md)を作り、そこから仮想マシンを複製します。同じデバイス、iOS と cloudOS のビルド、プリセット、ディスクサイズで次に `vm create` を実行すると、復元し直さずにそのテンプレートから複製します。仮想マシンを単独で作成するには `--no-template` を指定します。

### パッチとファームウェアの準備

ファームウェアの処理には 1 つのモードしかありません。ブートチェーンとゲストのシステムにパッチを適用し、vphoned をインストールし、ユーザ環境は空のままにします。Sileo、apt、TrollStore、SSH サーバ、VNC サーバはインストールしません。適用するパッチはパッチプリセットで選びます。`vphone-cli fw set-patches` に `--block` または `--allow` を付けると、個々のパッチをオフまたはオンにできます。

パッチを適用する前に、作成処理はファームウェアを準備します。一時的な cloudOS の復元から GPU ドライバを取り出し、vphone600 のコンポーネントを含まない cloudOS の場合は kernelcache を作り直します。[ファームウェアの準備](../firmware/firmware-preparation.md)をご覧ください。1 つのリストから複数のマシンを作成するには、[複数マシンの一括作成](../storage/many-machines.md)をご覧ください。

## 起動と停止

```sh
vphone-cli vm launch myphone  # start the VM window and keep it running
vphone-cli vm stop myphone    # run from another terminal to stop it
```

`vm launch` は vphoned を待たずにゲストを起動します。デーモンは起動中に接続します。仮想マシンのウィンドウとメニューには、ホームボタンと電源ボタン、アプリのインストール、ファイルの閲覧の機能があります。`vm launch --headless` は、仮想マシンのウィンドウとメニューバーなしで起動します。

次のどの操作でも、ゲストは正常にシステム終了します（vphoned の `system.shutdown`）。

- 仮想マシンのウィンドウを閉じる
- ⌘Q
- `vm stop`
- `vm launch` を実行したターミナルで Control-C

仮想マシンは、ゲストが停止した時点、または停止しない場合は 15 秒後に終了します。DFU 中や起動途中など、vphoned が応答できない状態のゲストは、電源を抜いたときのようにすぐに電源が切られます。Control-C をもう一度押すと、待たずに電源を切ります。

`vm stop` がシグナルを送るのは、そのマシン自身のプロセス、つまり `vphone-vm` と Virtualization の仮想マシンサービスだけです。サイズを計測中の Launchpad、Spotlight、バックアップツールなど、ディスクを開いているほかのプログラムは、名前が表示されるだけで実行されたままになります。

## 制御ソケット

実行中の各仮想マシンには、そのフォルダ内の `vphone.sock`（`~/.vphone/machines/<name>/vphone.sock`）に制御ソケットがあります。1 行の JSON を送ると、1 行の JSON が返ります。複数の接続は並行して処理されます。ウィンドウのない仮想マシンにもこのソケットはあり、その場合 `tap` と `swipe` は vphoned のタッチ注入を通じて行われ、画面の画像はゲストから取得されます。

`tap`、`swipe`、`key`、`screenshot` に加え、`rpc` リクエストで [API リファレンス](../../../Research/vphoned_http_api.md)にある任意の vphoned メソッドを呼び出せます。

```sh
printf '%s\n' '{"t":"rpc","method":"device.info","params":{}}' | nc -U ~/.vphone/machines/myphone/vphone.sock
```

たとえば、`input.key` に `{"name":"cmd+v"}` を渡すとペーストし、`input.type` でテキストを入力します。この処理では SSH や VNC のエンドポイントはインストールされません。HTTP と WebSocket でアクセスするには、[自動化 API](automation-api.md) をご覧ください。

## 各段階を手動で実行する

調査する場合や、ある段階だけをやり直す場合に使います。`restore` が通信している間は、DFU で起動した状態を保ってください。

```sh
vphone-cli vm new myphone
vphone-cli fw prepare myphone \
  --iphone-source /path/to/iPhone17,3_Restore.ipsw \
  --cloudos-source /path/to/cloudOS.ipsw
vphone-cli fw patch myphone

vphone-cli vm launch myphone --dfu &
vphone-cli restore myphone
vphone-cli vm stop myphone

vphone-cli cfw install myphone
vphone-cli vm launch myphone
```

オンラインの復元では、プロセス内でチケットを取得します。オフラインで復元するには、`vphone-cli restore --help` で `--get-shsh` と `--offline` を確認してください。手動の手順では、`vm create` が行う初回起動の ping チェックは実行されません。

## 関連項目

- [テンプレート](../storage/templates.md)
- [デバイス名と時計](device-name-and-clock.md)
- [ライブラリとバックアップ](../storage/library-and-backups.md)
- [ディスク容量の共有](../storage/sharing-disk-space.md)
