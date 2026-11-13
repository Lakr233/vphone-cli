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

26.4 ベータより後の cloudOS には vphone600 のコンポーネントがないため、研究用ボードが代わりを務めます（[互換性](compatibility.md)の「どの cloudOS を使うか」をご覧ください）。その kernelcache は、vphone600 の仮想化 kext を加えて作り直されます。すべてあなたのユーザ権限で実行され、sudo は不要です。

1. 通常どおり `fw prepare` を実行します。
2. ミックスを作成します。

   ```sh
   vphone-cli fw kernelcache myphone
   ```

3. `fw patch` に進みます。`fw patch` はキャッシュからミックスを取得します。あなたのユーザ権限で実行した場合は、`fw patch` 自身がミックスを作成することもできます。root で実行した場合はキャッシュから取得するだけです。

`fw kernelcache` の古い `--ipsw` 引数は引き続き受け付けられますが、無視されます。

## ミックスをリンクする kmutil

カーネルは Apple がリンクしたレイアウトでしか起動せず、そのレイアウトはリンクする kmutil で決まります。macOS 15 と 26.0〜26.3 はカーネルを先頭に、macOS 26.4 以降は末尾に置き、macOS 27 はさらに kext の auth stub を残します。どの kernelcache にも Apple がビルドに使った kmutil のバージョンが記録されているため、`fw kernelcache` はどの macOS 上でも同じバージョンでミックスをリンクします。

| kernelcache | kmutil | 入手元 |
| --- | --- | --- |
| iOS 18.1〜18.3.1 | 463.40.2 | macOS 15.1 (24B83) |
| iOS 18.5〜18.7.2 | 463.100.7 | macOS 15.6.1 (24G90) |
| iOS 26.4〜26.7、watchOS 26.4、HomePod 26.5 | 487.100.11 | macOS 26.5 (25F71) |
| iOS 27.2 | 514.40.8 | macOS 27.2.1 (26B131) |

この Mac 自身の kmutil がそのバージョンなら、それを使います。そうでなければ、その macOS の復旧イメージ（約 1 GB）を Apple の IPSW から一度だけダウンロードし、その kmutil とカーネルコレクションビルダーを `~/.vphone/kernelcache/kmutil/<version>`（数 MB）に保存して、イメージは削除します。何もインストールされず、ホストの設定も変わりません。別の Mac で ssh 経由でリンクする `VPHONE_KMUTIL_SSH` は使われなくなりました。

## 関連項目

- [ファームウェアの互換性](compatibility.md)
- [マシンの作成と実行](../machines/create-and-run.md)
- [ライブラリ、ファームウェア、バックアップ](../storage/library-and-backups.md)
- [kernelcache のレシピ](../../../VPhoneExecutable/VPhoneVirtualization/Resources/kernelcache_recipes/README.md)
