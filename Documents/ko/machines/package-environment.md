# 패키지 환경

가상 머신에 패키지 관리자를 설치하거나 제거합니다. 새 가상 머신에는 패키지 관리자가 없습니다. 게스트에서 `apt`, 셸, SSH 등 명령줄 도구가 필요할 때 이 페이지를 따르세요.

## 설치

1. 가상 머신 창의 메뉴 막대에서 **Apps > Install Bootstrap…**을 선택하고 **roothide** 레이아웃을 선택합니다(**rootless**는 더 이상 권장되지 않습니다). 가상 머신에 Irisin이 설치됩니다.
2. Irisin에서 **OwnGoal Packages** 저장소를 열고 **OwnGoal Bootstrap for vphone**(`owngoal-bootstrap-vphone`)을 찾아 **Bootstrap Install**로 설치합니다.
3. 처음 설치를 마친 뒤에는 다른 패키지를 일반적인 방법으로 설치합니다.

`owngoal-bootstrap-vphone` 하나로 가상 머신에 필요한 것이 한 번에 설치됩니다. `apt`와 `dpkg`, `bash`, `zsh`와 `dash`, `sudo`, 기본 명령줄 도구, `openssh-server`, `curl`, `wget`, `vim`, `git`, `uikittools`, `launchctl`, 그리고 OwnGoal 앱입니다.

> [!WARNING]
> 이 패키지들을 하나씩 설치하지 마세요. 일부 패키지는 서로 의존하며, `openssh-server`는 일부 의존성을 순환하도록 선언하고 있어 따로 설치하면 도중에 실패할 수 있습니다.

처음 설치에 실패하면 그 자리에서 복구하려 하지 마세요. **Apps > Uninstall Bootstrap…**을 선택한 뒤 1단계부터 다시 시작합니다.

### 가상 머신을 만들면서 설치하기

```sh
vphone-cli vm create myphone --bootstrap roothide ...
```

`--bootstrap roothide`는 새 머신의 첫 부팅 중에 1단계와 2단계를 수행합니다. Irisin을 설치한 뒤, Irisin이 권장하는 저장소에서 `irisin-cli`를 통해 `owngoal-bootstrap-vphone`을 Bootstrap Install로 설치합니다. 2단계에는 `irisin-cli install`이 `--repository`와 `--bootstrap-install`을 지원하는 Irisin이 필요합니다.

## 제거

**Apps > Uninstall Bootstrap…**을 선택합니다. 제거 후 가상 머신이 재시동됩니다.

Irisin은 데이터(다운로드, 기록, 설정)를 홈 아래의 `Documents/wiki.qaq.irisin`에 보관합니다.

| 레이아웃 | Irisin의 홈 | 제거 후 |
| --- | --- | --- |
| roothide | 환경 자체의 `/var/mobile` | 데이터가 다른 모든 것과 함께 제거됩니다. |
| rootless | 시스템의 `/var/mobile` | 데이터가 남습니다. |

## 추가 옵션

Option 키를 누른 채 **Apps** 메뉴를 열면 두 가지 항목이 더 나타납니다.

- **Install Bootstrap from File…:** 로컬 Irisin `.deb`로 설치합니다.
- **Uninstall Bootstrap Without Restarting…:** 가상 머신을 재시동하지 않고 환경을 제거합니다.

같은 작업을 자동화 API(`bootstrap.install`, `bootstrap.status`)로도 할 수 있습니다. [API 레퍼런스](../../../Research/vphoned_http_api.md)를 참고하세요.

## 함께 보기

- [가상 머신 생성 및 실행](create-and-run.md)
- [자동화 API](automation-api.md)
- [문제 해결](../help/troubleshooting.md)
