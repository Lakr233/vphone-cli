# 보관함, 펌웨어, 백업

vphone이 머신과 내려받은 펌웨어를 보관하는 위치, 그 위치를 옮기는 방법, 그리고 머신을 복사하고 백업하고 복원하는 방법을 설명합니다. 디스크 공간을 계획하거나, 보관함을 옮기거나, 머신의 사본이 하나 더 필요할 때 읽으세요.

## 백업, 복사, 복원

```sh
vphone-cli vm list
vphone-cli vm info myphone
vphone-cli vm clone myphone copy                    # backup: same identity
vphone-cli vm clone myphone second --new-identity   # a second device
vphone-cli vm export myphone --out myphone.tzst
vphone-cli vm import myphone.tzst --name restored
```

`vm clone`은 중지된 머신을 복사하며, 가능하면 APFS의 쓰기 시 복사(copy-on-write)를 사용합니다. 원본이 실행 중이면 거부합니다.

| 복제 | 식별 정보 | 용도 |
| --- | --- | --- |
| 일반 `vm clone` | 같은 머신 식별자와 MAC 주소 | 백업. 원본과 동시에 실행할 수 없습니다. |
| `vm clone --new-identity` | 새 머신 식별자(ECID)와 그에 따른 새 UDID, 첫 시작 시 새 MAC 주소 | 원본과 동시에 실행하는 두 번째 기기 |

`--new-identity` 사본은 다음과 같습니다.

- 원본과 충돌하므로 고정 IPv4 주소, 포트 포워딩, 직접 지정한 mDNS 이름을 지웁니다. `--mdns on`이 원본의 이름에서 만든 mDNS 이름은 이름을 바꿀 때처럼 새 이름을 따릅니다. 필요하면 `vm config`로 새로 설정하세요.
- 원본의 데이터, 앱, 설정을 그대로 유지하며 복원이 필요하지 않습니다.
- `ideviceinstaller` 같은 lockdown 도구가 동작하려면 잠금을 해제하고 이 Mac을 다시 신뢰해야 합니다.
- APFS에서는 원본과 디스크 블록을 공유하고 변경한 부분만 보관하므로 첫 부팅 후 약 0.35 GB를 차지합니다. 다만 `du`와 Finder는 각각을 전체 크기로 표시합니다.

> [!WARNING]
> `SEPStorage`, `nvram.bin`, 디스크 이미지를 머신끼리 바꾸지 마세요. 이들은 한 번의 복원으로 함께 만들어졌으며, SEP 저장소가 디스크와 맞지 않는 게스트는 부팅할 때 패닉합니다.

## 파일 위치

| 기본 경로 | 내용 |
| --- | --- |
| `~/.vphone/machines/<name>/` | 가상 머신 하나. 디스크, `config.plist`, 패치 작업 파일 포함 |
| `~/.vphone/ipsws/` | 원격 소스 IPSW. 모든 가상 머신이 공유하며, 로컬 IPSW는 그 자리에서 읽습니다 |
| `~/.vphone/gpu-drivers/<version>_<build>/` | cloudOS에서 추출한 GPU 드라이버 번들. 모든 가상 머신이 공유합니다 |
| `~/.vphone/kernelcache/` | vphone600 구성 요소가 없는 cloudOS 릴리스용 kernelcache 믹스, 준비된 볼륨, 도너 추출물 |

위치를 옮기려면 다음을 사용합니다.

| 설정 | 옮기는 대상 |
| --- | --- |
| `VPHONE_ROOT` | `~/.vphone` 데이터 루트 전체: 머신 보관함과 캐시 |
| `VPHONE_LIBRARY_ROOT` | 머신 보관함만. `VPHONE_ROOT`보다 우선합니다 |
| `vm create`와 `fw prepare`의 `--ipsw-cache <dir>` | IPSW 캐시만 |

## IPSW 캐시와 다운로드

내려받은 IPSW는 삭제할 때까지 캐시에 남으므로, 같은 URL로 두 번째 머신을 만들 때는 아무것도 내려받지 않습니다. Launchpad에서는 **File > Downloaded IPSWs…**로 삭제합니다.

준비된 복원 트리는 `--keep-artifacts`를 넘기지 않으면 `vm create`가 성공한 뒤 삭제됩니다. 이전 빌드에서 준비한 머신에는 `.ipsw-cache/` 디렉터리가 남아 있을 수 있습니다. 삭제해도 안전하며, `vm export`는 이를 제외합니다.

원격 IPSW는 Apple의 CDN처럼 서버가 HTTP 범위 요청에 응답하면 네 개의 연결로 동시에 내려받습니다. 각 연결은 32 MB 세그먼트를 차례로 받으며, 끊긴 세그먼트는 멈춘 곳부터 이어 받습니다. `fw prepare`의 `--download-connections <n>`으로 연결 수를 1~16 사이에서 지정합니다. 1이면 IPSW를 하나의 스트림으로 내려받으며, 범위 요청을 무시하는 서버에서도 이렇게 동작합니다.

## 디스크 공간과 메모리

리소스를 많이 쓰는 생성 작업은 한 번에 하나씩 실행하세요. IPSW와 임시 복원 트리가 상당한 디스크 공간을 차지하며, 큰 캐시를 패치할 때 메모리를 많이 사용할 수 있습니다. 두 번째 머신을 시작하기 전에 여유 공간을 확인하세요.

Launchpad는 해당하는 경우 CFW 작업 파일을 보관함이 있는 외장 볼륨에 둡니다. 단독으로 실행하는 `vphone-cli cfw install`은 기본적으로 `/private/var/tmp`를 사용하며, root 소유의 비공개 디렉터리를 지정하는 `--work-parent`를 받습니다.

## 함께 보기

- [스냅샷](snapshots.md)
- [템플릿](templates.md)
- [가상 머신 간 디스크 공간 공유](sharing-disk-space.md)
- [머신 생성 및 실행](../machines/create-and-run.md)
