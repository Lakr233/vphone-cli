# 템플릿 만들기와 찾기

가상 머신을 직접 템플릿으로 마무리하는 방법, `vm create`가 어떤 템플릿을 사용할지 확인하는 방법, Launchpad가 템플릿을 만드는 방식을 설명합니다. 템플릿이 무엇이고 키에 무엇이 포함되는지는 먼저 [템플릿](templates.md)을 읽으세요.

## 가상 머신을 템플릿으로 마무리하기

가상 머신을 만든 직후 템플릿으로 만들려면 중지하고, 정리하고, 설정 부팅을 거친 뒤 채택합니다. Launchpad가 템플릿을 만들어야 할 때 하는 작업과 같습니다.

```sh
vphone-cli vm stop phone-src
vphone-cli vm template trim phone-src --tier standard   # offline, no root; frees nothing until the setup boot
vphone-cli vm template setup phone-src        # headless; --window to watch, slimming switches as for vm create
vphone-cli vm template adopt phone-src --iphone-source … --cloudos-source …   # key from its records; the sources are recorded
vphone-cli vm create phone-d --template <id> --skip-first-boot
```

### vm template setup

- 실행 중인 가상 머신과 고정된 템플릿은 거부합니다.
- 자체적으로는 아무것도 정리하지 않습니다. `vm template trim`이 기록한 단계를 유지하며, 다른 단계를 지정한 `--trim`은 거부합니다.
- 가상 머신에서 vphoned가 제거하지 못한 앱이 있으면 이를 보고하고 기록되는 단계에서 제외하므로, 채택된 키는 실제로 수행된 작업을 나타냅니다.
- `--strict`를 지정하면 대신 실패합니다. 아무것도 기록하지 않으며, 설정 부팅을 다시 실행할 수 있습니다. 같은 스위치에 대해 `vm template find`가 제공한 키로 `--expect`와 함께 가상 머신을 채택할 때 사용하세요.
- `vm template list`에 표시된 `.building-…` 이름(설정 부팅이 실패한 `vm create`)을 지정하면, 빌드를 그 키에 맞게 설정하여 경량화 방식을 확정하고, 빌드가 오프라인 정리 전에 멈췄다면 먼저 정리를 실행하며, 성공하면 고정합니다.

### vm template adopt

| 옵션 | 효과 |
| --- | --- |
| `--iphone-source`, `--cloudos-source` | 템플릿을 만드는 `vm create`처럼, 가상 머신을 만들 때 사용한 IPSW를 `Template.plist`에 기록합니다. |
| `--json` | 새 템플릿을 `vm template show --json`과 같은 형식으로 출력합니다. |
| `--expect <id>` | 가상 머신의 기록이 템플릿 식별자 `<id>`를 제공하지 않으면 거부하고 가상 머신을 그대로 둡니다. `<id>`는 그 가상 머신을 만들 때 사용한 옵션으로 `vm template find`가 출력한 `id`입니다. |

나중에 템플릿을 다시 찾아야 한다면 항상 `--expect`를 사용하세요. 이 옵션이 없으면 설정 부팅이 완전히 끝나지 않은(제거하지 못한 앱이 있는) 가상 머신이 다른 키로 저장되고, 이후 같은 옵션의 모든 `vm create`가 이를 찾지 못해 또 다른 템플릿을 만들게 됩니다.

거부할 때 예상 키를 계산할 수 있으면 서로 다른 필드를 표시합니다. 보관함의 템플릿이나 빌드에 그 키가 있거나 경량화 방식만 다를 때 계산할 수 있습니다. 그렇지 않으면 비교할 수 있도록 가상 머신 자체의 키를 출력합니다. `--json`을 지정하면 거부 내용이 stdout에도 출력되며, 명령은 상태 1로 종료됩니다.

```text
{"adopted": false, "error": "unexpected_template", "id": …, "expected": …, "differences": […], …}
```

## 템플릿 찾기

`vm template find`는 아무것도 내려받거나 복원하거나 변경하지 않고, 같은 옵션의 `vm create`가 어떤 템플릿에서 복제할지 알려 줍니다.

```sh
vphone-cli vm template find --iphone-source … --cloudos-source … [--device …] [--preset …] [--disk-size …] [--block <id>] [--allow <id>] [slimming switches] --json
```

키는 `vm create`와 같은 방식으로 계산합니다. 빌드 정보는 IPSW가 로컬 파일이거나 이미 IPSW 캐시에 있으면 IPSW에서, 그렇지 않으면 기록에 같은 두 소스가 있는 템플릿에서 가져오므로, IPSW를 삭제한 뒤에도(로컬 IPSW 포함) 키를 계산할 수 있습니다. `--block`과 `--allow`는 `fw set-patches`가 기록하는 것과 같은 패치별 재정의입니다.

| JSON 필드 | 의미 |
| --- | --- |
| `resolved` | 키를 계산할 수 있었는지 여부 |
| `resolvedBy` | `ipsw` 또는 `template` |
| `id` | 템플릿 식별자 |
| `summary` | 키 요약 |
| `key` | 전체 키 |
| `template` | 일치하는 템플릿. `vm template show --json` 형식이며, 최신이든 오래되었든 표시됩니다 |
| `usable` | 템플릿이 존재하며 최신인지 여부 |
| `building` | 생성 작업이 빌드 잠금을 갖고 있는지 여부 |
| `reason` | 키를 계산할 수 없을 때 그 이유 |

## Launchpad에서

Launchpad 2.9 이상은 기본적으로 템플릿에서 머신을 만듭니다.

### New Machine

