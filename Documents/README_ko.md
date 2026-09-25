<div align="right"><a href="../README.md">English</a> · <a href="README_zh.md">中文</a> · <a href="README_ja.md">日本語</a> · <strong>한국어</strong></div>

# vphone-cli

> 이전 버전의 vphone-cli 1.x를 찾으신다면 [1.0.14 릴리스](https://github.com/Lakr233/vphone-cli/releases/tag/1.0.14)를 확인하세요.

Apple Silicon Mac에서 가상 iPhone을 만들고 실행합니다. vphone-cli는 Apple의 Virtualization.framework와 PCC 연구용 VM 기반을 사용합니다.

![macOS에서 실행 중인 가상 iPhone](demo.jpeg)

버전 2.x는 이전에 EXP로 제공하던 변경 사항을 포함한 전체 펌웨어 패치 세트를 적용합니다. 패치 구성은 선택할 수 없습니다. 독립적으로 실행 가능한 `VPhone.bundle`이 펌웨어 준비, 복원, VM 제어를 담당하고, `vphone-launchpad`가 bundle 설치와 VM 생성 및 실행을 안내합니다.

권장 호스트 설정은 macOS 복구 환경에서 `csrutil enable --without debug`와 `csrutil allow-research-guests enable`을 실행하는 것입니다. SIP를 켠 상태로 유지하면서 디버깅 제한을 완화합니다. Launchpad는 호스트를 확인하고 권한 있는 도우미를 사용하여 검증된 VM 바이너리가 AMFI를 통과하도록 허용합니다. 자세한 내용은 [호스트 설정](Guides/host-setup.md)을 참고하세요.

## 시작하기

macOS 15 이상을 실행하는 물리 Apple Silicon Mac에서는 공증된 [vphone-launchpad 2.0.5](https://github.com/Lakr233/vphone-cli/releases/download/2.0.5/vphone-launchpad-2.0.5-notarized.zip)를 사용하세요. 릴리스 버전을 실행할 때 Xcode, Python, Homebrew는 필요하지 않습니다.

1. macOS 복구 환경에서 `csrutil enable --without debug`와 `csrutil allow-research-guests enable`을 실행한 다음 재시동하세요. 자세한 내용은 [호스트 설정](Guides/host-setup.md)을 참고하세요.
2. 압축을 풀고 앱을 여세요. **Host Setup**의 안내에 따라 개발자 도구 접근을 허용하고 권한 있는 도우미를 설치하세요.
3. **Core Bundle**에서 **Download and Install**을 선택하여 최신 `VPhone.bundle`을 설치하세요. Launchpad가 다운로드를 검증하고 VM 바이너리를 호스트에서 사용할 수 있도록 준비합니다.
4. **Machines**에서 **New Machine**을 선택하고 카탈로그에서 펌웨어 조합을 고른 다음 **Create**를 클릭하세요. Launchpad가 첫 부팅을 확인한 뒤에도 VM은 계속 실행됩니다.

카탈로그의 펌웨어 조합을 선택하면 펌웨어가 다운로드됩니다. 로컬 IPSW를 사용하더라도 VM을 생성하려면 복원 티켓을 받을 네트워크 연결과 충분한 디스크 여유 공간이 필요합니다. 호환되는 iPhone 및 cloudOS IPSW를 직접 지정할 수도 있습니다. 검증된 조합은 [호환성 가이드](Guides/compatibility.md)를 참고하세요. 소스 빌드와 터미널 사용법은 [호스트 설정](Guides/host-setup.md) 및 [생성 및 실행 가이드](Guides/create-and-run.md)를 확인하세요.

2.x 버전은 `schemaVersion=2` 형식으로 생성한 VM만 시작할 수 있습니다. 이전 버전의 VM은 다시 만들어야 합니다.

## 커스텀 펌웨어 Bootstrap

VM을 실행한 뒤 macOS 메뉴 막대에서 **Guest > Install Bootstrap…**을 선택하고 환경 레이아웃을 고르세요. 그러면 게스트에 Irisin이 설치됩니다.
Option 키를 누른 채 이 메뉴를 열면 로컬 Irisin `.deb` 파일을 선택할 수 있습니다. **Uninstall Bootstrap…**의 Option 메뉴는 rootless와 RootHide 환경을 모두 삭제하지만 게스트를 재시동하지 않습니다. 일반 제거는 삭제 후 재시동합니다.

환경을 처음 준비할 때는 Irisin에서 `apt`와 `bash`를 선택하세요. **Install** 버튼을 길게 누른 다음 **Bootstrap Install**을 선택하세요. 이 모드는 이번 설치에 포함된 모든 패키지를 먼저 압축 해제한 뒤 설치 절차를 다시 실행합니다. 따라서 `debianutils`에는 `bash`가 필요하지만 `bash`에는 이미 설정된 `debianutils`가 필요한 초기 의존성 순환을 우회할 수 있습니다. 첫 준비가 끝나면 일반 설치 방식을 사용하면 됩니다.

## 기본 사용법

VM 창에서 앱과 파일 탐색, 클립보드와 설정 관리, 스크린샷, 녹화, 진단 기능을 사용할 수 있습니다. 로컬 자동화에는 `--api-listen 127.0.0.1:8765` 옵션으로 실행하세요. 자세한 내용은 [게스트 API](../Research/vphoned_http_api.md)를 참고하세요.

| 작업 | 명령 |
| --- | --- |
| VM 목록 | `vphone-cli vm list` |
| VM 정보 | `vphone-cli vm info myphone` |
| VM 창 시작 | `vphone-cli vm launch myphone` |
| VM 중지 | `vphone-cli vm stop myphone` |
| 백업 내보내기 | `vphone-cli vm export myphone --out myphone.tzst` |
| 백업 가져오기 | `vphone-cli vm import myphone.tzst --name restored` |

VM은 기본적으로 `~/.vphone/`에 저장됩니다. 다른 명령은 `vphone-cli <group> --help`에서 확인할 수 있습니다.

## 구성

`vphone-cli`는 펌웨어 준비, VM 복원 및 수명 주기 관리를 담당합니다. 번들에 포함된 `vphone-vm`이 게스트를 실행하고 macOS 창을 관리합니다. 게스트 내부의 `vphoned`는 창의 제어 기능과 선택적으로 공개하는 HTTP·WebSocket API를 제공합니다. Xcode의 `VPhone` scheme은 독립적으로 실행 가능한 `VPhone.bundle`을 빌드하고 검증합니다.

## 저장소 안내

| 경로 | 내용 |
| --- | --- |
| [`VPhoneExecutable/`](../VPhoneExecutable/) | CLI, VM 프로세스, 펌웨어 패치 도구, 복원 백엔드 |
| [`VPhoneKit/`](../VPhoneKit/) | 호스트 공용 라이브러리와 API 클라이언트 |
| [`VPhoneDaemon/`](../VPhoneDaemon/) | 게스트 제어 데몬 `vphoned` |
| [`VPhoneGuestComponents/`](../VPhoneGuestComponents/) | 게스트 후크와 지원 바이너리 |
| [`Documents/`](README.md) | 설정, 사용법, 호환성, 문제 해결 가이드 |
| [`Research/`](../Research/README.md) | 패치 및 구현 연구 기록 |

## 감사의 말

- [wh1te4ever/super-tart-vphone-writeup](https://github.com/wh1te4ever/super-tart-vphone-writeup)
