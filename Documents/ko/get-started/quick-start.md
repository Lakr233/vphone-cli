# 빠른 시작

Launchpad로 vphone을 설정하고 첫 가상 iPhone을 부팅합니다. Mac이 [준비 사항](overview.md)을 갖춘 뒤에 진행하세요.

## Launchpad로 설정하기

1. [최신 릴리스](https://github.com/Lakr233/vphone-cli/releases/latest)에서 `vphone-launchpad-<version>-notarized.zip`을 내려받아 압축을 풀고 엽니다. 모든 릴리스가 공증된 것은 아닙니다. 최신 릴리스에 `-notarized` 파일이 없으면 [다운로드](downloads.md)에서 공증된 버전을 선택하세요.
2. **Host Setup**(호스트 설정)에서 개발자 도구 접근 권한을 부여하고 도우미를 설치합니다.
3. **Core Bundle**(코어 번들)에서 **Download and Install**(다운로드 및 설치)을 클릭합니다.
4. **Machines**(머신)에서 **New Machine**(새 머신)을 클릭하고 펌웨어 조합을 선택한 뒤 **Create**(생성)를 클릭합니다.

Launchpad가 펌웨어를 내려받고, 패치를 적용하고, 시스템을 복원한 뒤 가상 머신을 부팅합니다. 직접 준비한 iPhone 및 cloudOS IPSW를 사용하려면 [호환성](../firmware/compatibility.md)을 참고하세요.

## 에이전트에게 맡기기

이 Mac에서 코딩 에이전트(Claude Code, Codex 등)를 사용한다면 직접 단계를 따라 하는 대신 아래 프롬프트를 붙여 넣으세요. 에이전트는 vphone 스킬을 읽고, 이미 설정된 부분을 확인한 뒤 Launchpad와 `VPhone.bundle`을 설치합니다. 관리자 암호나 macOS 복구에서의 변경처럼 사용자가 해야 하는 단계에서는 멈추고 물어봅니다.

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

## 다음 단계

- 가상 머신에 패키지 관리자 설치하기: [패키지 환경](../machines/package-environment.md)
- 터미널에서 가상 머신을 제어하거나 Launchpad 없이 만들기: [가상 머신 생성 및 실행](../machines/create-and-run.md)
- HTTP와 WebSocket으로 가상 머신을 스크립트로 제어하기: [자동화 API](../machines/automation-api.md)
- 문제가 생겼을 때: [문제 해결](../help/troubleshooting.md)

## 함께 보기

- [호스트 설정](host-setup.md)
- [다운로드](downloads.md)
- [Launchpad 명령줄](../launchpad/launchpad-cli.md)
