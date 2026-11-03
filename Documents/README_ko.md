<div align="right"><a href="../README.md">English</a> · <a href="README_zh.md">中文</a> · <a href="README_ja.md">日本語</a> · <strong>한국어</strong></div>

# vphone-cli

Apple Silicon Mac에서 가상 iPhone을 실행합니다.

> [!WARNING]
> 본 프로젝트는 암호화폐나 토큰을 발행하거나 그 발행을 승인한 적이 없으며, 암호화폐 결제나 기부도 받지 않습니다. 본 프로젝트의 이름을 내세워 발행·홍보하거나 본 프로젝트와의 관련성을 주장하는 암호화폐와 토큰은 모두 사기입니다.

![macOS에서 실행 중인 가상 iPhone](demo.jpeg)

vphone-cli는 Apple의 Virtualization.framework와 PCC 연구용 가상 머신으로 iOS를 실행하며, 보안 연구, 리버스 엔지니어링, 디버깅에 적합합니다.

- **그래픽 창**: Mac에서 가상 iPhone의 화면을 조작하고, 앱과 파일을 탐색하며, 스크린샷을 찍고 화면을 녹화합니다.
- **커스텀 펌웨어(Custom Firmware)**: 시스템에 패치가 미리 적용되어 있어 패키지 환경을 설치할 수 있습니다.
- **백업과 복제**: 가상 머신을 내보내고, 가져오고, 복제할 수 있습니다.
- **자동화 API**: 선택적으로 사용할 수 있는 로컬 HTTP 및 WebSocket 인터페이스입니다.
- **추가 의존성 없음**: 실행에 Xcode, Python, Homebrew가 필요하지 않습니다.

## 준비 사항

- macOS 15 이상을 실행하는 물리 Apple Silicon Mac. macOS 가상 머신에서는 사용할 수 없습니다.
- 충분한 디스크 공간. 가상 머신마다 기본적으로 64 GB 가상 디스크를 사용하며, 펌웨어와 임시 파일이 별도로 공간을 차지합니다.
- 네트워크 연결. 시스템을 복원할 때 서명 티켓을 온라인으로 받아야 합니다.
- 보안 설정 변경. macOS 복구 모드로 진입하여 터미널에서 다음 명령을 실행한 뒤 재시동합니다.

  ```sh
  csrutil enable --without debug
  csrutil allow-research-guests enable
  ```

  SIP는 켜진 상태로 유지되며 디버깅 제한만 완화됩니다. 이유와 다른 설정 방법은 [호스트 설정](Guides/host-setup.md)을 참고하세요.

## 빠른 시작

