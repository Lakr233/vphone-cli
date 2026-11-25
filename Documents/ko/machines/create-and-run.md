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

성공하면 `[+] First boot: vphoned ping succeeded.`와 `CFW VM created; vphoned connected. Guest user environment is untouched.`가 출력되며 끝납니다. 터미널에서는 [진행 화면](#진행-화면과-로그)이 이 두 줄을 대신합니다. First boot check 줄에 `First boot: vphoned ping succeeded.`가 표시되고, 마지막 줄은 `Done in`과 전체 소요 시간입니다. 그런 다음 가상 머신은 중지됩니다. ping은 그 부팅 중에 vphoned가 응답했다는 것을 확인하며, 실행 중인 가상 머신은 남지 않습니다.

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
| `--log <file>` | 일반 출력을 파일에도 씁니다. [진행 화면과 로그](#진행-화면과-로그)를 참고하세요. |

`--cpu`, `--memory`, `--network`, `--unlock-at-startup`은 새 가상 머신에 같은 이름의 `vm config` 설정을 지정합니다.

### 진행 화면과 로그

터미널에서 `vm create`는 줄을 하나씩 출력하는 대신 진행 화면을 그립니다.

- **단계:** 단계마다 한 줄에 경과 시간을 표시합니다. 시작 전에는 `○`, 끝나면 `✓`, 실패하면 `✗`가 붙습니다. 끝난 단계는 같은 줄에 결과를 남깁니다.
- **실행 중인 단계:** 최근 작업 세 개, 현재 작업, 진행 막대를 표시합니다. 막대는 다운로드와 복원에서는 백분율을, 패치에서는 개수를 보여 줍니다.
- **패치:** 펌웨어 구성 요소 하나의 패치가 끝나면 그 패치 목록이 진행 영역 위에 남습니다. 패치마다 이름과 변경 전후의 값을 표시하고, N곳을 더 바꿨다면 `+N`을 붙입니다. `~`는 바뀐 값, `+`는 추가된 값, `-`는 제거된 값입니다.
- **경고와 오류:** 최근 경고 세 개가 아래쪽에 남습니다. 생성이 실패하면 일반 출력의 마지막 15줄이 화면 뒤에 이어집니다.

다음 경우에는 `vm create`가 화면 대신 메시지마다 한 줄씩 일반 출력을 냅니다.

- 출력이 파이프나 파일처럼 터미널이 아닐 때
- 더 자세한 내용을 보려고 `-v`, `-vv`, `-vvv`를 지정했을 때
- `vm create-bulk`가 실행할 때

`--log <file>`은 화면 표시 여부와 관계없이 일반 출력과 모든 패치 기록을 파일에도 씁니다. 파일이 이미 있으면 끝에 이어 씁니다. 새로 만든 파일은 본인만 읽을 수 있습니다. 생성은 root로 실행될 수 있으므로 심볼릭 링크, 하드 링크가 둘 이상인 파일, 다른 사용자의 파일은 거부합니다.

```sh
vphone-cli vm create myphone \
  --iphone-source /path/to/iPhone17,3_Restore.ipsw \
  --cloudos-source /path/to/cloudOS.ipsw \
  --log myphone-create.log
```

### 템플릿

기본적으로 파이프라인은 [템플릿](../storage/templates.md)을 만들고 그 템플릿에서 가상 머신을 복제합니다. 이후 기기, iOS 및 cloudOS 빌드, 프리셋, 디스크 크기가 같은 `vm create`는 다시 복원하지 않고 그 템플릿에서 복제합니다. 가상 머신을 단독으로 만들려면 `--no-template`을 넘기세요.

### 패치와 펌웨어 준비

펌웨어 작업 흐름에는 모드가 하나뿐입니다. 부트 체인과 게스트 시스템을 패치하고 vphoned를 설치하며, 사용자 환경은 비워 둡니다. Sileo, apt, TrollStore, SSH 서버, VNC 서버는 설치하지 않습니다. 적용할 패치는 패치 프리셋이 선택하며, `vphone-cli fw set-patches`에 `--block` 또는 `--allow`를 지정하면 개별 패치를 끄거나 켤 수 있습니다.

패치하기 전에 생성 과정에서 펌웨어를 준비합니다. 임시 cloudOS 복원으로 GPU 드라이버를 얻고, vphone600 구성 요소가 없는 cloudOS에는 다시 빌드한 kernelcache가 필요합니다. [펌웨어 준비](../firmware/firmware-preparation.md)를 참고하세요. 목록 하나로 여러 머신을 만들려면 [여러 머신 만들기](../storage/many-machines.md)를 참고하세요.

## 시작 및 중지

```sh
vphone-cli vm launch myphone  # start the VM window and keep it running
vphone-cli vm launch myphone --detach  # start it in its own session and return once vphoned answers
vphone-cli vm stop myphone    # run from another terminal to stop it
```

`vm launch`는 vphoned를 기다리지 않고 게스트를 시작하며, 데몬은 부팅 중에 연결됩니다. 가상 머신 창과 메뉴에서 홈 버튼과 전원 버튼, 앱 설치, 파일 탐색을 사용할 수 있습니다. `vm launch --headless`는 가상 머신 창과 메뉴 막대 없이 부팅합니다.

`vm launch --detach [--timeout <seconds>]`는 가상 머신을 자체 세션에서 시작하므로 터미널을 닫아도 멈추지 않으며, vphoned를 기다립니다. `pid <n>`과 `log <path>`를 출력하고, 가상 머신의 출력을 `~/Library/Logs/vphone-launchpad/<name>.log`(기본값이 아닌 라이브러리에서는 `<name>-<digest>.log`. 시작할 때마다 비워지며, `vphone-launchpad-cli vm log <name>`가 읽는 파일입니다)에 덧붙인 뒤 `vphoned answered after <n>s`를 출력하고 0으로 종료합니다. 가상 머신이 먼저 종료되거나, 로그에 커널 패닉이 표시되거나, vphoned가 응답하기 전에 `--timeout`(기본값 300)이 지나면 1로 종료합니다. 패닉이나 타임아웃이 발생하면 가상 머신은 계속 실행되므로 `vphone-cli vm stop <name>`으로 중지하세요. 이미 사용 중인 머신은 거부되어 1로 종료하며, `--detach`는 `--dfu`와 함께 사용할 수 없습니다.

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

예를 들어 `input.key`에 `{"name":"cmd+v"}`를 보내면 붙여 넣고, `input.type`은 텍스트를 입력합니다. 이 작업 흐름은 SSH나 VNC 엔드포인트를 설치하지 않습니다. HTTP와 WebSocket으로 접근하려면 [자동화 API](automation-api.md)를 참고하세요. 게스트의 메모리를 저장하려면 `memory.dump`를 보냅니다. [메모리 덤프](memory-dumps.md)를 참고하세요.

## 일시 정지 및 재개

일시 정지하면 게스트가 그 자리에서 멈춥니다. 앱, 시계, 네트워크 연결은 재개할 때까지 기다리며, 그동안 Mac의 프로세서는 쓰이지 않습니다. 게스트는 메모리를 유지하지만 가상 머신이 실행되는 동안에만 그렇습니다. 일시 정지 상태는 저장되지 않습니다.

- 가상 머신 창에서 **Device > Pause Guest**를 선택하고, 계속하려면 **Device > Resume Guest**를 선택합니다.
- 터미널에서는 `vphone-cli vm pause myphone`과 `vphone-cli vm resume myphone`을 사용합니다.
- [제어 소켓](#제어-소켓)에서는 `{"t":"pause"}`와 `{"t":"resume"}`을 보냅니다.

게스트가 일시 정지된 동안에는 다음과 같습니다.

- 화면이 어두워지고 창의 부제목에 '일시 정지됨'이 표시됩니다. 탭, 키, 포인터는 게스트에 전달되지 않으므로 재개할 때 늦게 도착하는 입력이 없습니다.
- `rpc`, `screenshot`, `push`처럼 vphoned가 필요한 요청은 실패하며 게스트가 일시 정지되었다고 알립니다.
- 일시 정지할 때 이미 진행 중이던 요청(파일 `push` 등)은 게스트를 기다립니다. 일시 정지가 2분을 넘으면 실패하므로 재개한 뒤 다시 보내세요.
- [메모리 덤프](memory-dumps.md)는 그대로 저장할 수 있습니다. 게스트는 일시 정지된 채로 있고, 덤프에는 일시 정지한 시점의 게스트가 담깁니다.

게스트가 재개되면 시계가 다시 Mac의 시간으로 맞춰집니다. 일시 정지된 가상 머신을 위의 방법 중 하나로 중지하면 먼저 재개하므로, 게스트는 정상적으로 종료됩니다. 일시 정지가 길어지면 iPhone이 오래 잠자기 상태였을 때처럼 게스트가 연결해 있던 서버의 시간 제한을 넘을 수 있습니다.

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
