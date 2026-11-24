# カスタム CA 証明書

`vm ca` コマンドは、実行中のゲストの TrustStore で、信頼されたルート CA 証明書のインストール、一覧表示、削除を行います。システムに同梱されていない証明書、たとえば HTTPS 通信を傍受するプロキシのルート証明書をゲストに信頼させたいときに使います。

3 つのコマンドはいずれも実行中の仮想マシンと通信するため、まず `vm launch` でマシンを起動してください。仮想マシン名は、以下の例のように明示的に指定します。必須の引数が先、仮想マシン名が後です。名前を省略すると、ライブラリ内のすべての仮想マシンを（実行中かどうか、また 1 台しかない場合でも）一覧表示する対話式の選択画面が表示され、選ぶよう求められます。端末がない環境（スクリプトや CI）では、コマンドは `No VM name given, and this is not an interactive terminal` というエラーで失敗するため、自動化では必ず名前を指定してください。

## インストール

```sh
vphone-cli vm ca install <pem-file> <vm-name> [--admin] [--json]
```

単一の証明書を含む PEM ファイル（最大 64 KiB）を、信頼されたルート CA としてゲストにインストールします。次の 1 行を出力します。

```text
sha256<TAB>subject
```

| オプション | 意味 |
| --- | --- |
| `--admin` | 標準のユーザードメインではなく、管理者（admin）トラストドメインにインストールします。 |
| `--json` | 1 行の出力の代わりに、キーをソートして整形した JSON で `{sha256, subject, domain}` を出力します。 |

## 一覧表示

```sh
vphone-cli vm ca list <vm-name>
```

インストール済みのアンカーを、1 行につき 1 件、`sha256<TAB>subject` の形式で、sha256 順に並べて一覧表示します。

## 削除

```sh
vphone-cli vm ca remove <sha256> <vm-name>
```

`list` で表示される 64 桁の 16 進数 sha256 を指定して、そのアンカーを削除します。

## 例

HTTPS 通信を傍受するプロキシのルート証明書をゲストに信頼させ、反映を確認し、作業が終わったら削除します。

```sh
vphone-cli vm ca install proxy-ca.pem my-vm
vphone-cli vm ca list my-vm
vphone-cli vm ca remove 9f2b8c1d4e6a0f3b5c7d9e1a2b4c6d8e0f1a2b3c4d5e6f708192a3b4c5d6e7f8 my-vm
```

## 関連項目

- [ネットワーク](overview.md)
- [トンネルモード](tunnel.md)
