<div align="right"><a href="../README.md">English</a> · <a href="README_zh.md">中文</a> · <a href="README_ja.md">日本語</a> · <strong>한국어</strong></div>

# vphone-cli

> [!WARNING]
> 버전 2.0은 개발 중입니다. 안정 버전이 필요하면 [1.0.14](https://github.com/Lakr233/vphone-cli/tree/1.0.14)를 사용하세요.

Apple Silicon Mac에서 가상 iPhone을 만들고 실행합니다. vphone-cli는 Apple의 Virtualization.framework와 PCC 연구용 VM 기반을 사용합니다.

![macOS에서 실행 중인 가상 iPhone](demo.jpeg)

버전 2.0에서는 1.0의 무겁고 복잡한 호스트 설정을 상당 부분 없애고 커스텀 펌웨어에 필요한 시스템 수정 사항을 간소화했습니다. 핵심 흐름이 어느 정도 안정되어 구성은 **JB 한 가지**로 정리했습니다. 독립적으로 실행 가능한 `VPhone.bundle`의 CLI에서 펌웨어 다운로드부터 설치와 시작까지 처리합니다.

현재 권장하는 호스트 설정은 macOS 복구 환경에서 `csrutil enable --without debug`와 `csrutil allow-research-guests enable`을 실행하는 것입니다. SIP는 켜진 상태로 유지되고 디버깅 제한만 완화됩니다. AMFI가 VM 바이너리를 허용하도록 하려면 root 권한이 필요합니다. 절차는 [호스트 설정](Guides/host-setup.md), 원리는 [amfi-allow 연구 자료](https://github.com/Lakr233/amfi-allow)를 참고하세요. 향후 `vphone-ui.app`에서는 설정을 더 쉽게 하고 설치 단계의 수정 사항을 선택할 수 있게 할 예정입니다.

## 시작하기

macOS 15 이상이 설치된 Apple Silicon Mac, 소스 빌드용 Xcode, iPhone 복원 IPSW, 호환되는 cloudOS IPSW가 필요합니다. [호스트 설정](Guides/host-setup.md)에 따라 VM의 비공개 권한을 허용하고 [검증된 펌웨어 조합](Guides/compatibility.md)을 확인하세요. 중첩된 macOS VM에서는 게스트를 실행할 수 없습니다.

```sh
git clone https://github.com/Lakr233/vphone-cli.git
cd vphone-cli
xcodebuild -workspace VPhone.xcworkspace -scheme VPhone \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/XcodeBundle build
export PATH="$PWD/.build/XcodeBundle/Build/Products/Debug/VPhone.bundle/Contents/MacOS:$PATH"

vphone-cli host preflight
vphone-cli vm create myphone \
  --iphone-source /path/to/iPhone17,3_Restore.ipsw \
  --cloudos-source /path/to/cloudOS.ipsw
vphone-cli vm launch myphone
```

`vm create`는 게스트 준비와 복원, JB 시스템 변경 설치, `vphoned` 응답 확인을 수행합니다. 확인용 부팅은 완료 후 중지되므로, 실제 사용을 위해 `vm launch`로 VM 창을 여세요. 생성에는 네트워크 연결이, CFW 설치에는 관리자 권한이 필요합니다. 자세한 내용은 [생성 및 실행 가이드](Guides/create-and-run.md)를 참고하세요.

2.x 버전은 `schemaVersion=2` 형식으로 생성한 VM만 시작할 수 있습니다. 이전 버전의 VM은 다시 만들어야 합니다.

## 커스텀 펌웨어 Bootstrap

VM을 실행한 뒤 macOS 메뉴 막대에서 **Guest > Install Bootstrap…**을 선택하고 환경 레이아웃을 고르세요. 그러면 게스트에 Irisin이 설치됩니다.

환경을 처음 준비할 때는 Irisin에서 `coreutils`, `debianutils`, `dash` 등의 기본 패키지를 선택하세요. **Install** 버튼을 길게 누른 다음 **Bootstrap Install**을 선택하세요. 이 모드는 선택한 모든 패키지를 먼저 압축 해제한 뒤 설치 절차를 다시 실행합니다. 따라서 `debianutils`에는 `bash`가 필요하지만 `bash`에는 이미 설정된 `debianutils`가 필요한 초기 의존성 순환을 우회할 수 있습니다. 기본 패키지 설치가 끝나면 일반 설치 방식을 사용하면 됩니다.

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
