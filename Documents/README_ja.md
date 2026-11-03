<div align="right"><a href="../README.md">English</a> · <a href="README_zh.md">中文</a> · <strong>日本語</strong> · <a href="README_ko.md">한국어</a></div>

# vphone-cli

Apple Silicon Mac で仮想 iPhone を実行します。

> [!WARNING]
> 本プロジェクトは、暗号資産やトークンを発行したことも、その発行を許可したこともありません。また、暗号資産による支払いや寄付は受け付けていません。本プロジェクトの名をかたって発行・宣伝されるものや、本プロジェクトとの関係をうたう暗号資産・トークンは、すべて詐欺です。

![macOS 上で動作する仮想 iPhone](demo.jpeg)

vphone-cli は Apple の Virtualization.framework と PCC 研究用仮想マシンを使って iOS を実行します。セキュリティ研究、リバースエンジニアリング、デバッグに適しています。

- **グラフィカルウィンドウ**：Mac 上で仮想 iPhone の画面を操作し、App とファイルを閲覧し、スクリーンショットの撮影や画面収録ができます。
- **カスタムファームウェア（Custom Firmware）**：システムにはあらかじめパッチが適用されており、パッケージ環境をインストールできます。
- **バックアップと複製**：仮想マシンの書き出し、読み込み、複製ができます。
- **自動化 API**：任意で有効にできる、ローカルの HTTP と WebSocket のインターフェースです。
- **追加の依存なし**：実行時に Xcode、Python、Homebrew は不要です。

## 準備

- macOS 15 以降を搭載した物理 Apple Silicon Mac。macOS の仮想マシン上では使用できません。
- 十分なディスク容量。仮想マシンごとに標準で 64 GB の仮想ディスクを使用し、ファームウェアと一時ファイルにも別途容量が必要です。
- ネットワーク接続。システムの復元時に署名チケットをオンラインで取得します。
- セキュリティ設定の変更。macOS 復旧モードに入り、ターミナルで次のコマンドを実行してから再起動します。

  ```sh
  csrutil enable --without debug
  csrutil allow-research-guests enable
  ```

  SIP は有効のまま、デバッグの制限だけを緩和します。理由と別の設定方法は[ホストの設定](Guides/host-setup.md)をご覧ください。

## クイックスタート