1. [최신 릴리스](https://github.com/Lakr233/vphone-cli/releases/latest)에서 `vphone-launchpad-<버전>-notarized.zip`을 내려받아 압축을 풀고 엽니다. 모든 릴리스가 공증된 것은 아닙니다. 최신 릴리스에 `-notarized` 파일이 없으면 [다운로드 안내](Downloads/README.md)에서 공증된 버전을 선택하세요.
2. **Host Setup**에서 개발자 도구 권한을 부여하고 도우미 프로그램을 설치합니다.
3. **Core Bundle**에서 **Download and Install**을 클릭합니다. Launchpad가 `VPhone.bundle`을 내려받아 검증한 뒤, 그 안의 가상 머신 프로그램이 이 Mac에서 실행되도록 허용합니다.
4. **Machines**에서 **New Machine**을 클릭하고 펌웨어 조합을 선택한 뒤 **Create**를 클릭합니다.

Launchpad가 펌웨어를 내려받고, 패치를 적용하고, 시스템을 복원한 뒤 첫 부팅을 진행합니다. 완료되면 가상 머신은 계속 실행됩니다.

직접 준비한 iPhone 및 cloudOS IPSW를 사용할 수도 있습니다. 검증된 조합은 [호환성 안내](Guides/compatibility.md)를 참고하세요.

### 에이전트에게 맡기기

이 Mac에서 코딩 에이전트(Claude Code, Codex 등)를 사용한다면 직접 단계를 따라 하는 대신 아래 프롬프트를 붙여 넣으세요. 에이전트는 vphone 스킬을 읽고, 이미 준비된 부분을 확인한 뒤 Launchpad와 `VPhone.bundle`을 설치합니다. 관리자 암호나 macOS 복구 모드에서의 변경처럼 사용자가 해야 하는 단계에서는 멈추고 물어봅니다.

```text
이 Mac에 vphone을 설정해 주세요. 먼저 다음 스킬을 읽으세요:
https://raw.githubusercontent.com/Lakr233/vphone-cli/main/Skills/vphone-guest-control/SKILL.md
그리고 같은 폴더의 references/ 아래에 링크된 파일을 읽고 그대로 따라 하세요:
공증된 최신 vphone-launchpad를 설치하고(모든 릴리스에 -notarized zip이 있는 것은
아닙니다), vphone-launchpad-cli를 PATH에 추가하고, Launchpad와 같은 시리즈의
VPhone.bundle을 설치한 뒤 `vphone-launchpad-cli status`로 확인하세요. SIP,
boot-args 등 호스트 보안 설정은 변경하지 말고, 펌웨어와 여유 디스크 공간을
제가 확인하기 전에는 머신을 만들지 마세요. 제가 해야 하는 단계에서는 무엇을
해야 하는지 정확히 알려 주고 기다리세요.
```

## 패키지 환경 설치

가상 머신에는 기본적으로 패키지 관리자가 없습니다. 설치 방법은 다음과 같습니다.

1. 메뉴 막대에서 **Apps > Install Bootstrap…**을 선택하고 레이아웃으로 **roothide**를 선택합니다(**rootless**는 더 이상 권장되지 않습니다). 가상 머신에 Irisin이 설치됩니다.
2. Irisin에서 **OwnGoal Packages** 저장소를 열고 **OwnGoal Bootstrap for vphone**(`owngoal-bootstrap-vphone`)을 **Bootstrap Install**로 설치합니다.

   이 패키지 하나로 가상 머신에 필요한 것이 한 번에 설치됩니다: `apt`와 `dpkg`, `bash`, `zsh`와 `dash`, `sudo`, 기본 명령줄 도구, `openssh-server`, `curl`, `wget`, `vim`, `git`, `uikittools`, `launchctl`, 그리고 OwnGoal 앱. 이 패키지들을 하나씩 설치하지 마십시오. 일부 패키지는 서로 의존하며, `openssh-server`는 순환하는 의존성 선언을 포함하고 있어 따로 설치하면 도중에 실패할 수 있습니다.
3. 처음 설치를 마친 뒤에는 다른 패키지를 일반 설치로 설치하면 됩니다.

처음 설치에 실패했거나 설치 후 환경이 비정상적인 상태가 되었다면 그 자리에서 복구하려 하지 말고, **Apps > Uninstall Bootstrap…**으로 환경을 삭제한 뒤 1단계부터 다시 설치하십시오.

환경을 삭제하려면 **Apps > Uninstall Bootstrap…**을 선택합니다. 삭제 후 가상 머신이 재시동됩니다.

Option 키를 누른 채 **Apps** 메뉴를 열면 두 가지 항목이 더 있습니다.

- **Install Bootstrap from File…**: 로컬 Irisin `.deb`로 설치합니다.
- **Uninstall Bootstrap Without Restarting…**: 가상 머신을 재시동하지 않고 환경을 삭제합니다.

## 명령줄

Launchpad는 `VPhone.bundle` 안의 `vphone-cli`로 가상 머신을 관리하며, 터미널에서 직접 사용할 수도 있습니다.

| 작업 | 명령 |
| --- | --- |
| 가상 머신 목록 보기 | `vphone-cli vm list` |
| 가상 머신 정보 보기 | `vphone-cli vm info myphone` |
| 가상 머신 시작 | `vphone-cli vm launch myphone` |
| 가상 머신 중지 | `vphone-cli vm stop myphone` |
| 가상 머신 복제 | `vphone-cli vm clone myphone copy` |
| 가상 머신 내보내기 | `vphone-cli vm export myphone --out myphone.tzst` |
| 가상 머신 가져오기 | `vphone-cli vm import myphone.tzst --name restored` |

가상 머신은 기본적으로 `~/.vphone/`에 저장됩니다. 전체 명령은 `vphone-cli <group> --help`로 확인하세요. Launchpad 없이 가상 머신을 만드는 방법은 [생성 및 실행](Guides/create-and-run.md)을 참고하세요.

### 자동화 API

시작할 때 `--api-listen`을 추가하면 활성화됩니다.

```sh
vphone-cli vm launch myphone --api-listen 127.0.0.1:8765
# 출력에 [api] token: …이 표시됩니다
curl -H "Authorization: Bearer $TOKEN" http://127.0.0.1:8765/v1/health
```

시작할 때마다 새 token이 생성됩니다. 고정된 token을 사용하려면 환경 변수 `VPHONE_API_TOKEN`을 설정하세요. token이 없는 요청과 웹 페이지에서 온 요청은 모두 거부됩니다. 인터페이스 설명은 [API 문서](../Research/vphoned_http_api.md)를 참고하세요.

## 부트 ROM

새로 만든 가상 머신은 Virtualization.framework에 포함된 비공개 ROM 대신 두 가지 오픈 소스 ROM으로 부팅합니다.

- [OpenAVB](https://github.com/owngoal-dev/OpenAVB)는 부트 ROM인 AVPBooter를 대신합니다. 패치가 필요 없으므로 `fw patch`가 건드리지 않습니다.
- [OpenSEP](https://github.com/owngoal-dev/OpenSEP)는 SEP 부트 ROM인 AVPSEPBooter를 대신합니다.

둘을 함께 쓰면 iBoot와 SEPOS 이전에 실행되는 코드 중 Apple이 작성한 것은 없습니다. 두 ROM 모두 미리 빌드된 상태로 `VPhone.bundle`에 포함되며, 고정된 업스트림 커밋에서 빌드됩니다. 각각의 설명([OpenAVB](../VPhoneExecutable/VPhoneVirtualization/Resources/OpenAVB/README.md), [OpenSEP](../VPhoneExecutable/VPhoneVirtualization/Resources/OpenSEP/README.md))에 소스에서 다시 빌드하고 바이트 단위로 대조하는 방법이 있습니다.

이전 버전에서 만든 가상 머신은 Apple의 ROM을 그대로 사용합니다. 시스템을 다시 복원하지 않고 어느 쪽으로든 전환할 수 있으며, 다음 시작부터 적용됩니다.

```sh
vphone-cli vm config myphone --rom openavb --seprom opensep   # 오픈 소스 ROM
vphone-cli vm config myphone --rom apple --seprom apple       # Apple의 ROM
```

`vphone-cli vm info myphone`으로 가상 머신이 사용하는 ROM을 확인할 수 있습니다. OpenAVB로 부팅하는 가상 머신을 복원하려면 `VPhone.bundle` 2.10.1 이상이 필요합니다. 자세한 내용은 연구 기록의 [OpenAVB](../Research/Firmware/openavb_boot_rom.md)와 [OpenSEP](../Research/Firmware/opensep_sep_rom.md)를 참고하세요.

## 문제가 생기면

먼저 [문제 해결](Guides/troubleshooting.md)을 확인하세요. 시스템이 가상 머신 프로그램을 거부하는 경우, 복원 실패, “Press home to continue”에서 멈추는 경우 등을 다룹니다. 그래도 해결되지 않으면 [이슈를 등록](https://github.com/Lakr233/vphone-cli/issues)해 주세요.

## 문서

| 문서 | 내용 |
| --- | --- |
| [다운로드 안내](Downloads/README.md) | 공증된 Launchpad 버전과 맞는 `VPhone.bundle` 버전 |
| [호스트 설정](Guides/host-setup.md) | SIP 및 AMFI 설정, 소스 빌드, 환경 점검 |
| [생성 및 실행](Guides/create-and-run.md) | 펌웨어 출처, 생성 절차, 저장과 백업 |
| [호환성 안내](Guides/compatibility.md) | 검증된 펌웨어 조합 |
| [문제 해결](Guides/troubleshooting.md) | 자주 발생하는 오류와 해결 방법 |
| [네트워크](Guides/networking.md) | 네트워크 모드, 그리고 Mac이 VPN이나 프록시를 쓸 때의 `tunnel` |
| [Launchpad 명령줄](Guides/launchpad-cli.md) | `vphone-launchpad-cli`로 로컬 빌드 설치 및 테스트 |
| [연구 기록](../Research/README.md) | 패치와 구현 세부 사항 |

## 프로젝트 구조

- `vphone-launchpad`: `VPhone.bundle`을 내려받아 설치하고 호스트를 설정하는 Mac 앱입니다. 별도로 배포됩니다.
- `vphone-cli`: 펌웨어 준비, 패치 적용, 시스템 복원, 가상 머신 관리를 담당합니다.
- `vphone-vm`: 가상 머신을 실행하고 가상 머신 창을 표시합니다.
- `vphoned`: 가상 머신 안의 제어 서비스로, 창의 기능과 API는 모두 이를 통해 동작합니다.

| 경로 | 내용 |
| --- | --- |
| [`VPhoneExecutable/`](../VPhoneExecutable/) | `vphone-cli`, `vphone-vm`, 펌웨어 패치와 복원 |
| [`VPhoneKit/`](../VPhoneKit/) | 호스트 공용 라이브러리와 API 클라이언트 |
| [`VPhoneDaemon/`](../VPhoneDaemon/) | `vphoned` |
| [`VPhoneGuestComponents/`](../VPhoneGuestComponents/) | 가상 머신 안의 hook과 도우미 프로그램 |
| [`VPhoneLaunchpad/`](../VPhoneLaunchpad/) | Launchpad 앱과 도우미 프로그램 |

소스에서 빌드하려면 `xcodebuild -workspace VPhone.xcworkspace -scheme VPhone build`를 실행합니다. 결과물은 `VPhone.bundle`입니다.

## 감사의 말

- [wh1te4ever/super-tart-vphone-writeup](https://github.com/wh1te4ever/super-tart-vphone-writeup)
- [owngoal-dev/OpenAVB](https://github.com/owngoal-dev/OpenAVB)와 [owngoal-dev/OpenSEP](https://github.com/owngoal-dev/OpenSEP): 새 가상 머신이 부팅에 쓰는 부트 ROM
