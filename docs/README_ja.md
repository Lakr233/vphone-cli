<div align="right"><strong><a href="./README_ko.md">🇰🇷한국어</a></strong> | <strong>🇯🇵日本語</strong> | <strong><a href="./README_zh.md">🇨🇳中文</a></strong> | <strong><a href="./README_ru.md">🇷🇺Русский</a></strong> | <strong><a href="./README_pt.md">🇧🇷Português</a></strong> | <strong><a href="../README.md">🇬🇧English</a></strong></div>

# vphone-cli

PCC リサーチ VM インフラストラクチャを使用し、Apple の Virtualization.framework 経由で仮想 iPhone を起動します。

![poc](./demo.jpeg)

## 前提条件

**実行に必要なもの:**

- Apple Silicon
- macOS 15+ (Sequoia)
- [未署名バイナリでプライベートな PV=3 エンタイトルメントを許可するための SIP/AMFI の緩和](#sipamfi-の緩和)

**それ以外は何も要りません。** Homebrew パッケージも、インタープリタも、パッケージ環境も、
Xcode も不要です。vphone-cli が実行するものは、`/usr/bin`・`/bin`・`/usr/sbin`・`/sbin`
にあるシステムバイナリか、`.app` の中にあるもののどちらかです。署名器（`ldid` の置き換え）、
アーカイブ処理（`gtar`・`zstd`・`unzip`）、ファームウェアカタログと IM4P/AEA の処理
（`ipsw`）、そして CFW インストーラがゲストに入れる 5 つの iOS バイナリ——これらは
ビルド時にクロスコンパイルして同梱されるので、手元のマシンではコンパイルしません。
その状態を保つゲートが `make check-aux` です。

**ソースからビルドする場合**は、Xcode（その 5 つのゲストバイナリのクロスコンパイルに
iOS SDK を使います）と `git-lfs`（`git clone` が `scripts/resources` のアーカイブを
取得するのに必要）が追加で要ります。

## インストール

```bash
brew install zqxwce/tap/vphone-cli
```

## ビルド

```bash
brew install git-lfs
git clone --recurse-submodules https://github.com/Lakr233/vphone-cli.git

./scripts/build.sh            # vphone-cli のビルド + 署名、ゲストバイナリのクロスコンパイル、.app のバンドル

cd .build/vphone-cli.app/Contents/MacOS/
vphone-cli --help
```

`./scripts/setup_tools.sh` は任意で、ビルドするのは `insert_dylib` ひとつだけです。
Mach-O のテストが Swift の dylib インジェクタをバイト単位で照合するための独立した参照で、
配布物がこれを実行することはありません。

## クイックスタート

1 つのコマンドで VM をエンドツーエンドで作成します（ダウンロード → パッチ → DFU 復元 → CFW インストール → 初回起動）:

```bash
vphone-cli vm create myphone -V jb        # -V / --variant

vphone-cli vm launch myphone
```

## コマンド

`vphone-cli vm create` はパイプライン全体を実行します。以下の個別ステップを使うと、手動で操作したり 1 つの段階を再実行したりできます。

### 管理

```bash
vphone-cli vm list                         # VM の一覧表示（スクリプト用に --json）
vphone-cli vm info myphone                  # 1 つの VM を表示
vphone-cli vm new myphone                   # 空のバンドルを作成（cpu/mem/disk オプション）
vphone-cli vm config myphone --cpu 8 --memory 8192
vphone-cli vm clone myphone myphone-2       # 高速 APFS クローン、新しいデバイスアイデンティティ
vphone-cli vm export myphone --out myphone.tzst   # zstd fast by default (--max = xz -9); --out がディレクトリなら <vm>.tzst/.txz を自動命名; 復元ディレクトリ + ステージングファイルをスキップ
vphone-cli vm import myphone.tzst --name restored
vphone-cli vm rename myphone iphone16
vphone-cli vm delete iphone16
```

### VM を手動でビルドする（`vm create` が自動化する処理）

```bash
vphone-cli vm new myphone                              # 1. 空のバンドル
vphone-cli fw prepare myphone --iphone-version 26.1     # 2. IPSW のダウンロード + マージ
vphone-cli fw patch myphone --variant jb                # 3. ブートチェーンにパッチ適用

vphone-cli vm launch myphone --dfu &                    # 4. DFU で起動（バックグラウンド）
vphone-cli restore myphone --get-shsh                   #    SHSH を取得
vphone-cli restore myphone                              #    DFU 復元
vphone-cli vm stop myphone                              #    DFU 起動を停止

vphone-cli cfw install myphone --variant jb             # 5. CFW をインストール（ホストマウント; sudo を要求）
vphone-cli vm launch myphone                            # 6. 初回起動
```

新しい iOS に更新するには、`fw prepare` を IPSW に向けます: `--iphone-source /path/to.ipsw --cloudos-source /path/to.ipsw`。

ステップ 4 と 5 は `vphone-cli` 自身のプロセス内で実行されます。`restore` は同梱の
libirecovery と idevicerestore を直接駆動します — 外部の復元ツールも、最初の 1 回の前に
必要なセットアップ手順もありません。`--offline` を付けると、Apple に新しい ticket を
要求する代わりに、VM の横に保存済みの `.shsh` で復元します。

## ファームウェアバリアント

セキュリティバイパスの度合いが段階的に増す 5 つのパッチバリアント — いずれか 1 つを `--variant` に渡します:

| バリアント   | ブートチェーン | CFW       | 備考                                                              |
| ------------ | ----------- | --------- | ----------------------------------------------------------------- |
| `less`       | 4 patches   | 2 phases  | パッチなし — iOS の緩和策を有効なまま維持                          |
| `regular`    | 42 patches  | 10 phases | AMFI/SSV/Img4/TXM バイパス                                        |
| `dev`        | 53 patches  | 12 phases | + TXM エンタイトルメント/デバッグバイパス                          |
| `jb`         | 113 patches | 14 phases | + 完全な脱獄（Sileo、TrollStore を初回起動時に自動インストール）   |
| `exp`        | 141 patches | 18 phases | JB のスーパーセット + VM 検出対策リサーチパッチ                    |

コンポーネントごとの内訳については [`research/0_binary_patch_comparison.md`](../research/0_binary_patch_comparison.md) を参照してください。

## 実行と接続

- **SSH（脱獄）:** `ssh -p 22222 mobile@<vm-ip>`（パスワード `alpine`）
- **SSH（regular/dev）:** `ssh -p 22222 root@<vm-ip>`
- **VNC:** `vnc://<vm-ip>:5901`

## 場所

vphone-cli が生成するものはすべて `~/.vphone/` 以下に置かれます — 署名済みバンドルがポータブルであり続けるよう、リポジトリと `.app` の外に保管されます。`$VPHONE_ROOT` でツリー全体をリダイレクトできます:

| パス              | 内容                                                                                       |
| ----------------- | ------------------------------------------------------------------------------------------ |
| `~/.vphone/`      | ユーザー別データルート — `$VPHONE_ROOT` で場所全体を上書きします。                           |
| `~/.vphone/VMs/`  | VM バンドル — VM ごとに 1 ディレクトリ。これがライブラリです。`$VPHONE_LIBRARY_ROOT` で上書きできます。 |
| `~/.vphone/ipsws/`| ダウンロードされた iPhone + cloudOS の IPSW。キャッシュされ、複数の VM で再利用されます。       |
| `~/.vphone/tools/`| `fw prepare` 中に取得された APFS seal-volume アーティファクト（`apfs_sealvolume_<version>`）のキャッシュ。 |
| `~/.vphone/debs/` | `jb`/`exp` の CFW インストールがゲストに配置する `.deb` パッケージのキャッシュ（Sileo、apt など）。 |

優先順位: 項目ごとの上書き `$VPHONE_LIBRARY_ROOT` が `$VPHONE_ROOT` より優先され、`$VPHONE_ROOT` は `~/.vphone` のデフォルトより優先されます。`ipsws/`、`tools/`、`debs/` キャッシュは、常に現在有効なルートの直下に置かれます。

## SIP/AMFI の緩和

**オプション A — SIP を完全に無効化し、boot-arg で AMFI を無効化する（最も緩い）。**

リカバリーモードで（電源ボタン長押し → ターミナル）:

```bash
csrutil disable
csrutil allow-research-guests enable
```

その後 macOS で再起動し、AMFI の boot-arg を設定します（有効化には SIP を完全に無効化する必要があります）:

```bash
sudo nvram boot-args="amfi_get_out_of_my_way=1 -v"   # 後で再起動
```

これが依然として最も手軽な方法であり、VM のそばで何かを走らせ続ける必要がない唯一の方法です: AMFI が緩和されていれば `vphone-vm` は単体で起動します。

**オプション B — SIP を有効なまま（デバッグのみ緩和）にし、このビルドを許可リストに入れる**（それ以外の時間、および許可していないすべてのバイナリに対しては AMFI が有効なまま）。

リカバリーモードで:

```bash
csrutil enable --without debug
csrutil allow-research-guests enable
```

その後 macOS で再起動し、次を実行します:

```bash
make amfi_allow     # root が必要。ビルドのたびに再実行してください
make amfi_status    # 許可リストと、このホストがそれを持てるかどうかを表示
make amfi_off       # 許可リストを削除し、amfid をクリーンに再起動
```

これが実行するのは `vphone-amfi-allow` — 本リポジトリ自身の C で書かれ、`.app` に同梱されています。書き込むのは 2 つだけです:

* 2 つの `vphone-vm` の cdhash を
  `/Library/Preferences/com.apple.security.coderequirements.plist` に。これは AMFI が
  もともと読むファイルで、穴ではなく AMFI 自身の機能です;
* amfid の**ヒープの 1 バイト**。`_isRunningInternalBuild` フラグを立てて、そのファイルを読ませます。

2 つとも必要なのは、`make boot` が両方を起動するからです: `boot_binary_check` は
`.build/release/vphone-vm` を、起動処理そのものは `.app` の中のものを実行します。
署名の識別子が異なりハッシュも異なるため、片方だけを許可してもフローの半分しかカバーできません。

**ビルドのたびに再実行してください。** 許可は cdhash をキーにしており、署名のたびに cdhash は変わります — 素の `swift build` でも変わります。

許可すべきバイナリは `vphone-vm` です。`vphone-cli` は entitlement を持たず常に起動できるため、必要なのはその cdhash ではありません。

> **何が許可されるのかを正しく理解してください。** これは cdhash をキーにした許可リストです: 指定していないバイナリに対して amfid は通常どおり検証を続けます。`make amfi_off` はそのファイルを削除し amfid を再起動します。
>
> 書き込む 1 バイトは amfid の `__TEXT` ではなく**ヒープ**にあり、それがこの方式が成り立つ理由のすべてです。以前の手法はコードを書き換えていました — `vphone-letmein` は `-[AMFIPathValidator_macos validateWithError:]` の `ldrb` を上書きし、LLDB ベースのツールはブレークポイントのために `BRK` を埋め込みます。どちらも dirty で未署名の実行ページを残し、`sysctl vm.cs_system_enforcement` が 1 のホスト — macOS 27.0 (26A428)、arm64e、上記の `csrutil` 設定そのままで実測 — ではカーネルが次のフォルトでそのページを検証し、amfid を kill し、ゲストも巻き添えにします。この sysctl は実行時には読み取り専用なので、「コードにパッチを当てる」方式はどれだけ気をつけても生き残れません。ヒープはコードではないので、強制検証は何も文句を言いません。

## 動作確認済み環境

| ホスト          | iPhone                | CloudOS         |
| --------------- | --------------------- | --------------- |
| Mac16,11 27.0b2 | `17,3_18.6.2_22G100`  | `26.1-23B85`    |
| Mac16,8 26.5.1  | `17,3_26.0_23A341`    | `26.1-23B85`    |
| Mac16,8 26.5.1  | `17,3_26.0.1_23A355`  | `26.1-23B85`    |
| Mac16,12 26.3   | `17,3_26.1_23B85`     | `26.1-23B85`    |
| Mac16,12 26.3   | `17,3_26.3_23D127`    | `26.1-23B85`    |
| Mac16,12 26.3   | `17,3_26.3_23D127`    | `26.3-23D128`   |
| Mac16,12 26.3   | `17,3_26.3.1_23D8133` | `26.3-23D128`   |
| Mac16,11 26.2   | `17,3_26.4_23E246`    | `26.4-23E5207q` |
| Mac16,11 26.2   | `17,3_26.5_23F77`     | `26.4-23E5207q` |
| Mac16,11 27.0b2 | `17,3_26.5.2_23F84`   | `26.4-23E5207q` |
| Mac16,6 26.4.1  | `17,3_26.6_23G71`     | `26.4-23E5207q` |
| Mac16,11 27.0b2 | `17,3_26.6.1_23G83`   | `26.4-23E5207q` |
| Mac16,6 26.6.1  | `17,3_26.6.2_23G90`   | `26.4-23E5207q` |
| Mac16,11 27.0b2 | `17,3_27.0_24A5380h`  | `26.4-23E5207q` |
| Mac16,6 26.4.1  | `17,3_27.0_24A5390f`  | `26.4-23E5207q` |
| Mac16,6 26.6.1  | `17,3_27.0_24A5408d`  | `26.4-23E5207q` |
| Mac16,11 27.0b2 | `17,3_27.0_24A5418b`  | `26.4-23E5207q` |
| Mac16,11 27.0b2 | `17,3_27.0_24A5424a`  | `26.4-23E5207q` |
| Mac16,11 27.0b2 | `17,3_27.0_24A5430a`  | `26.4-23E5207q` |
| Mac16,6 26.6.1  | `17,3_27.0_24A435`    | `26.4-23E5207q` |

## FAQ

**`zsh: killed ./vphone-vm`** — AMFI/デバッグ制限がバイパスされていません。[SIP/AMFI の緩和](#sipamfi-の緩和) を参照してください（`amfi_get_out_of_my_way=1`（オプション A）、またはこのビルドに対する `make amfi_allow`（オプション B））。直近のビルドより前に実行したのであれば、もう一度実行してください: 許可は cdhash をキーにしており、署名がそれを変えます。なお `vphone-cli` 自体にこれは起こりません: entitlement を持たないため、*それ* が kill されている場合は別の原因があります。

**`Virtualization is not available on this hardware`** — お使いの Mac 自体が VM です。PV=3 ゲスト起動はネストできません。ネストされていない macOS 15+ ホストを使用してください。

**「Press home to continue」で止まる** — VNC で接続し、右クリック（2 本指クリック）してホームボタンをシミュレートします。

**システムアプリがインストールできない** — iOS のセットアップ中に、地域として日本や EU を選ばないでください（VM が満たせない追加の規制チェックが入ります）。例えば United States を選択してください。

**アプリが起動時に `EXC_GUARD` / `GUARD_TYPE_MACH_PORT` でクラッシュする** — `vphone-cli fw patch <name> --variant <v> --force-exc-guard` で再パッチし、再度復元/インストールしてください（[#291](https://github.com/Lakr233/vphone-cli/issues/291)）。iOS 18 ベースでは常に有効です。

**`.ipa`/`.tipa` をインストールする** — 実行中の VM の Install メニューを使用します（ドラッグ&ドロップまたはファイルピッカー）。

## 自動化

`vphone-cli` はプログラムによる制御のためにホスト制御ソケット（`<bundle>/vphone.sock`）を公開します — スクリーンショット、タッチ、スワイプ、ハードウェアキー、クリップボード — 各アクションは AI 駆動の E2E テスト用にインラインのスクリーンショットを返します。それをラップする MCP サーバーについては [vphone-mcp](https://github.com/pluginslab/vphone-mcp) を参照してください。

## 謝辞

- [wh1te4ever/super-tart-vphone-writeup](https://github.com/wh1te4ever/super-tart-vphone-writeup)
