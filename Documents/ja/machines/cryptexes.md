# Cryptex

Cryptex は、ゲストが実行中にマウントする署名済みディスクイメージで、中のプログラム用のトラストキャッシュを伴います。`minimal` ゲストを再度復元することなく、独自のプログラムを実行するために使います。

## 始める前に

- `minimal` プリセットでマシンを作成し、新規マシンの「パッチ」ページで **Trusted darwinOS environment** のボックスをオンにします。`vphone-launchpad-cli` では `--preset minimal --allow filesystem-exp-trusted_darwinos` です。このボックスは復元時にのみ有効になります。既存のマシンでオンにするには、マシンを作成し直す必要があります。
- macOS Security Research ツール（PCC Virtual Research Environment）をインストールします。VM ウインドウは、その `/System/Library/SecurityResearch/usr/bin/cryptexctl.research` で cryptex をビルドします。
- ゲストにはネットワークが必要です。cryptex をインストールするときに、Apple の署名サーバにこのゲスト用のパーソナライズを依頼します。

この環境では、ゲストは Restricted Execution Mode を適用し、研究ボード用 cloudOS（26.5〜26.7）上のゲストはデベロッパモードをオンにできません。

## cryptex をインストールする

1. cryptex に含めるファイルを、cryptex 内での配置どおりにフォルダに入れます。例：

   ```
   mycryptex/
     usr/bin/server
     Library/LaunchDaemons/server.plist
   ```

   各プログラムに、必要なエンタイトルメントを付けてアドホック署名します（`codesign -s - --entitlements entitlements.plist usr/bin/server`）。
2. VM ウインドウで **Apps › Install Cryptex…** を選択し、そのフォルダを選びます。

VM ウインドウがこのゲスト用に cryptex をビルドしてアップロードし、ゲストがそれをパーソナライズしてインストールします。フォルダ名（拡張子を除く）が cryptex の識別子になります。cryptex は `/private/var/DarwinDataCenterSupportImage/<identifier>` にマウントされます。上の例のフォルダ `mycryptex` なら、`usr/bin/server` はゲスト内では `/private/var/DarwinDataCenterSupportImage/mycryptex/usr/bin/server` です。インストール後のアラートにそのパスが表示されます。cryptex の `Library/LaunchDaemons` にある起動デーモンは、cryptex から起動されます。

**Apps › List Cryptexes** で、インストール済みの cryptex とそれぞれのマウントポイントを確認できます。

複数の cryptex を同時にインストールでき、それぞれに専用のパスが割り当てられます。フォルダ名がすでに cryptex としてインストールされている場合は拒否されます。まずその cryptex を `cryptex.uninstall` でアンインストールするか（後述）、フォルダ名を変更してください。

## `.cxbd` ではなくフォルダを選ぶ

Install Cryptex… は `.cxbd` もそのままインストールしますが、このゲスト用に作成されたものに限ります。つまり、`cryptexctl.research create` が `--BORD=0x90 --CHIP=0xfe01` で作成する、vresearch101 ボード用の Cryptex1 cryptex です。それ以外の場合はフォルダを選んでください。

Security Research Device の iPhone 用にビルドされた cryptex はインストールできません。SRD のサンプルやその Makefile が使う `cryptexctl create --research` は、この種類を作成します。Install Cryptex… はそのことを示し、アップロードの前に中止します。代わりに、それをビルドしたフォルダを選んでください。Makefile の場合は、多くは `build/<identifier>.root`、つまり内容がディスクイメージに入れられたフォルダです。

## スクリプトから

vphoned は [自動化 API](automation-api.md) で `cryptex.list`、`cryptex.install`、`cryptex.uninstall` を提供します。`cryptex.install` は、`/var/mobile/Documents/vphone-cryptexes` の下にアップロード済みの `.cxbd` と、その作成時の variant を受け取ります。

実装については [`Research/Firmware/trusted_darwinos_cryptexes.md`](../../../Research/Firmware/trusted_darwinos_cryptexes.md) を参照してください。
