<div align="right"><strong>🇰🇷한국어</strong> | <strong><a href="./README_ja.md">🇯🇵日本語</a></strong> | <strong><a href="./README_zh.md">🇨🇳中文</a></strong> | <strong><a href="./README.md">🇬🇧English</a></strong></div>

# vphone-cli

PCC 리서치 VM 인프라와 Apple의 Virtualization.framework를 사용하여 가상 iPhone(iOS 26)을 부팅합니다.

![poc](./demo.png)

## 테스트된 환경

| Host          | iPhone             | CloudOS       |
| ------------- | ------------------ | ------------- |
| Mac16,12 26.3 | `17,3_26.1_23B85`  | `26.1-23B85`  |
| Mac16,12 26.3 | `17,3_26.3_23D127` | `26.1-23B85`  |
| Mac16,12 26.3 | `17,3_26.3_23D127` | `26.3-23D128` |

## 사전 요구 사항

**호스트 OS:** PV=3 가상화를 위해 macOS 15+(Sequoia)가 필요합니다.

**SIP 및 AMFI 비활성화** — Private Virtualization.framework 권한을 사용하기 위해 필요합니다.

복구 모드(전원 버튼 길게 누르기)로 부팅한 후 터미널을 엽니다:

```bash
csrutil disable
csrutil allow-research-guests enable
```

macOS로 다시 시작한 후:

```bash
sudo nvram boot-args="amfi_get_out_of_my_way=1 -v"
```

한 번 더 재시작합니다.

**의존성(Dependencies) 설치:**

```bash
brew install ideviceinstaller wget gnu-tar openssl@3 ldid-procursus sshpass keystone autoconf automake pkg-config libtool
```

**Submodules** — 이 저장소는 리소스 아카이브를 위해 git submodule을 사용합니다. 클론 시 다음 명령어를 사용하세요:

```bash
git clone --recurse-submodules https://github.com/Lakr233/vphone-cli.git
```

## 초기 설정

```bash
make setup_machine            # "First Boot"까지의 전체 과정 자동화 (복원/Ramdisk/커스텀 펌웨어 포함)

# 수동 단계(위 명령과 동일):
make setup_tools              # brew 의존성 설치, trustcache + libimobiledevice 빌드, Python venv 생성
source .venv/bin/activate
```

`make setup_machine`을 사용하더라도 **복구 모드에서의 SIP/research-guest 설정**과 "First Boot" 명령어를 입력하기 위한 대화형 VM 콘솔 작업은 여전히 수동으로 필요합니다. 이 스크립트는 보안 설정 여부를 별도로 검증하지 않습니다.

## 빠른 시작

```bash
make build                    # vphone-cli 빌드 및 서명
make vm_new                   # vm/ 디렉토리 생성 (ROM, 디스크, SEP 저장소)
make fw_prepare               # IPSW 다운로드, 추출, 병합, manifest 생성
make fw_patch                 # 부트 체인 패치 (6개 구성 요소, 41개 이상의 수정 사항)
```

## 복원

복원 프로세스를 위해 **두 개의 터미널**이 필요합니다. 터미널 2를 사용하는 동안 터미널 1을 계속 실행 상태로 두세요.

```bash
# 터미널 1
make boot_dfu                 # VM을 DFU 모드로 부팅 (계속 실행 유지)
```

```bash
# 터미널 2
make restore_get_shsh         # SHSH blob 가져오기
make restore                  # idevicerestore를 통해 펌웨어 플래싱
```

## 램디스크 및 커스텀 펌웨어

터미널 1의 DFU 부팅을 중단(Ctrl+C)한 다음, 램디스크를 위해 다시 DFU로 부팅합니다:

```bash
# 터미널 1
make boot_dfu                 # 계속 실행 유지
```

```bash
# 터미널 2
make ramdisk_build            # 서명된 SSH 램디스크 빌드
make ramdisk_send             # 장치로 전송
```

램디스크가 실행되면(출력에 `Running server`가 표시됨), **세 번째 터미널**을 열어 iproxy 터널을 시작한 후, 터미널 2에서 커스텀 펌웨어를 설치합니다:

```bash
# 터미널 3 — 계속 실행 유지
iproxy 2222 22
```

```bash
# 터미널 2
make cfw_install
```

## 첫 부팅

터미널 1의 DFU 부팅을 중단(Ctrl+C)한 후 다음을 실행합니다:

```bash
make boot
```

그러면 VM에서 **direct console**이 나타납니다. `bash-4.4#`이 보이면 엔터를 누르고 다음 명령어를 실행하여 쉘 환경을 초기화하고 SSH 호스트 키를 생성하세요:

```bash
export PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/bin/X11:/usr/games:/iosbinpack64/usr/local/sbin:/iosbinpack64/usr/local/bin:/iosbinpack64/usr/sbin:/iosbinpack64/usr/bin:/iosbinpack64/sbin:/iosbinpack64/bin'

mkdir -p /var/dropbear
cp /iosbinpack64/etc/profile /var/profile
cp /iosbinpack64/etc/motd /var/motd

# generate SSH host keys (required for SSH to work)
dropbearkey -t rsa -f /var/dropbear/dropbear_rsa_host_key
dropbearkey -t ecdsa -f /var/dropbear/dropbear_ecdsa_host_key

shutdown -h now
```

> **참고:** 호스트 키 생성 단계를 거치지 않으면 dropbear(SSH 서버)가 연결을 수락하더라도 SSH 핸드셰이크를 수행할 키가 없어 즉시 연결을 종료합니다.

## 이후 부팅

```bash
make boot
```

별도의 터미널에서 iproxy 터널을 시작합니다:

```bash
iproxy 22222 22222   # SSH
iproxy 5901 5901     # VNC
iproxy 5910 5910     # RPC
```

다음을 통해 연결합니다:

- **SSH:** `ssh -p 22222 root@127.0.0.1` (password: `alpine`)
- **VNC:** `vnc://127.0.0.1:5901`
- [**RPC:**](http://github.com/doronz88/rpc-project) `rpcclient -p 5910 127.0.0.1`

## 전체 Make 타겟

전체 목록을 보려면 `make help`를 실행하세요. 주요 타겟은 다음과 같습니다:

| 타겟                | 설명                         |
| ------------------- | ---------------------------- |
| `build`             | vphone-cli 빌드 및 서명      |
| `vm_new`            | VM 디렉토리 생성             |
| `fw_prepare`        | IPSW 다운로드 및 병합        |
| `fw_patch`          | 부트 체인 패치               |
| `boot` / `boot_dfu` | VM 부팅 (GUI / DFU headless) |
| `restore_get_shsh`  | SHSH blob 가져오기           |
| `restore`           | 펌웨어 플래싱                |
| `ramdisk_build`     | SSH 램디스크 빌드            |
| `ramdisk_send`      | 장치에 램디스크 전송         |
| `cfw_install`       | CFW mods 설치                |
| `clean`             | 빌드 아티팩트 제거           |

## FAQ

> **무엇보다 먼저 — `git pull`을 실행하여 최신 버전인지 확인하세요.**

**Q: 실행하려고 하면 `zsh: killed ./vphone-cli` 오류가 발생합니다.**

AMFI가 비활성화되지 않았습니다. boot-arg를 설정하고 재시작하세요:

```bash
sudo nvram boot-args="amfi_get_out_of_my_way=1 -v"
```

**Q: 시스템 앱(App Store, 메시지 등)을 다운로드하거나 설치할 수 없습니다.**

iOS 초기 설정 시 지역을 **일본** 또는 **유럽 연합**으로 선택하지 **마세요**. 이 지역에서는 추가적인 규제 검사(사이드로딩 공개, 카메라 셔터음 등)가 적용되는데, 가상 머신은 이러한 요건을 충족할 수 없어 시스템 앱의 다운로드 및 설치가 불가능합니다. 이 문제를 피하려면 다른 지역(예: 미국)을 선택하세요.

**Q: "Press home to continue" 화면에서 멈췄습니다.**

VNC(`vnc://127.0.0.1:5901`)로 접속하여 화면의 아무 곳이나 우클릭(Mac 트랙패드에서는 두 손가락 클릭)하세요. 이것이 홈 버튼 누르기를 시뮬레이션합니다.

**Q: SSH가 연결되자마자 종료됩니다 (`Connection closed by 127.0.0.1`).**

첫 부팅 시 Dropbear 호스트 키가 생성되지 않았습니다. VNC나 `make boot` 콘솔을 통해 연결하여 다음을 실행하세요:

```bash
export PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/bin/X11:/usr/games:/iosbinpack64/usr/local/sbin:/iosbinpack64/usr/local/bin:/iosbinpack64/usr/sbin:/iosbinpack64/usr/bin:/iosbinpack64/sbin:/iosbinpack64/bin'
mkdir -p /var/dropbear
dropbearkey -t rsa -f /var/dropbear/dropbear_rsa_host_key
dropbearkey -t ecdsa -f /var/dropbear/dropbear_ecdsa_host_key
killall dropbear
dropbear -R -p 22222
```

**Q: 최신 iOS 버전으로 업데이트할 수 있나요?**

네. `fw_prepare`를 원하는 버전의 IPSW URL로 덮어쓰세요:

```bash
export IPHONE_SOURCE=/path/to/some_os.ipsw
export CLOUDOS_SOURCE=/path/to/some_os.ipsw
make fw_prepare
make fw_patch
```

저희의 패치는 정적 오프셋이 아닌 바이너리 분석을 통해 적용되므로, 최신 버전에서도 작동할 것입니다. 만약 문제가 발생하면 AI에게 도움을 요청하세요.

## 감사 인사

- [wh1te4ever/super-tart-vphone-writeup](https://github.com/wh1te4ever/super-tart-vphone-writeup)
