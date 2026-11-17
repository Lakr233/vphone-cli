# Launchpad 명령줄

`vphone-launchpad-cli`는 터미널이나 스크립트에서 실행 중인 Launchpad를 제어합니다. 번들을 설치하고, 머신을 만들고 시작하고 중지하며, 게스트와 통신합니다. 창을 일일이 클릭하지 않고 Launchpad의 동작을 이용하고 싶을 때 사용하세요.

## 설정하기

CLI는 `vphone-launchpad.app/Contents/MacOS`에 포함되어 있습니다. `PATH`에 링크하세요.

```sh
ln -s /Applications/vphone-launchpad.app/Contents/MacOS/vphone-launchpad-cli /usr/local/bin/
vphone-launchpad-cli help
```

Launchpad가 실행 중이 아니면 CLI가 Launchpad를 시작합니다. CLI가 시작한 Launchpad는 숨겨진 상태로 열리며, 앞에 있는 앱의 포커스를 가져가지 않습니다. 창을 보려면 Dock 아이콘이나 메뉴 막대의 Open Launchpad를 클릭하세요. 창을 앞으로 띄운 상태로 시작하려면 `--foreground`를 넘깁니다(명령 앞, 또는 `exec`를 제외한 모든 명령의 옵션 사이). 어느 쪽도 이미 실행 중인 Launchpad에는 영향을 주지 않습니다.

## 출력과 종료 상태

- 진행 상황은 도착하는 대로 stderr에 출력됩니다.
- 결과는 stdout에 JSON 문서 하나로 출력됩니다.
- 종료 상태는 성공 시 0, 실패 시 1이며, 이유는 stderr에 출력됩니다.
- CLI를 중단하면 취소할 수 있는 명령(`exec`, 대기, CFW 설치)은 취소됩니다. 번들 설치와 머신 생성은 창에 속하므로 계속 실행됩니다.

모든 명령은 Launchpad의 창과 명령 기록에도 표시됩니다.

## 명령

두 보관함에 같은 이름의 머신이 있을 때 머신 명령은 `--root <library>`를 받습니다.

### 상태와 번들

| 명령 | 동작 |
| --- | --- |
| `status` | 호스트 점검, 도우미, 기본 번들, 머신 수 |
| `bundle list` | 설치된 버전, 영수증, cdhash, 점검 결과, 연결된 머신 |
| `bundle install-local <path> [--keep-default]` | 로컬 `VPhone.bundle` 폴더 또는 `.zip` 설치 |
| `bundle install-release <version\|latest> [--keep-default]` | GitHub 릴리스를 내려받아 설치 |
| `bundle set-default <version>` | 버전을 기본으로 지정. `bundle use`는 이전 이름입니다 |
| `bundle verify <version>` | 버전을 다시 점검 |
| `bundle accept <version> [--off]` | 실패한 점검을 건너뛰거나, `--off`로 건너뛰기를 중단 |
| `bundle remove <version>` | 연결된 머신이 없는 버전 제거 |

로컬 빌드를 설치하거나, 머신을 그 빌드로 옮기거나, 두 빌드를 비교하려면 [코어 번들과 로컬 빌드](core-bundles.md)를 참고하세요.

### 머신

| 명령 | 동작 |
| --- | --- |
| `vm list` | 모든 보관함의 머신과 실행 상태, Core Bundle, 로그 경로 |
| `vm start <name> [--headless] [--wait]` | 머신의 번들로 시작. `--wait`는 vphoned를 기다립니다 |
| `vm stop <name>` | 게스트에 종료를 요청하고(vphoned `system.shutdown`) 최대 30초 기다립니다. 게스트에 요청할 수 없거나 멈추지 않으면 가상 머신을 종료합니다 |
| `vm wait <name>` | vphoned를 기다립니다 |
| `vm log <name> [--lines <n>] [--kind create\|dfu\|patch]` | 콘솔 로그 읽기 |
| `vm create <name> [options]` | New Machine 파이프라인. 아래의 '머신 만들기'를 참고하세요 |
| `vm set-bundle <name> <version> [--update-environment]` | 머신을 설치된 다른 버전에 연결 |
| `vm leases [--release]` | 공유 NAT 네트워크의 DHCP 임대와 각 임대를 소유한 머신. `--release`는 어느 보관함의 머신도 사용하지 않는 임대를 도우미를 통해 해제합니다([MAC 및 IP 주소](../networking/addresses.md)의 '이전 MAC이 차지하고 있는 주소' 참고) |

참고:

