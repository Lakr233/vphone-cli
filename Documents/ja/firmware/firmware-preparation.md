# ファームウェアの準備

ファームウェアにパッチを適用する前に `vm create` と `fw prepare` が 2 つの IPSW に対して行うこと、そして vphone600 のコンポーネントを含まない cloudOS で必要になる追加の手順を説明します。段階を手動で実行する場合、GPU ドライバを再利用する場合、研究用ボードの組み合わせでマシンを作成する場合にご覧ください。

## GPU ドライバ

`fw prepare` がハイブリッドな iPhone の復元イメージを作るには、cloudOS から準仮想化 GPU ドライバを取得する必要があります。取得は次の手順で行われます。

1. ネットワークデバイスのない一時的な vphone 仮想マシンを作成し、DFU で起動します。
2. vphone 独自の復元バックエンドで、選択した cloudOS の IPSW をその仮想マシンに復元します。
3. 復元した System ボリュームを読み取り専用でマウントし、GPU バンドルを取り出します。
4. 一時的な仮想マシンを削除します。

取り出したバンドルは cloudOS のビルドごとに `~/.vphone/gpu-drivers/` にキャッシュされるため、同じ cloudOS で作成する以降のマシンでは一時的な復元が省かれます。

以前に取り出したバンドルを再利用するには、`vm create` または `fw prepare` に渡します。

```sh
vphone-cli fw prepare myphone \
  --gpu-driver-bundle /path/to/AppleParavirtGPUMetalIOGPUFamily.bundle
```

CLI はバンドルの iPhoneOS プラットフォームのバージョンを、選択した cloudOS のバージョンと照合します。各復元はそれぞれオンラインでチケットを取得します。

バンドルには arm64e の GPU コンパイラプラグインも同梱されています。`fw prepare` は、パッチの適用とインストールの前に、それを準備した GPU バンドルにコピーします。

## 研究用ボードの組み合わせ

26.4 ベータより後の cloudOS には vphone600 のコンポーネントがないため、研究用ボードが代わりを務めます（[互換性](compatibility.md)の「どの cloudOS を使うか」をご覧ください）。その kernelcache は、vphone600 の仮想化 kext を加えて作り直されます。KDK の展開はあなたのユーザ権限でネイティブに実行され、root が必要なのは kmutil によるリンクだけです。

1. 通常どおり `fw prepare` を実行します。
2. 自分のユーザ権限でミックスを準備します。

   ```sh
   vphone-cli fw kernelcache myphone
   ```

3. root としてリンクします。

   ```sh
   sudo vphone-cli fw kernelcache myphone
   ```

4. `fw patch` に進みます。`fw patch` はキャッシュからミックスを取得します。

`fw kernelcache` の古い `--ipsw` 引数は引き続き受け付けられますが、無視されます。

## 別の Mac でリンクする

カーネルは Apple がリンクしたレイアウトでしか起動せず、kmutil はレイアウトを実行中の Mac から決めます。

| ホストの macOS | リンクできるもの |
| --- | --- |
| macOS 26.4 以降 | iOS 26.4 以降の kernelcache（kernel-last） |
| macOS 15、および 26.0〜26.3 | iOS 18 などの古い kernelcache（kernel-first） |

この Mac のレイアウトが異なる場合は、別の Mac または macOS 仮想マシンが ssh 経由でミックスをリンクします。`fw kernelcache` または作成処理のために、次を設定します。

```sh
export VPHONE_KMUTIL_SSH='user@host'
export VPHONE_KMUTIL_SSH_PASSWORD='password'   # only without ssh keys and passwordless sudo there
```

準備したボリュームはその Mac の `/private/var/tmp` にアップロードされ、そこで root としてリンクされた後、削除されます。この Mac では root 権限は必要ありません。別の Mac ではリモートログインがオンになっていて、そのユーザが sudo を使えることが必要です。

## 関連項目

- [ファームウェアの互換性](compatibility.md)
- [マシンの作成と実行](../machines/create-and-run.md)
- [ライブラリ、ファームウェア、バックアップ](../storage/library-and-backups.md)
- [kernelcache のレシピ](../../../VPhoneExecutable/VPhoneVirtualization/Resources/kernelcache_recipes/README.md)
