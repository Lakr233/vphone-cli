<div align="right"><strong><a href="./README_ko.md">🇰🇷한국어</a></strong> | <strong>🇯🇵日本語</strong> | <strong><a href="./README_zh.md">🇨🇳中文</a></strong> | <strong><a href="../README.md">🇬🇧English</a></strong></div>

# vphone-cli

Apple の Virtualization.framework と PCC の研究用 VM インフラを使用して、仮想 iPhone を起動するためのツール

![poc](./demo.jpeg)

## 検証済み環境

| ホスト           | iPhone                | CloudOS         |
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
| Mac16,11 27.0b2 | `17,3_27.0_24A5380h`  | `26.4-23E5207q` |

iOS 27.0 は 26.4 PCC vphone600 スタックに加えて、CFW 時の force-kern `IOMobileFramebuffer` present-path パッチと dyld 共有キャッシュの `maxSlide` 調整を使用します。

**注意:** iOS 18.x では Metal/GPU アクセラレーションは動作しません。18.x の Metal/IOGPU フレームワークに準仮想化 GPU の実装が存在しないため、Metal でレンダリングされるコンテンツ（Web ページ、画像、壁紙）は表示されません。タッチ、ネットワーク、アプリは正常に動作します。

## ファームウェアバリアント

セキュリティバイパスのレベルが異なる5つのパッチバリアントが利用可能です：

| バリアント    | ブートチェーン     |     CFW      | Make ターゲット                              |
| ------------- | :----------------: | :----------: | -------------------------------------------- |
| **Patchless** | 4 パッチ           | 2 フェーズ   | `fw_patch_less` + `boot_less`              |
| **通常版**    | 42 パッチ          | 10 フェーズ  | `fw_patch` + `cfw_install`                   |
| **開発版**    | 53 パッチ          | 12 フェーズ  | `fw_patch_dev` + `cfw_install_dev`           |
| **脱獄版**    | 113 パッチ         | 14 フェーズ  | `fw_patch_jb` + `cfw_install_jb`             |
| **実験版**    | 脱獄 + EXP 専用    | 脱獄 + EXP   | `fw_patch_exp` + `cfw_install_exp`           |

> JB最終設定（シンボリックリンク、Sileo、apt、TrollStore）は `/cores/vphone_jb_setup.sh` LaunchDaemon により初回起動時に自動実行されます。進捗確認：`/var/log/vphone_jb_setup.log`。

> **実験版（EXP）** は脱獄版の上位集合で、リサーチブランチの実験的パッチを追加で実行します：カーネルの `hv_vmm_present` sysctl リネーム + カーネル内部呼び出し元の改変（`KernelEXPPatcher`）、サインインブラックリスト付きの DSC バイト5改変 + スロット再認証、watchdogd 精密 2 命令パッチ（EXP-JB-3.5）、fw_patch 時点での DeviceTree アイデンティティプロパティ 8 件、復元後の DT アイデンティティ書き換え（EXP-JB-6）、`SPOOF_BUILD=<id>` によるオプトイン式の `SystemVersion.plist` `ProductBuildVersion` 書き換え（EXP-JB-7）。他のバリアントは意図的に影響を受けません。

詳細なコンポーネントごとの内訳については [research/0_binary_patch_comparison.md](../research/0_binary_patch_comparison.md) を参照してください。

## 前提条件

**ホストOS:** PV=3 仮想化には macOS 15+（Sequoia）が必要です。

**SIP/AMFIの設定** — プライベートな Virtualization.framework の entitlement と未署名バイナリのワークフローに必要です。

復旧モードで起動し（電源ボタンを長押し）、ターミナルを開いて、以下のいずれかの方法を選択します：

- **方法 1：SIP を完全に無効化 + AMFI boot-arg（最も制限が少ない）**

  復旧モードで：

  ```bash
  csrutil disable
  csrutil allow-research-guests enable
  ```

  通常の macOS に再起動した後：

  ```bash
  sudo nvram boot-args="amfi_get_out_of_my_way=1 -v"
  ```

  もう一度再起動します。

