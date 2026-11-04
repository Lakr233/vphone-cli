# トラブルシューティング

表示されている症状やエラーメッセージを探し、その下の対処方法に従ってください。ネットワークの問題については[ネットワーク](../networking/overview.md)をご覧ください。

## 仮想マシンが開く前に `vphone-vm` が強制終了される

1. ホストの事前チェックを実行します。

   ```sh
   vphone-cli host preflight
   ```

   CLI はエンタイトルメントを持たないため強制終了されずに動作を続け、署名された `vphone-vm` を AMFI が拒否した理由を説明できます。
2. バンドルをビルドし直した場合は、cdhash が変わっています。[ホストの設定](../get-started/host-setup.md)の説明に従い、同梱のヘルパーで新しいバイナリを許可してください。

## `Virtualization is not available on this hardware`

PV=3 のゲストは入れ子にできません。別の macOS 仮想マシンの中ではなく、Apple Silicon Mac で直接起動してください。

## `vm create` が vphoned の成功を表示したのに、仮想マシンが実行されていない

これは想定どおりの動作です。作成処理は一時的に GUI で起動し、実際に ping を送って、終了する前にその起動を停止します。使用するには仮想マシンを起動してください。

```sh
vphone-cli vm launch <name>
```

## 「Press home to continue」で止まる

仮想マシンのウィンドウのタイトルバーにあるホームボタンをクリックします。現在の JB の手順では VNC サーバはインストールされません。

## アプリが `EXC_GUARD` / `GUARD_TYPE_MACH_PORT` で終了する

カーネルパッチ `kernel-boot-thread_guard_violation` は、致命的な Mach ポートガードの通知を止めます。このパッチは起動に必要な iOS 18 ベースでのみ適用され、そこではすべてのプリセットでオンになっています。ほかのベースでは選択できないため、26.x ベースでこのガードに引っかかるアプリは引き続き終了します。[issue #291](https://github.com/Lakr233/vphone-cli/issues/291) をご覧ください。

## 復元または初回起動に失敗する

- 手動の手順では、`restore` が終了するまで仮想マシンを DFU のままにしてください。
- オンラインのチケット要求が Apple に届くことを確認してください。
- 処理全体をやり直す場合は、**新しい名前**で、ツールの詳細を表示する `-v` を付けて `vm create` を再実行してください。
- メモリやディスクに余裕がない場合は、仮想マシンを並行して作成しないでください。
- iPhone の IPSW と PCC イメージを組み合わせる前に、[ファームウェアの互換性](../firmware/compatibility.md)を確認してください。

## ゲストは起動するが、作成中に vphoned が応答しない

初回起動のチェックは 300 秒でタイムアウトします。復元したばかりのゲストは、最初のヘッドレス起動で vphoned を立ち上げないことがあるため、作成処理では GUI で起動します。成功の表示が何を示すかについては、[作成と実行](../machines/create-and-run.md)をご覧ください。

## 関連項目

- [ホストの設定](../get-started/host-setup.md)
- [作成と実行](../machines/create-and-run.md)
- [ファームウェアの互換性](../firmware/compatibility.md)
