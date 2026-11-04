# ライブラリ、ファームウェア、バックアップ

vphone がマシンとダウンロードしたファームウェアを保存する場所、それらを移動する方法、マシンをコピー、バックアップ、復元する方法を説明します。ディスク容量の計画を立てる場合、ライブラリを移動する場合、マシンのコピーがもう 1 つ必要な場合にご覧ください。

## バックアップ、コピー、復元

```sh
vphone-cli vm list
vphone-cli vm info myphone
vphone-cli vm clone myphone copy                    # backup: same identity
vphone-cli vm clone myphone second --new-identity   # a second device
vphone-cli vm export myphone --out myphone.tzst
vphone-cli vm import myphone.tzst --name restored
```

`vm clone` は停止中のマシンをコピーします。使える場合は APFS のコピーオンライトを使います。コピー元が実行中の場合は拒否されます。

| 複製 | アイデンティティ | 用途 |
| --- | --- | --- |
| 通常の `vm clone` | マシン識別子と MAC アドレスが同じ | バックアップ。元のマシンと同時には実行できません。 |
| `vm clone --new-identity` | 新しいマシン識別子（ECID）と、それに伴う新しい UDID。MAC アドレスは初回起動時に新しくなります | 元のマシンと同時に実行できる 2 台目のデバイス |

`--new-identity` で作ったコピーは：

- 固定の IPv4 アドレス、ポート転送、手動で選んだ mDNS 名を消去します。元のマシンのものと衝突するためです。`--mdns on` で元のマシンの名前から作られた mDNS 名は、名前の変更時と同じく新しい名前に追従します。必要であれば `vm config` で新しく設定してください。
- 元のマシンのデータ、アプリ、設定を引き継ぎます。復元は必要ありません。
- `ideviceinstaller` などの lockdown ツールを使う前に、ロックを解除してこの Mac をもう一度信頼する必要があります。
- APFS 上では元のマシンとディスクブロックを共有し、変更した分だけを保持します。最初の数回の起動後で約 0.35 GB です。ただし、`du` と Finder はそれぞれのフルサイズを表示します。

> [!WARNING]
> マシン間で `SEPStorage`、`nvram.bin`、ディスクイメージを入れ替えないでください。これらは 1 回の復元で一緒に作られたもので、SEP ストレージがディスクと一致しないゲストは起動時にパニックします。

## ファイルの保存場所

| 標準のパス | 内容 |
| --- | --- |
| `~/.vphone/machines/<name>/` | 1 台の仮想マシン。ディスク、`config.plist`、パッチの作業ファイルを含みます |
| `~/.vphone/ipsws/` | リモートから取得したソース IPSW。すべての仮想マシンで共有されます。ローカルの IPSW はその場で読み取られます |
| `~/.vphone/gpu-drivers/<version>_<build>/` | cloudOS から取り出した GPU ドライバのバンドル。すべての仮想マシンで共有されます |
| `~/.vphone/kernelcache/` | vphone600 のコンポーネントを含まない cloudOS リリース用の kernelcache ミックス、その準備用ボリューム、ドナーから展開したもの |

これらを移動するには：

| 設定 | 移動されるもの |
| --- | --- |
| `VPHONE_ROOT` | `~/.vphone` のデータルート全体：マシンライブラリとキャッシュ |
| `VPHONE_LIBRARY_ROOT` | マシンライブラリだけ。`VPHONE_ROOT` より優先されます |
| `vm create` と `fw prepare` の `--ipsw-cache <dir>` | IPSW キャッシュだけ |

## IPSW キャッシュとダウンロード

ダウンロードした IPSW は削除するまでキャッシュに残るため、同じ URL から 2 台目のマシンを作るときは何もダウンロードされません。Launchpad では **File > Downloaded IPSWs…** で削除できます。

準備した復元ツリーは、`--keep-artifacts` を指定しない限り、`vm create` が成功した後に削除されます。以前のビルドで準備したマシンには `.ipsw-cache/` ディレクトリが残っていることがあります。これは削除しても問題なく、`vm export` にも含まれません。

リモートの IPSW は、Apple の CDN のようにサーバが HTTP の範囲リクエストに応答する場合、4 つの接続で同時にダウンロードされます。各接続は 32 MB のセグメントを順に取得し、途切れたセグメントは止まった位置から再開します。`fw prepare` の `--download-connections <n>` で接続数を 1〜16 の範囲で設定できます。1 にすると IPSW は単一のストリームでダウンロードされます。範囲リクエストを無視するサーバの場合も同じになります。

## ディスク容量とメモリ

リソースを多く使う作成処理は、1 つずつ実行してください。IPSW と一時的な復元ツリーはかなりのディスク容量を使い、大きなキャッシュへのパッチ適用には多くのメモリが必要になることがあります。2 台目のマシンを作り始める前に、空き容量を確認してください。

Launchpad は、該当する場合、CFW の作業ファイルをライブラリがマウントされている外部ボリュームに置きます。単体の `vphone-cli cfw install` の標準は `/private/var/tmp` で、root 所有の非公開ディレクトリを指定する `--work-parent` を受け付けます。

## 関連項目

- [スナップショット](snapshots.md)
- [テンプレート](templates.md)
- [仮想マシン間でのディスク容量の共有](sharing-disk-space.md)
- [マシンの作成と実行](../machines/create-and-run.md)