- **方法 2：SIP はほぼ有効のまま、デバッグ制限のみ無効化、[`amfidont`](https://github.com/zqxwce/amfidont) または [`amfree`](https://github.com/retX0/amfree) を使用**

  復旧モードで：

  ```bash
  csrutil enable --without debug
  csrutil allow-research-guests enable
  ```

  通常の macOS に再起動した後：

  ```bash
  # amfidont の場合:
  xcrun python3 -m pip install amfidont
  sudo amfidont --path [PATH_TO_VPHONE_DIR]
  
  # または amfree の場合:
  brew install retX0/tap/amfree
  sudo amfree --path [PATH_TO_VPHONE_DIR]
  ```

  このリポジトリでは、`make amfidont_allow_vphone` を実行すると
  `amfidont` 用のエンコード済みパスと CDHash の許可設定をまとめて行えます。

> Patchless バリアントでは、方法 1 か、`-S` フラグ付きの amfidont（`sudo amfidont -S --path [PATH_TO_VPHONE_DIR]`）が必要です。

**依存関係のインストール:**

```bash
brew install aria2 wget gnu-tar openssl@3 ldid-procursus sshpass keystone libusb ipsw zstd
```

`scripts/fw_prepare.sh` は高速な多重接続ダウンロードのために `aria2c` を優先し、必要に応じて `curl` または `wget` にフォールバックします。

**Submodules** — このリポジトリはリソース、Swift 依存、`scripts/repos/` 配下のツールチェーンソースに git submodule を使用しています。クローン時に以下を使用してください：

```bash
git clone --recurse-submodules https://github.com/Lakr233/vphone-cli.git
```

## クイックスタート

```bash
make setup_machine            # 初回起動までを完全自動化（復元/CFWを含む）
# オプション：NON_INTERACTIVE=1 SUDO_PASSWORD=...
# LESS=1 で patchless バリアント（- AMFI, SSV, Img4, TXM バイパス）
# DEV=1 で開発バリアント（+ TXM entitlement/デバッグバイパス）
# JB=1 で脱獄バリアント（dev + 完全セキュリティバイパス）
# EXP=1 で実験バリアント（脱獄 + リサーチパッチ: hv_vmm リネーム、DT アイデンティティ、復元後書き換え）
# SPOOF_BUILD=<id>（EXP 限定）SystemVersion.plist の ProductBuildVersion を <id> に書き換え、例: 23F77
```

## 手動セットアップ

```bash
make setup_tools              # brew 依存関係のインストール、trustcache + insert_dylib のビルド、Python venv 作成（pymobiledevice3/aria2c を含む）
make build                    # vphone-cli のビルド + 署名
make vm_new                   # VM ディレクトリとマニフェスト（config.plist）の作成
# オプション：CPU=8 MEMORY=8192 DISK_SIZE=64
make fw_prepare               # IPSW のダウンロード、抽出、マージ、マニフェスト生成
make fw_patch                 # ブートチェーンのパッチ当て（通常バリアント）
# または: sudo make fw_patch_less # patchless バリアント（- AMFI, SSV, Img4, TXM バイパス）
# または: make fw_patch_dev   # 開発バリアント（+ TXM entitlement/デバッグバイパス）
# または: make fw_patch_jb    # 脱獄バリアント（dev + 完全セキュリティバイパス）
# または: make fw_patch_exp   # 実験バリアント（脱獄 + リサーチパッチスタック）
```

### クリーンアップ

```bash
make clean                    # ビルド/ツール関連の生成物のみ削除
make clean CLEAN_VM=1         # 確認後、vm/ も削除
make clean CLEAN_IPSW=1       # 確認後、ipsws/ も削除
```

通常の clean では `vm/` や `ipsws/` は削除されません。

### VM 設定

v1.0 から、VM 設定は `vm/config.plist` に保存されます。VM 作成時に CPU、メモリ、ディスクサイズを設定します：

```bash
# カスタム設定で VM を作成
make vm_new CPU=16 MEMORY=16384 DISK_SIZE=128

# 起動時に config.plist から設定を自動読み込み
make boot
```

マニフェストファイルはすべての VM 設定（CPU、メモリ、画面、ROM、ストレージ）を保存し、[security-pcc の VMBundle.Config 形式](https://github.com/apple/security-pcc) と互換性があります。

## 復元

復元プロセスには **2つのターミナル** が必要です。ターミナル 2 を使用している間、ターミナル 1 を実行し続けてください。

```bash
# ターミナル 1
make boot_dfu                 # DFUモードでVMを起動（実行したままにする）
```

```bash
# ターミナル 2
make restore_get_shsh         # SHSH blob の取得
make restore                  # pymobiledevice3 restore バックエンドでファームウェアを焼き込み
# または: make restore_offline    # オフライン復元（AEA イメージをその場で復号し、キャッシュ済み .shsh blob を使用）
                                  # 初回は AEA 復号のためインターネット接続が必要です
```

## カスタムファームウェアのインストール

復元が完了したら、ターミナル 1 の DFU 起動を停止（Ctrl+C）して VM を完全に電源オフにします。インストーラは VM の `Disk.img` をホスト側でマウントし、すべての CFW ファイルを配置してブートスナップショットをオフラインで切り替えます（DFU / Ramdisk / SSH は不要）。そのためディスクへの排他アクセスが必要です。

```bash
# ターミナル 2（自動的に sudo で再実行されます）
make cfw_install
# または: make cfw_install_dev       # 開発バリアント
# または: make cfw_install_jb        # 脱獄バリアント
# または: make cfw_install_exp       # 実験バリアント（脱獄 + リサーチパッチスタック）
# または: SPOOF_BUILD=23F77 make cfw_install_exp   # ProductBuildVersion も書き換え
```

## 初回起動

DFU 起動を停止し CFW をインストールしたら、VM を通常起動します：

```bash
make boot
```

`cfw_install_jb` 実行後、脱獄バリアントでは初回起動時に **Sileo** と **TrollStore** が利用可能になります。Sileo から `openssh-server` をインストールして SSH アクセスを有効にできます。

通常版/開発版では、VM に**直接繋がるコンソール**が開きます。`bash-4.4#` と表示されたら、Enter を押し、シェル環境を初期化して SSH ホストキーを生成するために以下のコマンドを実行します：

```bash
export PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/bin/X11:/usr/games:/iosbinpack64/usr/local/sbin:/iosbinpack64/usr/local/bin:/iosbinpack64/usr/sbin:/iosbinpack64/usr/bin:/iosbinpack64/sbin:/iosbinpack64/bin'

mkdir -p /var/dropbear
cp /iosbinpack64/etc/profile /var/profile
cp /iosbinpack64/etc/motd /var/motd

# SSHホストキーの生成（SSHを機能させるために必要）
dropbearkey -t rsa -f /var/dropbear/dropbear_rsa_host_key
dropbearkey -t ecdsa -f /var/dropbear/dropbear_ecdsa_host_key

shutdown -h now
```

> **注意:** ホストキー生成手順を行わないと、dropbear（SSH サーバー）は接続を受け付けますが、SSH ハンドシェイクを実行するためのキーがないためすぐに切断されます。

## 2回目以降の起動

```bash
make boot
```

別のターミナルで usbmux 転送トンネルを開始します：

```bash
python3 -m pymobiledevice3 usbmux forward 2222 22222    # SSH（dropbear）
python3 -m pymobiledevice3 usbmux forward 2222 22       # SSH（脱獄版：Sileo で openssh-server を入れた場合）
python3 -m pymobiledevice3 usbmux forward 5901 5901     # VNC
python3 -m pymobiledevice3 usbmux forward 5910 5910     # RPC
```

以下で接続します：

- **SSH（脱獄版）:** `ssh -p 2222 mobile@127.0.0.1` (パスワード: `alpine`)
- **SSH（通常版/開発版）:** `ssh -p 2222 root@127.0.0.1` (パスワード: `alpine`)
- **VNC:** `vnc://127.0.0.1:5901`
- [**RPC:**](http://github.com/doronz88/rpc-project) `rpcclient -p 5910 127.0.0.1`

## VM バックアップと切り替え

複数の VM 環境（異なる iOS ビルドやファームウェアバリアントなど）を保存して切り替えることができます。バックアップは `vm.backups/` に保存され、`rsync --sparse` でスパースディスクイメージを効率的に処理します。

```bash
make vm_backup NAME=26.1-clean    # 現在の VM を保存
rm -rf vm && make vm_new          # 新しいビルド用に初期化
# ... fw_prepare, fw_patch, restore, cfw_install, boot
make vm_backup NAME=26.3-jb       # 新しい VM も保存
make vm_list                      # すべてのバックアップを一覧表示
make vm_switch NAME=26.1-clean    # バックアップ間を切り替え
```

> **注意:** バックアップ/切り替え/復元の前に必ず VM を停止してください。

## よくある質問 (FAQ)

> **何よりもまず — `git pull` を実行して最新バージョンであることを確認してください**

**Q: 実行しようとすると `zsh: killed ./vphone-cli` と表示されます**

AMFI/デバッグ制限が正しくバイパスされていません。以下のいずれかの方法を選択してください：

- **方法 1（AMFI を完全に無効化）：**

  ```bash
  sudo nvram boot-args="amfi_get_out_of_my_way=1 -v"
  ```

- **方法 2（デバッグ制限のみ無効化）：**
  復旧モードで `csrutil enable --without debug`（完全な SIP 無効化は不要）を使用し、[`amfidont`](https://github.com/zqxwce/amfidont) または [`amfree`](https://github.com/retX0/amfree) をインストール/ロードして AMFI のその他の機能は有効のままにします。
  このリポジトリでは、`make amfidont_allow_vphone` により `amfidont` で必要なエンコード済みパスと CDHash の許可設定を自動で行えます。

**Q: `make boot` / `make boot_dfu` が `VZErrorDomain Code=2 "Virtualization is not available on this hardware."` で失敗します**

ホスト自体が Apple 仮想マシン上で動作しているため、ネストされた Virtualization.framework のゲスト起動は利用できません。ネストされていない macOS 15+ ホストで実行してください。`make boot_host_preflight` ではこの状態を `Model Name: Apple Virtual Machine 1` と `kern.hv_vmm_present=1` として確認できます。現在は `boot_binary_check` により、該当ホストでは起動前に早期失敗します。

**Q: システムアプリ（App Store、メッセージなど）がダウンロード・インストールできません**

iOS の初期設定時に、地域として**日本**または**欧州連合**を選択**しないでください**。これらの地域では追加の規制チェック（サイドローディングの開示、カメラのシャッター音など）が適用されますが、仮想マシンではこれらの要件を満たせないため、システムアプリのダウンロードおよびインストールができなくなります。この問題を回避するには、他の地域（例: 米国）を選択してください。

**Q: "Press home to continue" の画面から進めません**

VNC経由で接続し（`vnc://127.0.0.1:5901`）、画面の任意の場所を右クリック（Mac のトラックパッドでは 2 本指クリック）してください。これによりホームボタンの押下がシミュレートされます。

**Q: SSH アクセスを有効にするには？**

Sileo から `openssh-server` をインストールしてください（脱獄バリアントの初回起動後に利用可能）。

**Q: openssh-server をインストールしても SSH が動作しません。**

VM を再起動してください。次回起動時に SSH サーバーが自動的に開始されます。

**Q: `.tipa` ファイルをインストールできますか？**

はい。インストールメニューは `.ipa` と `.tipa` パッケージの両方に対応しています。ドラッグ＆ドロップまたはファイルピッカーを使用してください。

**Q: もっと新しいiOSバージョンにアップデートできますか？**

はい。`fw_prepare` に希望するバージョンの IPSW URL を指定することでできます：

```bash
export IPHONE_SOURCE=/path/to/some_os.ipsw
export CLOUDOS_SOURCE=/path/to/some_os.ipsw
make fw_prepare
make fw_patch
```

私たちのパッチは静的なオフセットではなくバイナリ解析によって適用されるため、新しいバージョンでも動作するはずです。何か壊れた場合は AI に聞いてください。

**Q: `restore_offline` を使ったらセットアップ画面で進めなくなりました**

セットアップ中に Apple への接続が必要ですが、`restore_offline` を使った場合はインターネットに接続されていない可能性があります。
デバイスを監視対象（supervised）にすることで、セットアップ画面の多くを回避できます：

```bash
python3 -m pymobiledevice3 profile supervise vphone
```

## 謝辞

- [wh1te4ever/super-tart-vphone-writeup](https://github.com/wh1te4ever/super-tart-vphone-writeup)
