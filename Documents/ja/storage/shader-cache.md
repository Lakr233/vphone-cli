# 永続シェーダキャッシュ

マシンはコンパイル済みの GPU シェーダを起動をまたいで保持するため、アニメーションがもたつくのは、最初の数回の実行でシェーダをコンパイルしている間だけです。このページでは、既存のマシンでキャッシュを有効にする方法と、キャッシュをリセットする方法を説明します。

Standard プリセットで作成した新しいマシンでは、Task3 カーネルパッチとゲストの Metal キャッシュの再利用が自動的に有効になります。ホストはキャッシュを `<machine>/ShaderCache`（例：`~/.vphone/machines/Lychee/ShaderCache`）に保存します。実行ファイルが変わると、ホストのキャッシュのアイデンティティも新しくなります。

## 既存のマシンで有効にする

この機能を含む Core Bundle をインストールし、停止中のマシンをそのバンドルに紐付けます。その後、ゲスト環境とカーネルを更新します。どちらの更新でもゲストのデータは保持され、復元も `fw patch` も必要ありません。

### Launchpad で

1. マシンのアクションメニューから **Update Guest Environment** を選びます。
2. **Patches** インスペクタで **Update Kernel** を選びます。

Standard では **GPU Task3 shader cache** が自動的に選択されるようになりました。マシンごとに明示的にオフにした設定は保持されます。パッチのチェックを外していた場合は、先にエディタで有効にしてください。

### Launchpad CLI で

```sh
# Replace <version> with the installed Core Bundle version from bundle list.
vphone-launchpad-cli vm stop Lychee
vphone-launchpad-cli vm set-bundle Lychee <version> --update-environment
vphone-launchpad-cli cfw update-kernel Lychee
vphone-launchpad-cli vm start Lychee --wait
```

- `--update-environment` は、ゲストライブラリとキャッシュ再利用のマーカーを配置し直します。
- `cfw update-kernel` は、`FirmwareOriginals` にある未変更のカーネルに現在の選択でパッチを適用し直し、Preboot の kernelcache を置き換えます。

Core Bundle の紐付けを変えるだけでは、インストールされたカーネルは更新されません。

### vphone-cli だけで

マシンの電源を切った状態で、新しいバンドルのコマンドを root 権限で実行します。

```sh
sudo vphone-cli cfw update-environment Lychee
sudo vphone-cli cfw update-kernel Lychee
```

`vphone-cli fw patches Lychee` で保留中のパッチを確認できます。どちらの更新コマンドも、ほかに保留中のゲストやカーネルの変更も含め、マシンの現在の選択を適用します。

### 未変更のカーネルがない古いマシン

`FirmwareOriginals` に未変更のカーネルがないマシンでは、先に新しいバンドルで `fw prepare` と `fw patch` を実行し、代わりに使われる復元ツリーに更新後のカーネルが含まれるようにします。その後 `cfw update-kernel` を実行します。`restore` は実行しないでください。

## ホストのキャッシュをリセットする

マシンを停止してから、その `ShaderCache` ディレクトリを削除します。次回の起動で、新しいホストキャッシュが作られます。

ゲストの Metal キャッシュは `Disk.img` 内の別のファイルなので、ホストのキャッシュを消去しても、初回実行時のもたつきがすべて再現されるとは限りません。

## 制限

- Task3 は cloudOS 26.4 のカーネルにのみ適用され、tvOS のプリセットでは無効です。
- macOS 27 より前のホストでは、ゲストはホスト自身の最大バージョンでネゴシエーションし、そのバージョンの機能を使うため、ホストのキャッシュは起動ごとのものになります。
- 実行時の検証は、macOS 27.0.1、cloudOS 26.4、iOS 27.0.1 と 26.6.2 のゲストで行いました。古いホストはフレームワークのコードから確認したもので、実際には実行していません。

## 関連項目

- [Core Bundle](../launchpad/core-bundles.md)
- [Launchpad CLI](../launchpad/launchpad-cli.md)
- [ライブラリ、ファームウェア、バックアップ](library-and-backups.md)