- `vm list`에서 머신을 `running`으로 만드는 것은 디스크를 붙잡고 있는 가상 머신 프로세스(`vphone-vm` 또는 Virtualization의 가상 머신 서비스)뿐입니다. 디스크를 열고 있는 다른 프로세스(`tail`, Spotlight, 백업 도구)는 `diskOpenIn`에 표시되며(예: `12925 tail`), 머신은 `stopped`로 남습니다.
- `vm start`는 `vphone-cli vm launch`와 마찬가지로 디스크를 열고만 있는 프로세스 때문에 거부되지 않으며, 그 프로세스의 이름을 담은 메모를 출력합니다.
- `vm start --wait`와 `vm wait`는 `--timeout`도 받습니다.
- `vm set-bundle --update-environment`는 해당 버전의 게스트 환경도 다시 배포하며, 머신이 중지되어 있어야 합니다. 다른 프로세스가 디스크를 열고 있으면 연결을 바꾸기 전에 그 프로세스의 이름을 표시하며 거부합니다. 업데이트 자체가 실패하면 머신은 새 버전에 연결된 상태로 남고 `vm list`는 여전히 이전 `guestEnvironmentBundle`을 표시합니다. 마무리하려면 `cfw update-environment`를 실행하세요.

### CFW

이 명령들은 중지된 머신에서 머신 자체의 번들로, Launchpad의 도우미를 통해 실행됩니다. 다른 프로세스가 디스크를 열고 있으면 그 이름(`12925 tail`)을 표시하며 거부합니다.

| 명령 | 동작 |
| --- | --- |
| `cfw install <name>` | CFW 설치. 해당하는 경우 도우미가 임시 작업 파일을 가상 머신 보관함의 외장 볼륨에 둡니다 |
| `cfw update-environment <name>` | 번들의 게스트 리소스(vphoned, 훅 dylib)를 다시 배포. 그 밖에는 아무것도 바뀌지 않습니다 |
| `cfw update-kernel <name>` | 머신의 현재 패치 선택으로 kernelcache를 다시 패치하고 Preboot에서 교체하며, 데이터는 유지합니다. 설치된 가상 머신에서 데이터를 유지하며 커널 패치를 바꾸는 방법이며, 복원 트리가 필요하지 않습니다 |

### 게스트

`guest` 명령과 `--wait`는 모든 시작에서 제공되는 머신의 `vphone.sock`을 통해 동작합니다. 2.0.9 이하의 번들은 창과 함께 시작한 머신에서만 이를 제공합니다.

| 명령 | 동작 |
| --- | --- |
| `guest send <name> <json>` | 원시 `vphone.sock` 요청 하나(tap, swipe, key, screenshot) |
| `guest rpc <name> <method> [params]` | 모든 vphoned 메서드. [`Research/vphoned_http_api.md`](../../../Research/vphoned_http_api.md)를 참고하세요. vphoned가 거부하면 stderr의 마지막 줄이 JSON 형식의 오류 객체입니다(`code`, `message`, `results`, `reason` …) |
| `guest push <name> <local> <guest-path> [--mode <octal>]` | Mac의 파일을 게스트로 복사. vphoned를 통해 스트리밍하므로 `guest rpc`의 1 MiB JSON 한 줄 제한을 받지 않습니다. 바이너리와 IPA에 사용하세요. `/`로 끝나는 게스트 경로는 파일 이름을 유지하며, 모드의 기본값은 Mac 파일의 권한입니다 |
| `guest pull <name> <guest-path> <local>` | 게스트 파일을 Mac으로 스트리밍 복사. `local`은 폴더여도 됩니다. 파일은 완료된 뒤에만 `local`을 대체합니다 |
| `guest unlock <name> [--passcode <code>] [--timeout <seconds>]` | 어떤 상태였든 화면을 켜고 게스트의 잠금을 해제합니다(vphoned `screen.unlock`). `--passcode`는 게스트에 암호가 있을 때만 필요합니다 |

### vphone-cli 실행

| 명령 | 동작 |
| --- | --- |
| `exec [--bundle <version>] <vphone-cli arguments>` | 기본 번들 또는 지정한 버전의 `vphone-cli`를 실행하고 출력을 스트리밍합니다. `--bundle`은 맨 앞에 와야 합니다 |

## 머신 만들기

`vm create`는 `--bundle <version>` 또는 기본 번들에 연결하여 New Machine 파이프라인을 실행합니다. 머신은 템플릿에서 복제되며, 템플릿이 없으면 먼저 빌드합니다(2.9). `--no-template`이면 단독으로 복원합니다.

```sh
vphone-launchpad-cli vm create rt-e --block system-debugserver-cfw-install
```

