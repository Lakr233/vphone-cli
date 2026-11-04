# MAC 및 IP 주소

이 페이지에서는 게스트에 저장된 MAC 주소, 이전 MAC이 아직 차지하고 있는 DHCP 임대의 해제, 게스트에 고정 IPv4 주소를 지정하는 방법을 다룹니다.

## MAC 주소

처음 시작할 때 게스트의 네트워크 카드에 무작위로 생성한 로컬 관리 MAC 주소를 부여하고, 머신 식별자와 마찬가지로 `config.plist`에 저장합니다. 그러면 게스트는 시작할 때마다 같은 식별 정보와 같은 DHCP 임대를 유지합니다.

설정하거나 교체하려면 다음을 실행합니다.

```sh
vphone-cli vm config <name> --mac 02:11:22:33:44:55
vphone-cli vm config <name> --mac random   # a new one now
vphone-cli vm config <name> --mac auto     # a new one at the next launch
```

복제한 머신은 머신 식별자처럼 원본의 MAC을 유지합니다. 둘을 동시에 실행하려면 사본에 새 식별 정보와 MAC을 부여하는 `vm clone --new-identity`로 복제하거나, 사본에 새 MAC을 지정하세요. `--new-identity`는 사본의 고정 주소, 포트 포워딩, mDNS 이름도 지웁니다.

## 이전 MAC이 차지하고 있는 주소

증상: `nat` 모드에서 새 게스트가 점점 더 높은 주소를 받다가, 결국 범위의 높은 쪽에 지정해 둔 고정 주소에까지 이릅니다.

공유 네트워크의 임대와 각 임대의 소유자를 나열한 뒤, 고아 임대를 해제합니다(`VPhone.bundle` 2.5 이상 필요).

```sh
vphone-cli vm leases
sudo vphone-cli vm leases --release-orphans
```

Launchpad를 통해서는 다음과 같습니다.

```sh
vphone-launchpad-cli vm leases
vphone-launchpad-cli vm leases --release
```

Launchpad 창에서는 Host Setup의 NAT Network 아래에 개수가 표시되며, Release…를 누르고 관리자가 승인하면 해제됩니다. Launchpad는 자신이 나열하는 모든 보관함을 기준으로 비교합니다.

고아 임대란 MAC이 보관함의 어느 머신에도 속하지 않고 임대 기간이 끝난 iOS 또는 iPadOS 게스트의 임대입니다. `--release-orphans`는 `/var/db/dhcpd_leases`에서 고아 임대를 제거하고 DHCP 서버가 파일을 다시 읽게 하므로 root 권한이 필요합니다. 다음은 절대 건드리지 않습니다.

- 머신 자신의 임대. 머신이 중지된 동안 기간이 끝난 임대도 포함합니다.
- 기간이 끝나지 않은 임대. 예를 들어 MAC을 방금 교체한 실행 중인 게스트의 임대입니다.
- 다른 가상 머신 앱의 임대, 또는 인터넷 공유에 연결된 기기의 임대.

다른 보관함의 머신은 그 보관함도 지정했을 때만 계산됩니다. 보관함마다 `--library-root`를 반복하세요. 보관함에 머신이 없거나 머신의 설정을 읽을 수 없으면, 그곳의 모든 임대가 고아로 보이게 되므로 해제를 거부합니다.

원인: Mac의 DHCP 서버는 임대 기간이 끝난 뒤에도 각 주소를 그 주소를 받은 MAC에 묶어 두며, 범위의 다른 모든 주소가 사용된 뒤에야 그 주소를 다른 기기에 넘깁니다. 머신을 삭제하거나 MAC을 교체하면 그 주소는 더 이상 아무도 쓰지 않는 MAC에 묶인 채 남으며, MAC이 저장되기 전에 이루어진 모든 시작도 마찬가지입니다.

## 고정 주소

`--ip`는 게스트에 고정 IPv4 주소를 지정합니다. 접두사 길이를 생략하면 `/24`로 간주합니다. `--gateway`와 `--dns`는 선택 사항이며, `auto`를 지정하면 기본값으로 돌아갑니다. `--ip dhcp`는 고정 주소를 제거합니다.

```sh
vphone-cli vm config <name> --ip 192.168.65.50
vphone-cli vm config <name> --network tunnel --ip 10.20.0.5/16 --dns 1.1.1.1
vphone-cli vm config <name> --ip dhcp
```

주소가 게스트에 적용되는 방식은 모드에 따라 다릅니다.

| 모드 | 주소 | 적용 방식 |
| --- | --- | --- |
| `nat` | Mac의 공유 NAT 네트워크: 일반적으로 `192.168.65.0/24`, `--nat-peers off`인 머신은 `192.168.64.0/24`([머신 간 연결](peers.md) 참고) | vphoned가 게스트의 네트워크 설정에 기록합니다. 게이트웨이와 DNS는 Mac(`192.168.65.1` 또는 `192.168.64.1`)입니다. |
| `tunnel` | 모든 사설 서브넷 | 터널 자체의 DHCP가 할당합니다. `--gateway`로 다른 주소를 지정하지 않으면 게이트웨이(DNS 확인자 역할도 함)는 서브넷의 첫 번째 주소입니다. |
| `bridged` | 물리 네트워크의 주소 | vphoned가 게스트에 기록합니다. `--gateway`와 `--dns`는 해당 네트워크의 값으로 설정하세요. |

> [!TIP]
> 공유 `nat` 네트워크의 주소는 Mac의 DHCP 서버에 예약되지 않습니다. DHCP가 다른 가상 머신에 할당했을 가능성이 낮은 범위의 높은 쪽 주소(예: `.200`)를 고르세요.

`nat` 모드에서는 머신이 참여하는 공유 네트워크의 주소여야 합니다. 서로 연결되는 머신(기본값)은 두 번째 네트워크(`192.168.65.0/24`), `--nat-peers off`인 머신은 첫 번째 네트워크(`192.168.64.0/24`)입니다. vmnet의 `Shared_Net_Address`가 옮겨졌다면 둘 다 이를 따릅니다. 그 밖의 서브넷에는 `tunnel`을 사용하세요.

vphoned는 `vphone-vm`이 연결할 때마다 주소를 적용하므로, Mac이 모르는 사이에 게스트에서 바뀐 설정은 되돌려집니다. vphoned는 자신이 한 설정만 되돌립니다. 게스트의 설정 앱에서 직접 입력한 주소는 가상 머신이 DHCP로 돌아갈 때 건드리지 않습니다.

macOS 26은 가상 머신에 전용 NAT 네트워크를 제공할 수 있지만, 그 서브넷은 가상 머신이 중지된 뒤에도 예약된 채로 남고(테스트에서 40분 뒤에도 예약 상태), 그동안 그 네트워크에서의 모든 시작이 실패하므로 vphone은 이를 사용하지 않습니다.

## 함께 보기

- [네트워크](overview.md)
- [포트 포워딩](port-forwarding.md)
- [머신 간 연결](peers.md)
