<div align="right"><strong>🇯🇵日本語</strong> | <strong><a href="./README_zh.md">🇨🇳中文</a></strong> | <strong><a href="./README.md">🇬🇧English</a></strong></div>

# vphone-cli

Apple の Virtualization.framework と PCC の研究用 VM インフラを使用して、仮想 iPhone (iOS 26) を起動するためのツール

![poc](./demo.png)

## 検証済み環境

| ホスト         | iPhone             | CloudOS       |
| ------------- | ------------------ | ------------- |
| Mac16,12 26.3 | `17,3_26.1_23B85`  | `26.1-23B85`  |
| Mac16,12 26.3 | `17,3_26.3_23D127` | `26.1-23B85`  |
| Mac16,12 26.3 | `17,3_26.3_23D127` | `26.3-23D128` |

## 前提条件

**SIPとAMFIを無効化** — プライベートな Virtualization.framework の entitlement を使うために必要です。

復旧モードで起動し（電源ボタンを長押し）、ターミナルを開いて以下を実行します：

```bash
csrutil disable
csrutil allow-research-guests enable
```

通常の macOS に再起動した後：

```bash
sudo nvram boot-args="amfi_get_out_of_my_way=1 -v"
```

実行したらもう一度再起動します。

**依存関係のインストール:**

```bash
brew install gnu-tar openssl@3 ldid-procursus sshpass keystone autoconf automake pkg-config libtool git-lfs
```

**Git LFS** — このリポジトリは大きなリソースアーカイブに Git LFS を使用しています。ビルド前にインストールと pull を行ってください：

```bash
git lfs install
git lfs pull
```

## 初回セットアップ

```bash
make setup_machine            # 初回起動までを完全自動化（復元/ラムディスク/CFWを含む）

# 手動で行う場合：
make setup_tools              # brew の依存関係インストール、trustcache + libimobiledevice のビルド、Python venv の作成
source .venv/bin/activate
```

`make setup_machine` は、依然として手動での **リカバリーモードの SIP/research-guest 設定** と、出力される初回起動コマンドを実行するためのインタラクティブなVMコンソールが必要です。スクリプトはこれらのセキュリティ設定を検証しません。

## クイックスタート

```bash
make build                    # vphone-cliのビルド + 署名
make vm_new                   # vm/ ディレクトリの作成（ROM、ディスク、SEP ストレージ）
make fw_prepare               # IPSW のダウンロード、抽出、マージ、マニフェスト生成
make fw_patch                 # ブートチェーンのパッチ当て（6コンポーネント、41箇所以上の変更）
```

## 復元

復元プロセスには **2つのターミナル** が必要です。ターミナル 2 を使用している間、ターミナル 1 を実行し続けてください。

```bash
# ターミナル 1
make boot_dfu                 # DFUモードでVMを起動（実行したままにする）
```

```bash
# ターミナル 2
make restore_get_shsh         # SHSH blob の取得
make restore                  # idevicerestore 経由でファームウェアを焼き込み
```

## Ramdisk と CFW

ターミナル 1 の DFU 起動を停止し（Ctrl+C）、Ramdisk 用に再び DFU で起動します：

```bash
# ターミナル 1
make boot_dfu                 # 実行したままにする
```

```bash
# ターミナル 2
make ramdisk_build            # 署名済みSSH Ramdisk のビルド
make ramdisk_send             # デバイスへ送信
```

Ramdisk が起動したら（出力に `Running server` と表示されるはずです）、iproxy トンネル用 に **3つ目のターミナル** を開き、ターミナル 2 から CFW をインストールします：

```bash
# ターミナル 3 — 実行したままにする
iproxy 2222 22
```

```bash
# ターミナル 2
make cfw_install
```

## 初回起動

ターミナル 1 の DFU 起動を停止し（Ctrl+C）、以下を実行します：

```bash
make boot
```

これにより VM に **直接繋がるコンソール** が開きます。`bash-4.4#` と表示されたら、Enter を押し、シェル環境を初期化して SSH ホストキーを生成するために以下のコマンドを実行します：

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

別のターミナルで iproxy トンネルを開始します：

```bash
iproxy 22222 22222   # SSH
iproxy 5901 5901     # VNC
iproxy 5910 5910     # RPC
```

以下で接続します：

- **SSH:** `ssh -p 22222 root@127.0.0.1` (パスワード: `alpine`)
- **VNC:** `vnc://127.0.0.1:5901`
- [**RPC:**](http://github.com/doronz88/rpc-project) `rpcclient -p 5910 127.0.0.1`

## Makefile の全ターゲット

完全なリストは `make help` を実行してください。主なターゲット：

| ターゲット            | 説明                          |
| ------------------- | ---------------------------- |
| `build`             | vphone-cli のビルド + 署名      |
| `vm_new`            | VM ディレクトリの作成            |
| `fw_prepare`        | IPSW のダウンロード/マージ       |
| `fw_patch`          | ブートチェーンのパッチ当て         |
| `boot` / `boot_dfu` | VMの起動 (GUI / DFU ヘッドレス)  |
| `restore_get_shsh`  | SHSH blobの取得                |
| `restore`           | ファームウェアのフラッシュ         |
| `ramdisk_build`     | SSH Ramdisk のビルド           |
| `ramdisk_send`      | Ramdisk の送信                 |
| `cfw_install`       | CFW のインストール              |
| `clean`             | ビルドアーティファクトの削除       |

## よくある質問 (FAQ)

> **何よりもまず — `git pull` を実行して最新バージョンであることを確認してください**

**Q: 実行しようとすると `zsh: killed ./vphone-cli` と表示されます**

AMFIが無効化されていません。boot-arg を設定して再起動してください：

```bash
sudo nvram boot-args="amfi_get_out_of_my_way=1 -v"
```

**Q: "Press home to continue" の画面から進めません**

VNC経由で接続し（`vnc://127.0.0.1:5901`）、画面の任意の場所を右クリック（Mac のトラックパッドでは 2 本指クリック）してください。これによりホームボタンの押下がシミュレートされます。

**Q: SSH を接続した後にすぐ切断されます（`Connection closed by 127.0.0.1`）**

初回起動時にDropbearホストキーが生成されていません。VNC または `make boot` コンソール経由で接続し、以下を実行してください：

```bash
export PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/bin/X11:/usr/games:/iosbinpack64/usr/local/sbin:/iosbinpack64/usr/local/bin:/iosbinpack64/usr/sbin:/iosbinpack64/usr/bin:/iosbinpack64/sbin:/iosbinpack64/bin'
mkdir -p /var/dropbear
dropbearkey -t rsa -f /var/dropbear/dropbear_rsa_host_key
dropbearkey -t ecdsa -f /var/dropbear/dropbear_ecdsa_host_key
killall dropbear
dropbear -R -p 22222
```

**Q: もっと新しいiOSバージョンにアップデートできますか？**

はい。`fw_prepare` に希望するバージョンの IPSW URL を指定することでできます：

```bash
export IPHONE_SOURCE=/path/to/some_os.ipsw
export CLOUDOS_SOURCE=/path/to/some_os.ipsw
make fw_prepare
make fw_patch
```

私たちのパッチは静的なオフセットではなくバイナリ解析によって適用されるため、新しいバージョンでも動作するはずです。何か壊れた場合は AI に聞いてください。

## 謝辞

- [wh1te4ever/super-tart-vphone-writeup](https://github.com/wh1te4ever/super-tart-vphone-writeup)