| 옵션 | 동작 |
| --- | --- |
| `--bundle <version>` | 기본 번들 대신 설치된 이 버전에 머신을 연결 |
| `--device <product-type>` | 다른 기기 만들기. 아래의 '다른 기기'를 참고하세요 |
| `--preset <preset>` | 프리셋 이름 또는 프리셋 plist 경로(2.14). 머신이 그 사본을 보관합니다 |
| `--block <patch>`, `--allow <patch>` | 프리셋의 패치 하나를 끄거나 켭니다. 반복할 수 있습니다. 아래의 '패치 재정의'를 참고하세요 |
| `--no-template` | 템플릿을 복제하지 않고 머신을 단독으로 복원. 경량화 스위치 중 `--slim`만 적용됩니다. `on`(기본값)이면 머신이 자체 설정 부팅을 거쳐 설정 지원을 건너뛰고, `off`이면 설정 지원부터 시작합니다 |
| `--slim on\|off`, `--trim …`, `--keep-languages …`, `--service-profile …`, `--remove-apps …`, `--keep-apps …` | `vphone-cli vm create`의 경량화 스위치. New Machine과 마찬가지로 Apple 계정은 trimmed 서비스 프로필과 함께 꺼집니다 |
| `--accounts-off` | 받기는 하지만 아무것도 바꾸지 않습니다 |
| `--ipsw <path>` | 선택 사항. New Machine의 ipsw 필드처럼, 이 경로로 kernelcache 믹스를 준비하는 2.12.0 번들에만 전달됩니다. 2.12.1 번들은 네이티브로 추출합니다 |
| `--from <step>` | 생성을 시작할 때의 옵션으로 특정 단계(`findTemplate` … `firstBoot`)부터 다시 시도 |

파서는 `--iphone-source`, `--cloudos-source`, `--cpu`, `--memory`, `--disk-size`, `--network`, `--keep-artifacts`, `--no-wait`도 받습니다. `vphone-launchpad-cli help`를 참고하세요.

결과에는 템플릿, 이번 생성에서 템플릿을 빌드했는지 여부, 사용한 패치가 표시됩니다.

### 다른 기기

