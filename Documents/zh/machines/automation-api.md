# 自动化 API

通过 HTTP 和 WebSocket 用脚本控制运行中的虚拟机。本页介绍如何开启 API、完成认证并发出第一批请求；[完整 API 参考](../../../Research/vphoned_http_api.md)列出了所有路由和方法。

## 开启 API

启动虚拟机时加上 `--api-listen`：

```sh
vphone-cli vm launch myphone --api-listen 127.0.0.1:8765
```

虚拟机启动后，`vphone-vm` 会打印地址和 token：

```text
[api] HTTP/WebSocket API: http://127.0.0.1:8765
[api] token: 3f9c…
[api] send it as: Authorization: Bearer 3f9c…
```

- 不加 `--api-listen` 时，宿主机上不会有监听器。
- 端口设为 `0` 时由 macOS 分配一个空闲端口；实际地址会在虚拟机启动后打印出来。
- `--api-listen` 不能与 `--dfu` 一起使用。

> [!WARNING]
> vphoned 以 root 身份运行，API 可以读写客户机中的任何文件、列出钥匙串内容并载入启动守护进程。仅在本机使用时，请监听 `127.0.0.1` 或 `[::1]`。监听其他地址时会打印警告：任何能访问该地址的机器只需要 token 即可控制虚拟机，而 token 在普通 HTTP 上以明文传输，因此只应在可信网络中使用。

## Token

每次启动都会生成新的 token：32 个随机字节，以十六进制表示。要使用固定的 token，请在启动前设置 `VPHONE_API_TOKEN`；`vphone-cli vm launch` 会把自己的环境变量传给 `vphone-vm`。该值必须是 16 到 256 个 `A-Z a-z 0-9 - . _ ~` 中的字符；其他非空值都会导致启动中止。

token 可以用以下任意一种方式发送：

| 方式 | 适用于 |
| --- | --- |
| `Authorization: Bearer <token>` 请求头 | HTTP，以及可以设置请求头的 WebSocket 客户端 |
| `token=<token>` 查询参数 | WebSocket URL，例如 `ws://127.0.0.1:8765/v1/events?token=<token>` |
| `Sec-WebSocket-Protocol: vphone-token.<token>` | 只能设置子协议的 WebSocket 客户端 |

缺少 token 或 token 错误时返回 `401 Unauthorized`，连接会在任何内容到达客户机之前关闭。

## 请求示例

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

自行编写客户端时容易出错的规则：

- 每个 `POST` 都必须发送 `Content-Type: application/json`，否则返回 `415`。
- 带有 `Origin` 请求头的请求，或者 `Host` 不是 `vphoned`、`localhost`、`127.0.0.1` 或 `::1` 的请求，会返回 `403`。这样可以阻止网页访问 API。
- `GET` 路由只读取。要更改设置，请使用 `PUT` 或 `POST`，例如对 `PUT /v1/low-power-mode` 发送 `{"enabled": true}`。

Swift App 可以使用 `VPhoneExternalAccessKit` 库中的 `VPhoneAPIClient`，它会自动发送 token；示例见 API 参考。

## 不使用网络监听器

虚拟机的控制套接字无需 API 监听器也能接受同样的方法：以一行 JSON 发送 `{"t":"rpc","method":"<method>","params":{}}`。见[控制套接字](create-and-run.md)。

## 另请参阅

- [完整 API 参考](../../../Research/vphoned_http_api.md)
- [创建与运行虚拟机](create-and-run.md)
- [端口转发](../networking/port-forwarding.md)
- [Launchpad 命令行](../launchpad/launchpad-cli.md)
