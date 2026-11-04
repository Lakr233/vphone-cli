# 가상 머신 생성 및 실행

터미널에서 `vphone-cli`로 가상 머신을 만들고, 시작하고, 중지합니다. Launchpad 없이 작업하거나, 가상 머신 생성을 스크립트로 처리하거나, 과정의 한 단계를 다시 실행해야 할 때 이 페이지를 사용하세요.

Launchpad는 `VPhone.bundle` 안의 `vphone-cli`로 가상 머신을 제어하며, 같은 명령을 터미널에서도 사용할 수 있습니다.

```sh
vphone-cli vm list
vphone-cli vm launch myphone
vphone-cli vm export myphone --out myphone.tzst
```

가상 머신은 `~/.vphone/`에 저장됩니다. 전체 명령은 `vphone-cli <group> --help`로 확인하세요.

## 가상 머신 만들기

iPhone17,3 복원 IPSW와 호환되는 PCC/cloudOS IPSW가 로컬 경로나 URL로 필요합니다. 지금까지 검증된 조합은 [호환성](../firmware/compatibility.md)에 있습니다.

```sh
vphone-cli host preflight
vphone-cli vm create myphone \
  --iphone-source /path/to/iPhone17,3_Restore.ipsw \
  --cloudos-source /path/to/cloudOS.ipsw
```

생성은 준비, 펌웨어 패치, 온라인 DFU 복원, 호스트에서 마운트한 CFW 설치, 첫 GUI 부팅 순서로 진행됩니다.

- 복원 티켓을 받기 위해 네트워크 연결이 필요합니다.
- CFW 설치에는 root 권한이 필요합니다. 번들에는 인증 대화상자나 권한 도우미가 없으므로 root 권한은 사용자가 직접 제공해야 합니다.
- 기본 가상 디스크 크기는 64 GB입니다.

성공하면 `[+] First boot: vphoned ping succeeded.`와 `CFW VM created; vphoned connected. Guest user environment is untouched.`가 출력되며 끝납니다. 그런 다음 가상 머신은 중지됩니다. ping은 그 부팅 중에 vphoned가 응답했다는 것을 확인하며, 실행 중인 가상 머신은 남지 않습니다.

### 옵션

| 옵션 | 효과 |
| --- | --- |
| `--iphone-version`, `--iphone-build` | `--iphone-source`를 넘기는 대신 `fw prepare`처럼 `--device`(기본값 iPhone17,3)에 맞는 iPhone IPSW를 찾습니다. |
| `--cloudos-source` 생략 | `fw catalog`에 표시되는 대로, 카탈로그가 해당 릴리스에 권장하는 cloudOS를 사용합니다. |
| `--disk-size` | 가상 디스크 크기(GB, 기본값 64). |
| `--preset` | 패치 프리셋 이름 또는 프리셋 plist 경로(기본값 `standard`). 각 프리셋이 적용하는 패치는 `fw patches`로 확인하세요. |
| `--cpu` | CPU 코어 수(기본값 8). |
| `--memory` | 메모리(MB, 기본값 8192). |
| `--network` | `nat`(기본값), `bridged`, `tunnel`, `none`. |
| `--unlock-at-startup` | `on` 또는 `off`(기본값). |
| `--no-template` | 템플릿에서 복제하지 않고 가상 머신을 단독으로 만듭니다. |
| `--skip-first-boot` | 마지막 부팅을 생략합니다. 호출하는 쪽에서 가상 머신을 직접 부팅할 때 사용합니다. |
| `--bootstrap roothide` | 첫 부팅 중에 패키지 환경을 설치합니다. [패키지 환경](package-environment.md)을 참고하세요. |
| `--keep-artifacts` | 준비 과정에서 만든 큰 복원 트리를 보존합니다. 디스크 공간이 중요하면 생략하세요. |

`--cpu`, `--memory`, `--network`, `--unlock-at-startup`은 새 가상 머신에 같은 이름의 `vm config` 설정을 지정합니다.

### 템플릿

기본적으로 파이프라인은 [템플릿](../storage/templates.md)을 만들고 그 템플릿에서 가상 머신을 복제합니다. 이후 기기, iOS 및 cloudOS 빌드, 프리셋, 디스크 크기가 같은 `vm create`는 다시 복원하지 않고 그 템플릿에서 복제합니다. 가상 머신을 단독으로 만들려면 `--no-template`을 넘기세요.

### 패치와 펌웨어 준비

펌웨어 작업 흐름에는 모드가 하나뿐입니다. 부트 체인과 게스트 시스템을 패치하고 vphoned를 설치하며, 사용자 환경은 비워 둡니다. Sileo, apt, TrollStore, SSH 서버, VNC 서버는 설치하지 않습니다. 적용할 패치는 패치 프리셋이 선택하며, `vphone-cli fw set-patches`에 `--block` 또는 `--allow`를 지정하면 개별 패치를 끄거나 켤 수 있습니다.

