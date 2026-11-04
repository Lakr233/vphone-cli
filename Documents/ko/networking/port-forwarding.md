# 포트 포워딩

`nat`와 `tunnel` 모드에서 `--forward`를 사용하면 Mac의 포트를 게스트로 전달할 수 있습니다. `bridged`는 게스트를 자체 주소로 LAN에 연결하므로 포워딩이 필요하지 않습니다.

## 포워딩 추가 및 제거

```sh
vphone-cli vm config <name> --forward tcp:8022:22
vphone-cli vm config <name> --forward udp:0.0.0.0:5353:53
vphone-cli vm config <name> --remove-forward 8022
vphone-cli vm config <name> --clear-forwards
```

형식은 다음과 같습니다.

```text
[tcp|udp:][host-address:]host-port:guest-port
```

| 부분 | 의미 |
| --- | --- |
| `tcp` 또는 `udp` | 프로토콜 |
| `host-address` | Mac에서 포워딩이 수신하는 주소. 기본값은 `127.0.0.1`이며, `0.0.0.0`으로 지정하면 LAN의 다른 기기에서도 접근할 수 있습니다. |
| `host-port` | Mac의 포트 |
| `guest-port` | 게스트의 포트 |

포트를 더 추가하려면 `--forward`를 반복합니다. Launchpad에서는 머신의 Settings…에 Port Forwarding 섹션이 있습니다.

## 포워딩 동작 방식

- `vphone-vm`은 가상 머신이 시작될 때 리스너를 열고 중지될 때 닫습니다.
- `nat` 모드에서는 게스트의 주소, 즉 [고정 주소](addresses.md)나 vphoned가 보고하는 주소로 연결합니다.
- `tunnel` 모드에서는 연결이 게이트웨이에서 온 것처럼 게스트에 도달합니다.
- Mac에서 이미 사용 중인 포트는 가상 머신의 로그에 보고되고 건너뜁니다. 다른 포워딩은 계속 동작합니다.

## 함께 보기

- [네트워크](overview.md)
- [터널 모드](tunnel.md)
- [MAC 및 IP 주소](addresses.md)
