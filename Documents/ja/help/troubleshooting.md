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

## Xcode や Instruments でゲストがオフラインと表示される

CoreDevice はゲストを有線デバイスとしてペアリングしますが、そのトンネルを維持するのは、いずれかのプログラムがトンネルを使っている間だけです。トンネルがないと、`xcrun xctrace list devices` ではゲストが「Devices Offline」に表示され、`xctrace record --device <UDID>` はデバイスの起動を待ち、約 30 秒であきらめます。Instruments が接続を提案するのはネットワークデバイスだけで、有線デバイスには提案しません。

ゲストの実行中は `vphone-vm` にトンネルを開いたままにさせます。

- 仮想マシンのウィンドウで **Diagnostics > Keep Developer Tunnel Open** を選びます。すぐに適用され、マシンに保存されます。
- または、ターミナルで次を実行します。

  ```sh
  vphone-cli vm config <name> --developer-tunnel on
  ```

  次回の起動から適用されます。`vm info` ではこの設定が `developer tunnel` として表示されます。

vphoned が応答すると、`vphone-vm` はゲストに対して `/usr/bin/devicectl` を実行し、終了するたびに起動し直します。`/usr/bin/devicectl` のない Mac では、仮想マシンのログに `[developer-tunnel]` の行が 1 行表示され、トンネルは維持されません。

この設定のない bundle では、代わりにターミナルからトンネルを維持できます。`vphone-cli vm info <name>` でゲストの UDID を確認し、次のコマンドを実行したままにします。

```sh
/usr/bin/devicectl device notification observe --device <UDID> \
  --name com.vphone.keepalive --session-timeout 3500 --timeout 3600
```

`--session-timeout` は `--timeout` より小さくする必要があります。コマンドは 1 時間で終了するので、そのときにもう一度実行します。

トンネルがつながってから 1 分ほどの間は、`xctrace record --attach` が `Cannot find process matching name` や `Cannot find process for provided pid` で失敗することがあります。少し待ってからやり直してください。

## 関連項目

- [ホストの設定](../get-started/host-setup.md)
- [作成と実行](../machines/create-and-run.md)
- [ファームウェアの互換性](../firmware/compatibility.md)
