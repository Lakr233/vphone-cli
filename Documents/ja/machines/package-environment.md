# パッケージ環境

仮想マシンにパッケージマネージャをインストールしたり、削除したりします。新しい仮想マシンにはパッケージマネージャがありません。ゲストで `apt`、シェル、SSH などのコマンドラインツールが必要な場合は、このページの手順に従ってください。

## インストール

1. 仮想マシンのウィンドウのメニューバーで **Apps > Install Bootstrap…** を選び、レイアウトとして **roothide** を選択します（**rootless** は非推奨です）。仮想マシンに Irisin がインストールされます。
2. Irisin で **OwnGoal Packages** リポジトリを開き、**OwnGoal Bootstrap for vphone**（`owngoal-bootstrap-vphone`）を探して **Bootstrap Install** でインストールします。
3. この初回のインストール後は、ほかのパッケージを通常どおりインストールできます。

`owngoal-bootstrap-vphone` 1 つで、仮想マシンに必要なものが一度にそろいます：`apt` と `dpkg`、`bash`、`zsh` と `dash`、`sudo`、基本的なコマンドラインツール、`openssh-server`、`curl`、`wget`、`vim`、`git`、`uikittools`、`launchctl`、そして OwnGoal のアプリです。

> [!WARNING]
> これらのパッケージを一つずつインストールしないでください。いくつかのパッケージは相互に依存しており、`openssh-server` には循環した依存の記述があるため、個別にインストールすると途中で失敗することがあります。

初回のインストールに失敗した場合は、その場で修復しようとしないでください。**Apps > Uninstall Bootstrap…** を選んでから、手順 1 からやり直してください。

### 仮想マシンの作成時にインストールする

```sh
vphone-cli vm create myphone --bootstrap roothide ...
```

`--bootstrap roothide` は、新しいマシンの初回起動中に手順 1 と 2 を行います。Irisin をインストールし、Irisin が推奨するリポジトリから `irisin-cli` を通じて `owngoal-bootstrap-vphone` を Bootstrap Install でインストールします。手順 2 には、`irisin-cli install` が `--repository` と `--bootstrap-install` に対応している Irisin が必要です。

## 削除

**Apps > Uninstall Bootstrap…** を選びます。削除後、仮想マシンは再起動します。

Irisin はデータ（ダウンロード、ジャーナル、設定）を自身のホーム内の `Documents/wiki.qaq.irisin` に保存します。

| レイアウト | Irisin のホーム | 削除後 |
| --- | --- | --- |
| roothide | 環境自身の `/var/mobile` | データもほかのものと一緒に削除されます。 |
| rootless | システムの `/var/mobile` | データは残ります。 |

## その他のオプション

Option キーを押しながら **Apps** メニューを開くと、さらに 2 つの項目が表示されます。

- **Install Bootstrap from File…：** ローカルの Irisin `.deb` からインストールします。
- **Uninstall Bootstrap Without Restarting…：** 仮想マシンを再起動せずに環境を削除します。

同じ操作は自動化 API（`bootstrap.install`、`bootstrap.status`）からも行えます。[API リファレンス](../../../Research/vphoned_http_api.md)をご覧ください。

## 関連項目

- [仮想マシンの作成と実行](create-and-run.md)
- [自動化 API](automation-api.md)
- [トラブルシューティング](../help/troubleshooting.md)
