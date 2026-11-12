# 自動化 API

実行中の仮想マシンを、HTTP と WebSocket を使ってスクリプトから操作します。このページでは、API の有効化、認証、最初の呼び出しまでを説明します。すべてのルートとメソッドは [API の完全なリファレンス](../../../Research/vphoned_http_api.md)に記載されています。

## 有効にする

仮想マシンの起動時に `--api-listen` を追加します。

```sh
vphone-cli vm launch myphone --api-listen 127.0.0.1:8765
```

仮想マシンが起動すると、`vphone-vm` がアドレスとトークンを表示します。

```text
[api] HTTP/WebSocket API: http://127.0.0.1:8765
[api] token: 3f9c…
[api] send it as: Authorization: Bearer 3f9c…
```

- `--api-listen` を指定しないと、ホスト側でリッスンするものはありません。
- ポート `0` を指定すると、macOS に空いているポートを割り当てさせます。実際のアドレスは仮想マシンの起動後に表示されます。
- `--api-listen` は `--dfu` と併用できません。

> [!WARNING]
> vphoned は root として動作し、API はゲストの任意のファイルの読み書き、キーチェーンの一覧表示、launch daemon の読み込みができます。ローカルだけで使う場合は、`127.0.0.1` または `[::1]` でリッスンしてください。それ以外のアドレスでは警告が表示されます。そのアドレスに到達できるマシンはトークンさえあれば操作でき、トークンは平文の HTTP でそのまま送られるため、信頼できるネットワークでのみ使用してください。

## トークン

トークンは起動のたびに新しく生成されます（32 バイトの乱数を 16 進数で表したもの）。トークンを固定するには、起動前に `VPHONE_API_TOKEN` を設定します。`vphone-cli vm launch` は自身の環境変数を `vphone-vm` に引き継ぎます。値は `A-Z a-z 0-9 - . _ ~` からなる 16〜256 文字である必要があります。それ以外の空でない値を設定すると、起動は中止されます。

トークンは次のどの形式でも送れます。

| 形式 | 用途 |
| --- | --- |
| `Authorization: Bearer <token>` ヘッダ | HTTP、およびヘッダを設定できる WebSocket クライアント |
| `token=<token>` クエリ項目 | `ws://127.0.0.1:8765/v1/events?token=<token>` のような WebSocket の URL |
| `Sec-WebSocket-Protocol: vphone-token.<token>` | サブプロトコルしか設定できない WebSocket クライアント |

トークンがない、または間違っている場合は `401 Unauthorized` が返され、ゲストに何かが届く前に接続が閉じられます。ゲストが応答を 1 バイトも送らずに接続を閉じた場合、プロキシはエラーコード `guest_closed` 付きの `502 Bad Gateway` を返します。すでに送信中の応答が変更されることはありません。

## 呼び出しの例

```sh
TOKEN=...   # from the "[api] token:" line, or the VPHONE_API_TOKEN you set

# Health check
curl -H "Authorization: Bearer $TOKEN" http://127.0.0.1:8765/v1/health

# Call any method through /v1/rpc
curl -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
     -d '{"method":"device.snapshot","params":{}}' http://127.0.0.1:8765/v1/rpc

# Event stream
websocat "ws://127.0.0.1:8765/v1/events?token=$TOKEN"

# Interactive shell in the guest (websocat needs --binary)
websocat --binary "ws://127.0.0.1:8765/v1/shell?token=$TOKEN&cols=120&rows=40"
```

自作のクライアントでつまずきやすい規則：

- すべての `POST` で `Content-Type: application/json` を送る必要があります。送らないと `415` が返されます。
- `Origin` ヘッダのあるリクエスト、または `Host` が `vphoned`、`localhost`、`127.0.0.1`、`::1` 以外のリクエストには `403` が返されます。これにより、ブラウザのページから API にアクセスできないようにしています。
- `GET` のルートは読み取りだけを行います。設定を変更するには `PUT` または `POST` を使います。たとえば `PUT /v1/low-power-mode` に `{"enabled": true}` を送ります。

Swift のアプリでは、`VPhoneExternalAccessKit` ライブラリの `VPhoneAPIClient` を使えます。トークンは自動で送られます。例はリファレンスをご覧ください。

## ネットワークでリッスンせずに使う

仮想マシンの制御ソケットは、API のリスナーがなくても同じメソッドを受け付けます。`{"t":"rpc","method":"<method>","params":{}}` を 1 行の JSON として送ってください。[仮想マシンの作成と実行](create-and-run.md)の「制御ソケット」をご覧ください。

## 関連項目

- [API の完全なリファレンス](../../../Research/vphoned_http_api.md)
- [仮想マシンの作成と実行](create-and-run.md)
- [ポート転送](../networking/port-forwarding.md)
- [Launchpad コマンドライン](../launchpad/launchpad-cli.md)
