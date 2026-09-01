<div align="right"><strong><a href="./README_ko.md">🇰🇷한국어</a></strong> | <strong>🇯🇵日本語</strong> | <strong><a href="./README_zh.md">🇨🇳中文</a></strong> | <strong><a href="../README.md">🇬🇧English</a></strong></div>

# vphone-cli

PCC リサーチ VM インフラストラクチャを使用し、Apple の Virtualization.framework 経由で仮想 iPhone を起動します。

![poc](./demo.jpeg)

## 前提条件

**ホスト:**

- Apple Silicon
- macOS 15+ (Sequoia)
- Xcode + iOS SDK（ゲストデーモンをクロスコンパイルするため）
- [未署名バイナリでプライベートな PV=3 エンタイトルメントを許可するための SIP/AMFI の緩和](#sipamfi-の緩和)

**依存関係:**

```bash
brew install python@3.13 aria2 wget gnu-tar openssl@3 ldid-procursus sshpass keystone cmake libusb ipsw zstd
```

## インストール

```bash
brew install zqxwce/tap/vphone-cli
```

## ビルド

```bash
git clone --recurse-submodules https://github.com/Lakr233/vphone-cli.git

./scripts/setup_tools.sh      # 依存関係のインストール、ツールチェーンのサブモジュールのビルド、Python venv の作成
./scripts/build.sh            # vphone-cli のビルド + 署名、.app のバンドル、vphoned のクロスコンパイル

cd .build/vphone-cli.app/Contents/MacOS/
vphone-cli --help
```

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
| `~/.vphone/venv/` | 自動的にプロビジョニングされる Python 環境（[Python ランタイム](#python-ランタイム) を参照。`$VPHONE_VENV_DIR` で上書き可能）。 |

優先順位: 項目ごとの上書き（`$VPHONE_LIBRARY_ROOT`、`$VPHONE_VENV_DIR`）が `$VPHONE_ROOT` より優先され、`$VPHONE_ROOT` は `~/.vphone` のデフォルトより優先されます。`ipsws/`、`tools/`、`debs/` キャッシュは、常に現在有効なルートの直下に置かれます。

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

**オプション B — SIP を有効なまま（デバッグのみ緩和）にし、amfidont でバイナリを許可リストに追加する**（AMFI はシステム全体で有効なまま）。

リカバリーモードで:

```bash
csrutil enable --without debug
csrutil allow-research-guests enable
```

その後 macOS で再起動し:

```bash
vphone-amfidont         # ローカルビルドの場合は .build/vphone-cli.app/Contents/Resources/vphone-amfidont
```

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
| Mac16,11 27.0b2 | `17,3_27.0_24A5380h`  | `26.4-23E5207q` |
| Mac16,6 26.4.1  | `17,3_27.0_24A5390f`  | `26.4-23E5207q` |
| Mac16,6 26.6.1  | `17,3_27.0_24A5408d`  | `26.4-23E5207q` |
| Mac16,11 27.0b2 | `17,3_27.0_24A5418b`  | `26.4-23E5207q` |
| Mac16,11 27.0b2 | `17,3_27.0_24A5424a`  | `26.4-23E5207q` |
| Mac16,11 27.0b2 | `17,3_27.0_24A5430a`  | `26.4-23E5207q` |

## FAQ

**`zsh: killed ./vphone-cli`** — AMFI/デバッグ制限がバイパスされていません。[前提条件](#前提条件) を参照してください（`amfi_get_out_of_my_way=1` または `amfidont`）。

**`Virtualization is not available on this hardware`** — お使いの Mac 自体が VM です。PV=3 ゲスト起動はネストできません。ネストされていない macOS 15+ ホストを使用してください。

**「Press home to continue」で止まる** — VNC で接続し、右クリック（2 本指クリック）してホームボタンをシミュレートします。

**システムアプリがインストールできない** — iOS のセットアップ中に、地域として日本や EU を選ばないでください（VM が満たせない追加の規制チェックが入ります）。例えば United States を選択してください。

**アプリが起動時に `EXC_GUARD` / `GUARD_TYPE_MACH_PORT` でクラッシュする** — `vphone-cli fw patch <name> --variant <v> --force-exc-guard` で再パッチし、再度復元/インストールしてください（[#291](https://github.com/Lakr233/vphone-cli/issues/291)）。iOS 18 ベースでは常に有効です。

**`.ipa`/`.tipa` をインストールする** — 実行中の VM の Install メニューを使用します（ドラッグ&ドロップまたはファイルピッカー）。

## 自動化

`vphone-cli` はプログラムによる制御のためにホスト制御ソケット（`<bundle>/vphone.sock`）を公開します — スクリーンショット、タッチ、スワイプ、ハードウェアキー、クリップボード — 各アクションは AI 駆動の E2E テスト用にインラインのスクリーンショットを返します。それをラップする MCP サーバーについては [vphone-mcp](https://github.com/pluginslab/vphone-mcp) を参照してください。

## 謝辞

- [wh1te4ever/super-tart-vphone-writeup](https://github.com/wh1te4ever/super-tart-vphone-writeup)