1. [最新のリリース](https://github.com/Lakr233/vphone-cli/releases/latest)から `vphone-launchpad-<バージョン>-notarized.zip` をダウンロードし、展開して開きます。すべてのリリースが公証済みではありません。最新リリースに `-notarized` ファイルがない場合は、[ダウンロードガイド](Downloads/README.md)から公証済みのバージョンを選んでください。
2. **Host Setup** で開発者ツールへのアクセスを許可し、ヘルパーをインストールします。
3. **Core Bundle** で **Download and Install** をクリックします。Launchpad が `VPhone.bundle` をダウンロードして検証し、その中の仮想マシン用プログラムがこの Mac で実行できるようにします。
4. **Machines** で **New Machine** をクリックし、ファームウェアの組み合わせを選んで **Create** をクリックします。

Launchpad がファームウェアのダウンロード、パッチの適用、システムの復元、初回起動を行います。完了後も仮想マシンは実行されたままです。

自分の iPhone と cloudOS の IPSW を使うこともできます。検証済みの組み合わせは[互換性ガイド](Guides/compatibility.md)をご覧ください。

### エージェントに任せる

この Mac でコーディングエージェント（Claude Code、Codex など）を使っている場合は、手順を手作業で進める代わりに、次のプロンプトを貼り付けてください。エージェントは vphone スキルを読み、設定済みの部分を確認して Launchpad と `VPhone.bundle` をインストールします。管理者パスワードや macOS 復旧モードでの変更など、あなたの操作が必要な手順では止まって確認します。

```text
この Mac に vphone をセットアップしてください。まず次のスキルを読んでください：
https://raw.githubusercontent.com/Lakr233/vphone-cli/main/Skills/vphone-guest-control/SKILL.md
および同じフォルダの references/ 以下にリンクされたファイルを読み、その手順に従います：
公証済みの最新の vphone-launchpad をインストールし（すべてのリリースに
-notarized zip があるわけではありません）、vphone-launchpad-cli を PATH に通し、
Launchpad と同じシリーズの VPhone.bundle をインストールして、
`vphone-launchpad-cli status` で確認してください。SIP、boot-args などホストの
セキュリティ設定は変更せず、ファームウェアと空きディスク容量を私が確認するまで
マシンは作成しないでください。私の操作が必要な手順では、何をすればよいかを
正確に伝えて待ってください。
```

## パッケージ環境のインストール

仮想マシンには標準でパッケージマネージャが入っていません。インストール手順は次のとおりです。

1. メニューバーで **Apps > Install Bootstrap…** を選び、レイアウトとして **roothide** を選択します（**rootless** は非推奨です）。仮想マシンに Irisin がインストールされます。
2. Irisin で **OwnGoal Packages** リポジトリを開き、**OwnGoal Bootstrap for vphone**（`owngoal-bootstrap-vphone`）を **Bootstrap Install** でインストールします。

   このパッケージ 1 つで、仮想マシンに必要なものが一度にそろいます：`apt` と `dpkg`、`bash`、`zsh` と `dash`、`sudo`、基本的なコマンドラインツール、`openssh-server`、`curl`、`wget`、`vim`、`git`、`uikittools`、`launchctl`、そして OwnGoal のアプリです。これらを一つずつインストールしないでください。一部のパッケージは相互に依存しており、`openssh-server` には循環した依存の記述があるため、個別にインストールすると途中で失敗することがあります。
3. 初回のインストール後は、ほかのパッケージを通常どおりインストールできます。

初回のインストールに失敗した場合や、環境が不整合な状態になった場合は、その場で修復しようとせず、**Apps > Uninstall Bootstrap…** で環境を削除し、手順 1 からインストールし直してください。

環境を削除するには **Apps > Uninstall Bootstrap…** を選びます。削除後、仮想マシンは再起動します。

Option キーを押しながら **Apps** メニューを開くと、さらに 2 つの項目があります。

- **Install Bootstrap from File…**：ローカルの Irisin `.deb` を使ってインストールします。
- **Uninstall Bootstrap Without Restarting…**：仮想マシンを再起動せずに環境を削除します。

## コマンドライン

Launchpad は `VPhone.bundle` 内の `vphone-cli` を使って仮想マシンを管理しています。ターミナルから直接使うこともできます。

| 操作 | コマンド |
| --- | --- |
| 仮想マシンの一覧表示 | `vphone-cli vm list` |
| 仮想マシンの情報表示 | `vphone-cli vm info myphone` |
| 仮想マシンの起動 | `vphone-cli vm launch myphone` |
| 仮想マシンの停止 | `vphone-cli vm stop myphone` |
| 仮想マシンの複製 | `vphone-cli vm clone myphone copy` |
| 仮想マシンの書き出し | `vphone-cli vm export myphone --out myphone.tzst` |
| 仮想マシンの読み込み | `vphone-cli vm import myphone.tzst --name restored` |

仮想マシンは標準で `~/.vphone/` に保存されます。すべてのコマンドは `vphone-cli <group> --help` で確認できます。Launchpad を使わずに仮想マシンを作成する方法は[作成と実行](Guides/create-and-run.md)をご覧ください。

### 自動化 API

起動時に `--api-listen` を指定すると有効になります。

```sh
vphone-cli vm launch myphone --api-listen 127.0.0.1:8765
# 出力に [api] token: … と表示されます
curl -H "Authorization: Bearer $TOKEN" http://127.0.0.1:8765/v1/health
```

token は起動のたびに新しく生成されます。token を固定するには、環境変数 `VPHONE_API_TOKEN` を設定してください。token のないリクエストと Web ページからのリクエストは、どちらも拒否されます。インターフェースの説明は [API ドキュメント](../Research/vphoned_http_api.md)をご覧ください。

## ブート ROM

新しく作成した仮想マシンは、Virtualization.framework に含まれるクローズドな ROM ではなく、2 つのオープンソース ROM から起動します。

- [OpenAVB](https://github.com/owngoal-dev/OpenAVB) はブート ROM の AVPBooter の代わりです。パッチが不要なので、`fw patch` は変更しません。
- [OpenSEP](https://github.com/owngoal-dev/OpenSEP) は SEP ブート ROM の AVPSEPBooter の代わりです。

両方を使うと、iBoot と SEPOS より前に実行されるコードに Apple が書いたものはなくなります。どちらもビルド済みの状態で `VPhone.bundle` に含まれており、固定した上流のコミットからビルドされています。それぞれの説明（[OpenAVB](../VPhoneExecutable/VPhoneVirtualization/Resources/OpenAVB/README.md)、[OpenSEP](../VPhoneExecutable/VPhoneVirtualization/Resources/OpenSEP/README.md)）に、ソースからビルドし直してバイト単位で照合する方法があります。

以前のバージョンで作成した仮想マシンは Apple の ROM のままです。どちらの ROM にも、システムを復元し直さずに切り替えられます。次回の起動から反映されます。

```sh
vphone-cli vm config myphone --rom openavb --seprom opensep   # オープンソース ROM
vphone-cli vm config myphone --rom apple --seprom apple       # Apple の ROM
```

`vphone-cli vm info myphone` で仮想マシンが使っている ROM を確認できます。OpenAVB で起動する仮想マシンを復元するには、`VPhone.bundle` 2.10.1 以降が必要です。詳しくは研究記録の [OpenAVB](../Research/Firmware/openavb_boot_rom.md) と [OpenSEP](../Research/Firmware/opensep_sep_rom.md) をご覧ください。

## 問題が起きたら

まず[トラブルシューティング](Guides/troubleshooting.md)をご覧ください。仮想マシン用プログラムがシステムに拒否される、復元に失敗する、「Press home to continue」で止まる、といった状況を扱っています。それでも解決しない場合は、[issue を送信](https://github.com/Lakr233/vphone-cli/issues)してください。

## ドキュメント

| ドキュメント | 内容 |
| --- | --- |
| [ダウンロードガイド](Downloads/README.md) | 公証済みの Launchpad バージョンと対応する `VPhone.bundle` バージョン |
| [ホストの設定](Guides/host-setup.md) | SIP と AMFI の設定、ソースからのビルド、環境の確認 |
| [作成と実行](Guides/create-and-run.md) | 作成の流れ、仮想マシンの起動と停止 |
| [テンプレート](Guides/templates.md) | 1 回の復元から複数の仮想マシンを作成し、ゲストを軽量化する |
| [ライブラリとバックアップ](Guides/library-and-backups.md) | 仮想マシンの保存場所、複製と書き出し |
| [互換性ガイド](Guides/compatibility.md) | 検証済みのファームウェアの組み合わせ |
| [スナップショット](Guides/snapshots.md) | 停止中の仮想マシンのディスク状態を保存し、その状態に戻す |
| [iPadOS ゲスト](Guides/ipados.md) | iOS の代わりに iPadOS を実行する |
| [その他の iPhone モデル](Guides/iphone-models.md) | 別の iPhone モデルの IPSW で iOS を実行する |
| [パッケージ環境](Guides/package-environment.md) | 仮想マシンのパッケージマネージャのインストールと削除 |
| [トラブルシューティング](Guides/troubleshooting.md) | よくあるエラーと対処方法 |
| [ネットワーク](Guides/networking.md) | ネットワークモード、アドレス、ポート転送と、Mac が VPN やプロキシを使うときの `tunnel` |
| [Launchpad コマンドライン](Guides/launchpad-cli.md) | `vphone-launchpad-cli` でローカルビルドをインストールしてテストする |
| [すべてのガイド](README.md) | 主題別にまとめたすべてのガイド |
| [研究記録](../Research/README.md) | パッチと実装の詳細 |

## プロジェクト構成

- `vphone-launchpad`：Mac App です。`VPhone.bundle` のダウンロードとインストール、ホストの設定を行います。別途配布されます。
- `vphone-cli`：ファームウェアの準備、パッチの適用、システムの復元、仮想マシンの管理を行います。
- `vphone-vm`：仮想マシンを実行し、仮想マシンのウィンドウを表示します。
- `vphoned`：仮想マシン内の制御サービスです。ウィンドウの機能と API は、すべてこれを通じて実現されています。

| パス | 内容 |
| --- | --- |
| [`VPhoneExecutable/`](../VPhoneExecutable/) | `vphone-cli`、`vphone-vm`、ファームウェアパッチと復元 |
| [`VPhoneKit/`](../VPhoneKit/) | ホスト側の共有ライブラリと API クライアント |
| [`VPhoneDaemon/`](../VPhoneDaemon/) | `vphoned` |
| [`VPhoneGuestComponents/`](../VPhoneGuestComponents/) | 仮想マシン内のフックと補助プログラム |
| [`VPhoneLaunchpad/`](../VPhoneLaunchpad/) | Launchpad App とそのヘルパー |

ソースからのビルド：`xcodebuild -workspace VPhone.xcworkspace -scheme VPhone build`。成果物は `VPhone.bundle` です。

## 謝辞

- [wh1te4ever/super-tart-vphone-writeup](https://github.com/wh1te4ever/super-tart-vphone-writeup)
- [owngoal-dev/OpenAVB](https://github.com/owngoal-dev/OpenAVB) と [owngoal-dev/OpenSEP](https://github.com/owngoal-dev/OpenSEP)：新しい仮想マシンが起動に使うブート ROM