| `--device` | 게스트 | 참고 |
| --- | --- | --- |
| iPad 제품 유형 | iPadOS | [iPadOS 게스트](../firmware/ipados.md)를 참고하세요 |
| `AppleTV5,3` | Apple TV HD | 항상 경량화 없이 단독으로 복원됩니다. `--preset`으로 다른 프리셋을 지정하지 않으면 `tvos` 프리셋을 사용합니다 |
| `AppleTV14,1` | Apple TV 4K(3세대) | 위와 같으며, `tvos-4k` 프리셋과 카탈로그 OTA의 사용자 영역을 사용합니다 |
| `AppleTV18,1` | Apple TV 4K(4세대) | Launchpad와 Core Bundle 2.13이 필요합니다. `tvos-4k`를 선택하고, 경량화 없이 단독으로 복원하며, Apple TV HD 기반 위에 전체 OTA로 tvOS 27.2 베타(`24K120`)를 사용합니다. 생성에는 macOS 27이 필요합니다. 실제 부팅은 아직 확인되지 않았습니다. [초기 구동 기록](../../../Research/Firmware/tvos_support.md#apple-tv-4k-4th-generation)을 참고하세요 |

다음 두 경우에는 도우미를 통해 일부 단계를 root로 실행합니다.

- `--preset minimal`(Minimal: 순정 부트 체인, 커널, TXM을 사용하고 복원 전에 시스템을 사용자화)도 경량화 없이 단독으로 복원되며, `fw patch`는 도우미를 통해 root로 실행됩니다. Userspace debugging 상자(`vphone-cli fw patches`의 Features 아래 `userspace-debugging`)는 그 상자가 나열하는 각 패치에 대한 `--allow`에 해당합니다. Trusted darwinOS environment 상자(`trusted-darwinos`, 즉 `--allow filesystem-exp-trusted_darwinos`)는 iPhone 또는 iPad를 trusted darwinOS로 복원하고 cloudOS의 cryptexctl을 추가하므로, 게스트가 실행 중일 때 cryptex를 설치할 수 있습니다(VM 창의 Apps › Install Cryptex…, [Cryptex](../machines/cryptexes.md) 참조). 상자 아래 설명에 그 영향이 적혀 있습니다. 이후 게스트는 Restricted Execution Mode를 강제하고, 리서치 보드 게스트(cloudOS 26.5~26.7)는 개발자 모드를 켤 수 없으며, 상자를 바꾼 내용은 다시 복원해야만 적용됩니다.
- cloudOS에 vphone600 구성 요소가 없는 머신(해당 릴리스 자체의 cloudOS, Watch, iOS 18 게스트)은 `fw kernelcache`가 사용자 권한으로 kernelcache 믹스를 빌드합니다. Core Bundle 2.17 이하에서는 준비만 하고 도우미가 root로 링크합니다.

### 패치 재정의

`--block <patch>`와 `--allow <patch>`는 `vphone-cli fw patches`가 나열하는 식별자를 패치마다 하나씩 받습니다.

```sh
vphone-launchpad-cli exec fw patches --preset <preset>
```

Launchpad는 생성 작업의 번들에서 그 카탈로그를 읽고, 어느 패치 세트에도 선언되지 않은 식별자나 차단과 허용이 동시에 지정된 식별자를 거부하며, `fw set-patches`처럼 프리셋과 다른 것만 보관합니다. 그런 다음 New Machine과 같은 방식으로 나눕니다.

- **부트 체인 패치**(AVPBooter, iBSS, iBEC, LLB, TXM, kernelcache, DeviceTree …)는 템플릿 키에 포함됩니다. Find Template은 그 패치로 빌드된 템플릿을 찾고, 템플릿 빌드는 `fw patch` 전에 `fw set-patches`로 이를 기록합니다.
- **게스트 패치**는 템플릿에 포함되지 않습니다. 복제본이 `fw set-patches`로 이를 기록하고, Apply Guest Patches 단계가 첫 부팅 전에 도우미를 통해 `cfw update-environment`로 적용합니다. 따라서 게스트 재정의만 있으면 일반 템플릿을 재사용합니다.

결과의 `patches` 객체에는 프리셋, `blocked`와 `allowed` 재정의, 그리고 복제본에 적용된 `guest` 재정의가 들어 있습니다. `--no-template`이면 모든 재정의가 머신 자체의 복원에 들어갑니다. `--from`은 `--block`과 `--allow`를 거부합니다. 재시도는 생성 작업의 패치를 그대로 유지합니다.

## 결과의 번들 필드

| 명령 | 필드 | 의미 |
| --- | --- | --- |
| `status` | `defaultBundle` | 기본 버전. 이전 스크립트를 위해 `activeBundle`에도 같은 값이 들어 있습니다 |
| `bundle list` | `default` | 이 버전이 기본 버전임. 이전 스크립트를 위해 `active`에도 같은 값이 들어 있습니다 |
| `bundle list` | `machines` | 이 버전에 연결된 머신의 이름 |
| `vm list` | `bundle` | 머신의 호스트 프로그램이 실행되는 버전 |
| `vm list` | `guestEnvironmentBundle` | 게스트 환경이 마지막으로 설치된 버전. 알 수 없으면 `null` |
| `vm list` | `bootChainBundle` | 부트 체인을 빌드한 버전. Launchpad가 이를 기록하기 전에 만든 머신은 `null` |
| `vm create`, `cfw …`, `exec` | `bundle` | 명령이 실행된 버전 |

`guestEnvironmentBundle`이 `bundle`과 다르면 호스트와 게스트가 서로 다른 빌드에서 온 것입니다. `cfw update-environment`로 게스트를 맞추세요.

## 터치 좌표와 디스플레이 형상

`guest send`의 터치 좌표는 `t:screenshot`이 반환하는 **똑바로 세운 전체 스크린샷**을 기준으로 합니다. 4분의 1 회전하면 너비와 높이가 바뀝니다. 호스트는 GUI와 헤드리스 시작 모두에서 그 지점을 고정 패널 HID 좌표로 변환합니다. 스와이프는 시작 시점에 측정한 형상을 유지합니다. 스크린샷 도중 형상이 바뀌면, 입력 좌표가 모호한 이미지 대신 오류가 반환됩니다.

회전된 좌표의 불일치를 진단하려면 형상을 읽으세요.

```sh
vphone-launchpad-cli guest send <name> '{"t":"display.geometry"}'
```

호스트에 구성된 픽셀 크기와 캡처된 픽셀 크기, 그리고 실시간 디스플레이 뷰의 경계, 회전, 화면비를 유지한 그리기 영역, 포인터/터치 경로를 반환하며, 입력이나 디스플레이 상태는 바꾸지 않습니다. `capture_pixels`는 호스트의 원시 프레임이고, `screenshot_pixels`와 `input_orientation`은 입력 좌표를 나타냅니다. 이를 `device.screen`, `display.orientation`, 그리고 게스트가 실제로 받는 이벤트와 비교하세요.

## 연결 방식

CLI는 `~/Library/Application Support/vphone-launchpad/control.sock`의 Unix 소켓(모드 0600, 같은 사용자에게만 제공)으로 실행 중인 Launchpad와 통신합니다. CLI에는 권한도 자체 상태도 없습니다. 번들은 Launchpad의 도우미를 통해 설치되며, 각 머신은 자신의 Core Bundle에 있는 `vphone-cli`로 실행됩니다. 네트워크에서 수신하는 것은 없습니다. 다른 컴퓨터에서 사용하려면 ssh로 접속하세요.

## 함께 보기

- [코어 번들과 로컬 빌드](core-bundles.md)
- [번들 통합](bundle-integration.md)
- [생성 및 실행](../machines/create-and-run.md)
