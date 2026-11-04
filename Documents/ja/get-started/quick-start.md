# クイックスタート

Launchpad で vphone をセットアップし、最初の仮想 iPhone を起動します。Mac が[概要](overview.md)の「必要なもの」に記載された条件を満たしたら始めてください。

## Launchpad でセットアップする

1. [最新のリリース](https://github.com/Lakr233/vphone-cli/releases/latest)から `vphone-launchpad-<version>-notarized.zip` をダウンロードし、展開して開きます。すべてのリリースが公証済みとは限りません。最新のリリースに `-notarized` ファイルがない場合は、[ダウンロード](downloads.md)から公証済みのバージョンを選んでください。
2. **Host Setup**（ホストの設定）でデベロッパツールへのアクセスを許可し、ヘルパーをインストールします。
3. **Core Bundle** で **Download and Install**（ダウンロードしてインストール）をクリックします。
4. **Machines**（マシン）で **New Machine**（新規マシン）をクリックし、ファームウェアの組み合わせを選んで **Create**（作成）をクリックします。

Launchpad がファームウェアのダウンロード、パッチの適用、システムの復元、仮想マシンの起動を行います。自分で用意した iPhone と cloudOS の IPSW を使う場合は、[互換性](../firmware/compatibility.md)をご覧ください。

## エージェントに任せる

この Mac でコーディングエージェント（Claude Code、Codex など）を使っている場合は、手順を手作業で進める代わりに、次のプロンプトを貼り付けてください。エージェントは vphone スキルを読み、設定済みの部分を確認して Launchpad と `VPhone.bundle` をインストールします。管理者パスワードや macOS 復旧での変更など、あなたの操作が必要な手順では止まって確認します。

```text
この Mac に vphone をセットアップしてください。次のスキルを読み、
https://raw.githubusercontent.com/Lakr233/vphone-cli/main/Skills/vphone-guest-control/SKILL.md
そこからリンクされている references/ 以下（同じフォルダ）のファイルも読んで、その手順に従ってください：
公証済みの最新の vphone-launchpad をインストールし（すべてのリリースに
-notarized zip があるわけではありません）、vphone-launchpad-cli を PATH に通し、
Launchpad と同じシリーズの VPhone.bundle をインストールして、
`vphone-launchpad-cli status` で確認してください。SIP、boot-args などホストの
セキュリティ設定は変更せず、ファームウェアと空きディスク容量を私が確認するまで
マシンは作成しないでください。私の操作が必要な手順では、何をすればよいかを
正確に伝えて待ってください。
```

## 次のステップ

- 仮想マシンにパッケージマネージャをインストールする：[パッケージ環境](../machines/package-environment.md)
- ターミナルから仮想マシンを操作する、または Launchpad を使わずに作成する：[仮想マシンの作成と実行](../machines/create-and-run.md)
- HTTP と WebSocket で仮想マシンをスクリプトから操作する：[自動化 API](../machines/automation-api.md)
- 問題が起きた場合：[トラブルシューティング](../help/troubleshooting.md)

## 関連項目

- [ホストの設定](host-setup.md)
- [ダウンロード](downloads.md)
- [Launchpad コマンドライン](../launchpad/launchpad-cli.md)
