# vphone 설명서

vphone이 처음이라면 [개요](get-started/overview.md)를 읽은 뒤 [빠른 시작](get-started/quick-start.md)을 따라 하세요.

## 시작하기

| 페이지 | 내용 |
| --- | --- |
| [개요](get-started/overview.md) | vphone이 무엇이고, 무엇이 필요하며, 어떤 프로그램이 포함되는지 |
| [빠른 시작](get-started/quick-start.md) | Launchpad 또는 코딩 에이전트로 첫 가상 머신 만들기 |
| [호스트 설정](get-started/host-setup.md) | Mac의 SIP, AMFI, Research Guests 설정 |
| [다운로드](get-started/downloads.md) | 공증된 Launchpad 버전과 그에 맞는 `VPhone.bundle` 버전 |

## 머신

| 페이지 | 내용 |
| --- | --- |
| [가상 머신 생성 및 실행](machines/create-and-run.md) | 터미널에서 가상 머신 만들기, 시작, 중지 |
| [부트 ROM](machines/boot-roms.md) | OpenAVB/OpenSEP와 Apple ROM 사이의 전환 |
| [자동화 API](machines/automation-api.md) | 선택적으로 사용하는 로컬 HTTP 및 WebSocket 인터페이스 |
| [기기 이름과 시계](machines/device-name-and-clock.md) | 게스트가 가상 머신 이름과 Mac의 시계에서 가져오는 것 |
| [패키지 환경](machines/package-environment.md) | 게스트에 패키지 관리자 설치 및 제거 |

## 펌웨어와 기기

| 페이지 | 내용 |
| --- | --- |
| [호환성](firmware/compatibility.md) | 검증된 iPhone 및 cloudOS 펌웨어 조합 |
| [펌웨어 준비](firmware/firmware-preparation.md) | GPU 드라이버 복원, 최신 cloudOS용 kernelcache 믹스 |
| [다른 iPhone 모델](firmware/iphone-models.md) | 다른 iPhone 모델의 IPSW로 iOS 실행 |
| [iPadOS 게스트](firmware/ipados.md) | iOS 대신 iPadOS 실행 |

## 저장소와 백업

| 페이지 | 내용 |
| --- | --- |
| [보관함과 백업](storage/library-and-backups.md) | 가상 머신과 캐시의 위치, 복제와 내보내기 |
| [스냅샷](storage/snapshots.md) | 중지된 가상 머신의 디스크를 저장하고 되돌리기 |
| [템플릿](storage/templates.md) | 한 번의 복원으로 여러 가상 머신 만들기 |
| [템플릿 만들기](storage/template-building.md) | 가상 머신을 템플릿으로 만들고 템플릿 찾기 |
| [디스크 공간 공유](storage/sharing-disk-space.md) | 따로 복원한 가상 머신을 위한 `vm rebase` |
| [여러 머신 만들기](storage/many-machines.md) | plist로 `vm create-bulk` 실행 |
| [셰이더 캐시](storage/shader-cache.md) | 기존 가상 머신의 영구 셰이더 캐시 |

## 네트워크

| 페이지 | 내용 |
| --- | --- |
| [네트워크 모드](networking/overview.md) | 모드 선택, 실행 중인 가상 머신의 네트워크 분리 |
| [터널 모드](networking/tunnel.md) | VPN이나 프록시 앱을 사용하는 Mac |
| [MAC 및 IP 주소](networking/addresses.md) | 저장된 MAC, 이전 임대, 고정 주소 |
| [포트 포워딩](networking/port-forwarding.md) | Mac의 포트를 게스트로 전달하기 |
| [네트워크상의 이름](networking/names.md) | 게스트의 `.local` 이름과 게스트에서의 Mac 이름 |
| [머신 간 연결](networking/peers.md) | 하나의 공유 네트워크에 있는 `nat` 머신 |

## Launchpad와 번들

| 페이지 | 내용 |
| --- | --- |
| [Launchpad 명령줄](launchpad/launchpad-cli.md) | `vphone-launchpad-cli`로 Launchpad 제어하기 |
| [코어 번들과 로컬 빌드](launchpad/core-bundles.md) | 머신을 번들에 연결하기, 로컬 빌드 테스트 |
| [번들 통합](launchpad/bundle-integration.md) | `VPhone.bundle`에 포함된 것과 앱에서 사용하는 방법 |

## 도움말

| 페이지 | 내용 |
| --- | --- |
| [문제 해결](help/troubleshooting.md) | 실행 거부, 복원 실패, 게스트 문제 |

구현 기록, 패치 기록, 전체 API 레퍼런스는 [연구 기록](../../Research/README.md)에 있으며, 영어로만 제공됩니다.
