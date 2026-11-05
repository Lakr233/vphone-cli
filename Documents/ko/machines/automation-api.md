# 자동화 API

실행 중인 가상 머신을 스크립트에서 HTTP와 WebSocket으로 제어합니다. 이 페이지에서는 API를 켜고, 인증하고, 첫 호출을 보내는 방법을 설명합니다. 모든 경로와 메서드는 [전체 API 레퍼런스](../../../Research/vphoned_http_api.md)에 있습니다.

## 켜기

가상 머신을 시작할 때 `--api-listen`을 추가합니다.

```sh
vphone-cli vm launch myphone --api-listen 127.0.0.1:8765
```

가상 머신이 시작되면 `vphone-vm`이 주소와 token을 출력합니다.

```text
[api] HTTP/WebSocket API: http://127.0.0.1:8765
[api] token: 3f9c…
[api] send it as: Authorization: Bearer 3f9c…
```

- `--api-listen`이 없으면 호스트에서 수신하는 리스너가 없습니다.
- 포트를 `0`으로 지정하면 macOS가 비어 있는 포트를 할당하며, 실제 주소는 가상 머신이 시작된 뒤 출력됩니다.
- `--api-listen`은 `--dfu`와 함께 사용할 수 없습니다.

> [!WARNING]
> vphoned는 root로 실행되며, API로 게스트의 모든 파일을 읽고 쓰고, 키체인을 나열하고, launch daemon을 로드할 수 있습니다. 로컬에서만 사용하려면 `127.0.0.1` 또는 `[::1]`에서 수신하세요. 그 밖의 주소를 지정하면 경고가 출력됩니다. 그 주소에 접근할 수 있는 모든 컴퓨터는 token만 있으면 되고, token은 일반 HTTP로 평문 전송되므로 신뢰할 수 있는 네트워크에서만 사용하세요.

## token

token은 시작할 때마다 새로 만들어지며, 32바이트 난수를 16진수로 표현한 값입니다. 고정된 token을 사용하려면 시작하기 전에 `VPHONE_API_TOKEN`을 설정하세요. `vphone-cli vm launch`는 자신의 환경 변수를 `vphone-vm`에 그대로 넘깁니다. 값은 `A-Z a-z 0-9 - . _ ~`로 이루어진 16~256자여야 하며, 비어 있지 않은 다른 값이면 시작이 중단됩니다.

token은 다음 중 어느 형식으로든 보낼 수 있습니다.

| 형식 | 용도 |
| --- | --- |
| `Authorization: Bearer <token>` 헤더 | HTTP, 그리고 헤더를 설정할 수 있는 WebSocket 클라이언트 |
| `token=<token>` 쿼리 항목 | `ws://127.0.0.1:8765/v1/events?token=<token>` 같은 WebSocket URL |
| `Sec-WebSocket-Protocol: vphone-token.<token>` | 서브프로토콜만 설정할 수 있는 WebSocket 클라이언트 |

token이 없거나 틀리면 `401 Unauthorized`가 반환되고, 게스트에 아무것도 전달되기 전에 연결이 닫힙니다.

## 호출 예시

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

클라이언트를 직접 작성할 때 걸리기 쉬운 규칙은 다음과 같습니다.

- 모든 `POST`는 `Content-Type: application/json`을 보내야 하며, 그렇지 않으면 `415`가 반환됩니다.
- `Origin` 헤더가 있는 요청, 또는 `Host`가 `vphoned`, `localhost`, `127.0.0.1`, `::1`이 아닌 요청에는 `403`이 반환됩니다. 이렇게 웹 페이지가 API에 접근하지 못하도록 막습니다.
- `GET` 경로는 읽기만 합니다. 설정을 변경하려면 `PUT`이나 `POST`를 사용하세요. 예를 들어 `PUT /v1/low-power-mode`에 `{"enabled": true}`를 보냅니다.

Swift 앱에서는 `VPhoneExternalAccessKit` 라이브러리의 `VPhoneAPIClient`를 사용할 수 있으며, token은 이 클라이언트가 알아서 보냅니다. 예시는 레퍼런스를 참고하세요.

## 네트워크 리스너 없이 사용하기

가상 머신의 제어 소켓은 API 리스너 없이도 같은 메서드를 받습니다. `{"t":"rpc","method":"<method>","params":{}}`를 JSON 한 줄로 보내세요. [가상 머신 생성 및 실행](create-and-run.md)의 '제어 소켓' 절을 참고하세요.

## 함께 보기

- [전체 API 레퍼런스](../../../Research/vphoned_http_api.md)
- [가상 머신 생성 및 실행](create-and-run.md)
- [포트 포워딩](../networking/port-forwarding.md)
- [Launchpad 명령줄](../launchpad/launchpad-cli.md)