패치하기 전에 생성 과정에서 펌웨어를 준비합니다. 임시 cloudOS 복원으로 GPU 드라이버를 얻고, vphone600 구성 요소가 없는 cloudOS에는 다시 빌드한 kernelcache가 필요합니다. [펌웨어 준비](../firmware/firmware-preparation.md)를 참고하세요. 목록 하나로 여러 머신을 만들려면 [여러 머신 만들기](../storage/many-machines.md)를 참고하세요.

## 시작 및 중지

```sh
vphone-cli vm launch myphone  # start the VM window and keep it running
vphone-cli vm stop myphone    # run from another terminal to stop it
```

`vm launch`는 vphoned를 기다리지 않고 게스트를 시작하며, 데몬은 부팅 중에 연결됩니다. 가상 머신 창과 메뉴에서 홈 버튼과 전원 버튼, 앱 설치, 파일 탐색을 사용할 수 있습니다. `vm launch --headless`는 가상 머신 창과 메뉴 막대 없이 부팅합니다.

다음은 모두 게스트를 정상적으로 종료합니다(vphoned `system.shutdown`).

- 가상 머신 창 닫기
- ⌘Q
- `vm stop`
- `vm launch`를 실행한 터미널에서 Control-C

가상 머신은 게스트가 멈추면 종료되며, 15초가 지나도 멈추지 않으면 그때 종료됩니다. DFU 상태이거나 아직 시작 중인 게스트처럼 vphoned가 응답할 수 없는 게스트는 전원을 뽑은 것처럼 즉시 꺼집니다. Control-C를 한 번 더 누르면 기다리지 않고 끕니다.

`vm stop`은 머신 자신의 프로세스인 `vphone-vm`과 Virtualization의 가상 머신 서비스에만 신호를 보냅니다. 크기를 측정하는 Launchpad, Spotlight, 백업 도구처럼 디스크를 열고 있는 다른 프로그램은 이름만 표시하고 그대로 둡니다.

## 제어 소켓

실행 중인 각 가상 머신은 자신의 폴더에 제어 소켓 `vphone.sock`(`~/.vphone/machines/<name>/vphone.sock`)을 둡니다. JSON 한 줄을 보내면 JSON 한 줄이 돌아옵니다. 연결은 동시에 처리되며, 창이 없는 가상 머신에도 소켓이 있습니다. 이 경우 `tap`과 `swipe`는 vphoned의 터치 주입으로 처리되고 화면 이미지는 게스트에서 가져옵니다.

`tap`, `swipe`, `key`, `screenshot` 외에도 `rpc` 요청으로 [API 레퍼런스](../../../Research/vphoned_http_api.md)에 있는 모든 vphoned 메서드를 호출할 수 있습니다.

```sh
printf '%s\n' '{"t":"rpc","method":"device.info","params":{}}' | nc -U ~/.vphone/machines/myphone/vphone.sock
```

예를 들어 `input.key`에 `{"name":"cmd+v"}`를 보내면 붙여 넣고, `input.type`은 텍스트를 입력합니다. 이 작업 흐름은 SSH나 VNC 엔드포인트를 설치하지 않습니다. HTTP와 WebSocket으로 접근하려면 [자동화 API](automation-api.md)를 참고하세요.

## 각 단계를 직접 실행하기

한 단계를 조사하거나 다시 실행할 때 사용합니다. `restore`가 통신하는 동안 DFU 부팅을 계속 실행해 두세요.

```sh
vphone-cli vm new myphone
vphone-cli fw prepare myphone \
  --iphone-source /path/to/iPhone17,3_Restore.ipsw \
  --cloudos-source /path/to/cloudOS.ipsw
vphone-cli fw patch myphone

vphone-cli vm launch myphone --dfu &
vphone-cli restore myphone
vphone-cli vm stop myphone

vphone-cli cfw install myphone
vphone-cli vm launch myphone
```

온라인 복원은 프로세스 안에서 티켓을 받습니다. 오프라인 복원은 `vphone-cli restore --help`에서 `--get-shsh`와 `--offline`을 확인하세요. 수동 흐름에서는 `vm create`가 수행하는 첫 부팅 ping 확인을 실행하지 않습니다.

## 함께 보기

- [템플릿](../storage/templates.md)
- [기기 이름과 시계](device-name-and-clock.md)
- [보관함과 백업](../storage/library-and-backups.md)
- [디스크 공간 공유](../storage/sharing-disk-space.md)