New Machine은 짧은 페이지로 열립니다. 이름, 펌웨어 카탈로그의 기기와 iOS 버전, **Slim System** 스위치가 있습니다. 그 아래 행은 나머지 설정을 요약하며, 네 페이지로 된 **Advanced Options**를 엽니다.

- 하드웨어
- 템플릿과 그 구성: 정리 단계와 유지할 언어, 서비스 프로필, 제거할 시스템 앱
- Core Bundle, 사용자 지정 IPSW, 패치
- 위치, 네트워크, 복원 옵션

이 행은 기본값과 다른 설정의 개수를 세고, **Create**를 막는 항목이 있으면 그 이름을 표시합니다. **Create from a template**를 끄면 `--no-template`처럼 머신을 자체 키로, 경량화 없이 단독 복원합니다. Apple 계정 옵션은 제공되지 않습니다. 어느 쪽이든 게스트가 로그인을 거부하므로, 서비스 프로필이 trimmed일 때 Launchpad는 항상 `--accounts-off`를 넘깁니다. 시트는 페이지에 맞춰 600포인트까지 커지고 그 이상은 스크롤되므로, 노트북 화면에서도 버튼이 화면 안에 남습니다.

### kernelcache를 다시 빌드하는 펌웨어

**Firmware**에서 자체 cloudOS에서도 실행되는 릴리스(`fw catalog`의 세 번째 열)는 권장 cloudOS 옆에 그 cloudOS를 제공합니다. 이 경우 생성 작업은 사용자 권한으로 kernelcache 믹스를 빌드하고, 그 릴리스의 kernelcache를 빌드할 때 사용된 kmutil로 링크합니다([펌웨어 준비](../firmware/firmware-preparation.md#믹스를-링크하는-kmutil) 참고). Core Bundle 2.17 이하에서는 대신 도우미가 root로 링크하며, 이때 인증을 한 번 요청합니다.

이전의 호환 Core Bundle(2.12.0)은 `ipsw` 도구로 믹스를 준비하므로, Launchpad는 이런 조합에 여전히 `ipsw` 도구 필드를 표시합니다. Core Bundle 2.12.1 이상은 네이티브로 추출하며 선택한 경로를 무시합니다.

iPhone XS Max는 iOS 18.1~18.7.2를 각 릴리스 자체의 cloudOS에서 템플릿 없이 실행하며, 기본 프리셋은 Minimal입니다. Standard도 동작합니다(18.6에서 확인). 이 조합은 항상 kernelcache를 다시 빌드하며, 어떤 macOS에서든 macOS 15의 kmutil로 링크합니다.

### 생성 작업이 템플릿을 사용하는 방식

생성 작업은 먼저 `vm template find`를 실행합니다.

- 일치하는 최신 템플릿이 있으면 머신을 복제하고(`vm create --template <id> --skip-first-boot`) 부팅합니다.
- 없으면 같은 보관함에 `template-`와 16진수 여덟 자리로 된 이름의 임시 머신을 만들어 템플릿을 빌드합니다. 일반적인 단계(복원, 그리고 도우미를 통한 `cfw install`)를 실행한 뒤 `vm template trim`, 헤드리스 `vm template setup --strict`, `vm template adopt --iphone-source … --cloudos-source … --expect <id>`를 실행하고, 그 결과에서 머신을 복제합니다.

제거해야 할 앱이 남아 있으면 설정 부팅이 실패하고, 빌드의 키가 `find`가 계산한 키와 다르면 채택이 실패하므로, 이후 생성 작업이 찾지 못할 id로 빌드가 저장되는 일은 없습니다. 각각은 소요 시간이 표시되는 별도의 단계이며, 실패한 단계에는 `vphone-cli`가 제공한 이유가 표시됩니다.

New Machine의 **Patch Settings**에서 지정한 패치별 재정의는 템플릿 키와 같은 방식으로 나뉩니다.

- 부트 체인 재정의는 키에 포함됩니다. 템플릿은 그 재정의를 적용해 빌드되며, `find`도 그 재정의가 적용된 템플릿을 찾습니다.
- 게스트 패치 재정의는 키에 포함되지 않습니다. 템플릿은 그 재정의 없이 빌드됩니다. 복제 후 생성 작업은 첫 부팅 전에 `fw set-patches`로 새 머신에 재정의를 기록하고, 도우미를 통해 `cfw update-environment`로 적용합니다(**Apply guest patches** 단계). 따라서 템플릿이 한 생성 작업의 게스트 패치 선택을 다른 생성 작업에 넘기는 일은 없습니다.

템플릿을 빌드한 뒤에는 생성 작업이 원본 IPSW 두 개를 삭제할지 묻습니다. 확인 없이는 아무것도 삭제하지 않습니다.

### Launchpad에서 템플릿 관리하기

- **File > Templates…**는 모든 보관함의 템플릿을 머신, 경량화 방식, 크기, 상태와 함께 나열하며, 템플릿을 삭제할 수 있습니다.
- **Guest System…**(머신의 Actions 메뉴와 인스펙터에 있음)은 실행 중인 머신의 서비스 프로필을 전환하고, 템플릿이 제거한 시스템 앱을 되돌립니다.
- 인스펙터와 머신 목록에는 각 머신의 파일이 할당한 공간 옆에 그 머신만 사용하는 디스크 공간이 표시됩니다. 다른 머신이나 템플릿이 공유하지 않는 블록으로, 머신을 삭제하면 해제됩니다. 그 전에 만들어진 로컬 Time Machine 스냅샷은 만료될 때까지 블록을 유지합니다.

## 함께 보기

- [템플릿](templates.md)
- [여러 머신 만들기](many-machines.md)
- [펌웨어 준비](../firmware/firmware-preparation.md)
- [Launchpad CLI](../launchpad/launchpad-cli.md)
