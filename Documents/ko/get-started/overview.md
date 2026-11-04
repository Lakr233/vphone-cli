# 개요

vphone-cli는 Apple Silicon Mac에서 가상 iPhone을 실행합니다. 이 페이지에서는 vphone-cli가 하는 일, Mac에 필요한 조건, 각 프로그램의 역할을 설명합니다.

> [!WARNING]
> 본 프로젝트는 암호화폐나 토큰을 발행하거나 그 발행을 승인한 적이 없으며, 암호화폐 결제나 기부도 받지 않습니다. 본 프로젝트의 이름을 내세워 발행·홍보하거나 본 프로젝트와의 관련성을 주장하는 암호화폐와 토큰은 모두 사기입니다.

![macOS에서 실행 중인 가상 iPhone](../../demo.jpeg)

vphone-cli는 Apple의 Virtualization.framework와 PCC 연구용 가상 머신으로 iOS를 실행하며, 보안 연구, 리버스 엔지니어링, 디버깅에 사용합니다.

## 기능

- **그래픽 창:** Mac에서 가상 iPhone의 화면을 조작하고, 앱과 파일을 탐색하며, 스크린샷을 찍고 화면을 녹화합니다.
- **커스텀 펌웨어:** 시스템에 패치가 미리 적용되어 있으며, [패키지 환경](../machines/package-environment.md)을 설치할 수 있습니다.
- **백업과 복제:** 가상 머신을 내보내고, 가져오고, 복제합니다.
- **자동화 API:** 선택적으로 사용할 수 있는 로컬 HTTP 및 WebSocket 인터페이스입니다. [자동화 API](../machines/automation-api.md)를 참고하세요.
- **추가 의존성 없음:** 실행에 Xcode, Python, Homebrew가 필요하지 않습니다.

## 준비 사항

- macOS 15 이상을 실행하는 물리 Apple Silicon Mac. macOS 가상 머신에서는 동작하지 않습니다.
- 여유 디스크 공간. 가상 머신마다 기본적으로 64 GB 가상 디스크를 사용하며, 펌웨어가 별도로 공간을 차지합니다.
- 네트워크 연결. 시스템을 복원할 때 서명 티켓을 온라인으로 받습니다.
- 보안 설정 변경. macOS 복구로 시동하고 터미널에서 다음 명령을 실행한 뒤 재시동합니다.

  ```sh
  csrutil enable --without debug
  csrutil allow-research-guests enable
  ```

  SIP는 켜진 상태로 유지되며 디버깅 제한만 완화됩니다. 자세한 내용은 [호스트 설정](host-setup.md)을 참고하세요.

## 네 가지 프로그램

| 프로그램 | 역할 |
| --- | --- |
| `vphone-launchpad` | `VPhone.bundle`을 내려받아 설치하고 호스트를 설정하는 Mac 앱입니다. 별도로 배포됩니다. |
| `vphone-cli` | 펌웨어를 준비하고 패치하며, 시스템을 복원하고 가상 머신을 관리합니다. |
| `vphone-vm` | 가상 머신을 실행하고 그 창을 표시합니다. |
| `vphoned` | 가상 머신 안의 제어 서비스입니다. 창의 기능과 API가 이를 통해 동작합니다. |

`vphone-cli`, `vphone-vm`, `vphoned`는 `VPhone.bundle`에 함께 포함되어 배포됩니다. Launchpad는 이 번들 안의 `vphone-cli`로 각 가상 머신을 제어하며, 터미널에서 `vphone-cli`를 직접 실행할 수도 있습니다.

## 함께 보기

- [빠른 시작](quick-start.md)
- [호스트 설정](host-setup.md)
- [다운로드](downloads.md)
- [가상 머신 생성 및 실행](../machines/create-and-run.md)
