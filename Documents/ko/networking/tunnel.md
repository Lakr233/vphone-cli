# 터널 모드

Mac의 트래픽이 VPN이나 프록시 앱을 거치고 게스트의 트래픽도 같은 경로를 따라야 할 때 `tunnel` 모드를 사용하세요. `nat`와 `bridged`에서는 게스트의 패킷이 VPN을 우회합니다.

## 켜기

머신을 중지한 뒤 다음을 실행합니다.

```sh
vphone-cli vm config <name> --network tunnel
```

Launchpad에서는 머신의 Settings…에 있는 Network 섹션에서 `tunnel`을 선택합니다. 번들의 `vphone-cli vm config --help`에 `tunnel`이 나열되어야 하며, 이전 번들은 이를 거부합니다.

## 동작 확인하기

1. 머신을 시작하고 부팅이 끝날 때까지 기다립니다.
2. 게스트의 주소를 확인합니다.

   ```sh
   vphone-launchpad-cli guest rpc <name> device.network
   ```

   `en0`에 `192.168.127.3`이 표시되어야 합니다. `fe80::` 주소만 표시되면 DHCP가 아직 끝나지 않은 것입니다. 몇 초 기다린 뒤 다시 시도하세요.
3. 게스트에서 페이지를 엽니다.

   ```sh
   vphone-launchpad-cli guest rpc <name> apps.open_url '{"url":"https://example.com"}'
   ```

4. Mac에서 연결이 `vphone-vm`에 속하고 VPN의 주소를 사용하는지 확인합니다.

   ```sh
   lsof -nP -a -i -p "$(pgrep -f 'vphone-vm.*<name>')"
   ```

## 게스트에서 보이는 것

| 항목 | 값 |
| --- | --- |
| 게스트 주소 | DHCP로 받는 `192.168.127.3/24`, 또는 [고정 주소](addresses.md) |
| 게이트웨이와 DNS | `192.168.127.1`, 또는 고정 주소 서브넷의 첫 번째 주소 |
| MTU | 1500 |
| DNS | `192.168.127.1`로 보낸 질의는 Mac의 확인자로 전달됩니다 |
| 게이트웨이로의 다른 연결 | Mac의 루프백 `127.0.0.1`(TCP 및 UDP) |

프록시 앱에서 게스트는 머신 이름을 딴 별도의 클라이언트로 표시되며, 앱의 규칙은 다른 앱과 마찬가지로 게스트에도 적용됩니다.

## 게스트 TCP를 SOCKS5 프록시로 가로채기

`tunnel` 모드에서는 게스트의 TCP를 SOCKS5 프록시로 보낼 수도 있어, Mac의 도구로 게스트의 연결을 관찰하거나 필터링할 수 있습니다. 머신을 정지한 다음 실행하세요.

```sh
vphone-cli vm config <name> --intercept socks5://host:1080
```

이 설정은 `tunnel` 모드에서만 적용되며 다음 시작 시 반영됩니다. 게스트의 각 TCP 연결은 원래 목적지에 대한 SOCKS5 CONNECT로 프록시를 통해 열립니다. 게이트웨이로 향하는 트래픽은 여전히 Mac의 루프백(`127.0.0.1`)으로 직접 연결되며 프록시를 거치지 않습니다.

QUIC는 프록시가 전달하지 않는 UDP 위에서 동작하므로 QUIC 앱은 프록시를 우회합니다. `--intercept-block-quic`를 추가하면 게스트의 443 포트 UDP를 버려, 그런 앱이 프록시가 전달할 수 있는 TCP로 폴백하게 만듭니다.

```sh
vphone-cli vm config <name> --intercept socks5://host:1080 --intercept-block-quic
```

`vphone-cli vm info <name>`는 활성 프록시(비밀번호는 가려집니다)와 QUIC 차단 여부를 보여 줍니다.

### 자격 증명

사용자 이름과 비밀번호가 필요한 프록시는 이를 URL로 받습니다. 비밀번호를 명령줄에 그대로 넣지 마세요. `ps`에 보이고 셸 기록에 남으며, 디스크의 VM 매니페스트에도 평문으로 저장됩니다. 대신 `vphone-cli`가 VM을 시작할 때마다 해석하는, 작은따옴표로 감싼 `${env:NAME}` 토큰으로 환경에서 읽으세요.

```sh
vphone-cli vm config <name> --intercept 'socks5://user:${env:PROXY_PASS}@host:1080'
```

`vm config`는 토큰만 저장합니다. 변수는 VM을 시작하는 프로세스의 환경에서 읽히므로 `vm config`가 아니라 `vm launch`에 설정하세요. 비밀번호를 직접 입력하면 셸 기록에 남으므로 키체인에서 가져옵니다.

```sh
PROXY_PASS="$(security find-generic-password -s <item> -w)" vphone-cli vm launch <name>
```

작은따옴표는 셸이 토큰을 확장하지 못하게 하므로 비밀번호가 명령줄에도 매니페스트에도 남지 않습니다.

Launchpad에서 시작한 VM은 Launchpad의 환경을 받으며, 여기에는 이 변수가 없습니다. 그러면 토큰이 정의되지 않아 가로채기가 fail-closed로 동작하고, 변수가 있는 프로세스에서 VM을 다시 시작할 때까지 게스트 TCP가 리셋됩니다.

## 제한 사항

- **IPv4만 지원합니다.** 게스트는 IPv6 주소를 받지 않으며, IPv6 트래픽은 버려집니다.
- **포워딩된 포트를 제외하면 아웃바운드만 가능합니다.** [포트 포워딩](port-forwarding.md)에 나열된 포트 외에는 Mac이나 LAN의 어떤 것도 이 네트워크로 게스트에 접근할 수 없습니다. USB 접근(`iproxy`, `ideviceinstaller`)과 `vphone.sock`은 게스트 네트워크를 사용하지 않으므로 계속 동작합니다. `.local` 이름도 USB 링크로 게스트에 도달합니다. [네트워크상의 이름](names.md)을 참고하세요.
- **ping은 게이트웨이까지만 도달합니다.** 인터넷으로의 ICMP는 전달되지 않으므로, TCP와 UDP가 동작하더라도 게스트에서 `ping 1.1.1.1`은 실패합니다.
- **처리량은 `vphone-vm`에 의해 제한됩니다.** 모든 패킷이 그 프로세스에서 처리됩니다. 다운로드와 동영상은 동작하지만, VPN이 없다면 `nat`가 더 빠릅니다.

## 동작 원리

VPN이 Mac의 기본 경로를 차지하고 있으면(WireGuard, Cloudflare WARP, 또는 Surge나 Clash처럼 TUN 모드로 동작하는 프록시 앱), `nat`와 `bridged`가 물리 인터페이스로 내보내는 패킷은 VPN을 건너뜁니다. 그 패킷은 암호화되지 않은 채 나가거나 아예 나가지 못합니다.

`tunnel` 모드에서는 게스트의 네트워크 카드가 `vphone-vm` 안에 구현됩니다. 게이트웨이에 대한 DHCP, ARP, ping에 응답하고, 게스트의 각 TCP 연결과 UDP 흐름을 Mac의 일반 소켓으로 바꿉니다. 이 소켓은 다른 앱과 마찬가지로 Mac의 라우팅 테이블을 따르므로 VPN이 이를 전달합니다. root 권한, 새 네트워크 인터페이스, Mac의 네트워크 설정 변경이 모두 필요하지 않습니다.

## 함께 보기

- [네트워크](overview.md)
- [MAC 및 IP 주소](addresses.md)
- [포트 포워딩](port-forwarding.md)
