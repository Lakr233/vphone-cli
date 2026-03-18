<div align="right"><strong>🇰🇷한국어</strong> | <strong><a href="./README_ja.md">🇯🇵日本語</a></strong> | <strong><a href="./README_zh.md">🇨🇳中文</a></strong> | <strong><a href="../README.md">🇬🇧English</a></strong></div>

# vphone-cli

PCC 리서치 VM 인프라와 Apple의 Virtualization.framework를 사용하여 가상 iPhone(iOS 26)을 부팅합니다.

![poc](./demo.jpeg)

## 테스트된 환경

| Host          | iPhone                | CloudOS       |
| ------------- | --------------------- | ------------- |
| Mac16,12 26.3 | `17,3_26.1_23B85`     | `26.1-23B85`  |
| Mac16,12 26.3 | `17,3_26.3_23D127`    | `26.1-23B85`  |
| Mac16,12 26.3 | `17,3_26.3_23D127`    | `26.3-23D128` |
| Mac16,12 26.3 | `17,3_26.3.1_23D8133` | `26.3-23D128` |

## 펌웨어 변형

보안 우회 수준이 다른 3가지 패치 변형을 사용할 수 있습니다:

| 변형     | 부트 체인 |    CFW    | Make 타겟                          |
| -------- | :-------: | :-------: | ---------------------------------- |
| **일반** |  41 패치  | 10 페이즈 | `fw_patch` + `cfw_install`         |
| **개발** |  52 패치  | 12 페이즈 | `fw_patch_dev` + `cfw_install_dev` |
| **탈옥** | 112 패치  | 14 페이즈 | `fw_patch_jb` + `cfw_install_jb`   |

> JB 최종 설정(심볼릭 링크, Sileo, apt, TrollStore)은 `/cores/vphone_jb_setup.sh` LaunchDaemon을 통해 첫 번째 부팅 시 자동으로 실행됩니다. 진행 상황 확인: `/var/log/vphone_jb_setup.log`.

컴포넌트별 상세 분류는 [research/0_binary_patch_comparison.md](../research/0_binary_patch_comparison.md)를 참조하세요.

## 사전 요구 사항

**호스트 OS:** PV=3 가상화를 위해 macOS 15+(Sequoia)가 필요합니다.

**SIP/AMFI 설정** — Private Virtualization.framework 권한과 서명되지 않은 바이너리 워크플로우에 필요합니다.

복구 모드(전원 버튼 길게 누르기)로 부팅한 후 터미널을 열고, 다음 중 하나를 선택합니다:

- **방법 1: SIP 완전 비활성화 + AMFI boot-arg (가장 관대)**

  복구 모드에서:

  ```bash
  csrutil disable
  csrutil allow-research-guests enable
  ```

  macOS로 다시 시작한 후:

  ```bash
  sudo nvram boot-args="amfi_get_out_of_my_way=1 -v"
  ```

  한 번 더 재시작합니다.

- **방법 2: SIP은 대부분 활성 유지, 디버그 제한만 비활성화, [`amfidont`](https://github.com/zqxwce/amfidont) 또는 [`amfree`](https://github.com/retX0/amfree) 사용**

  복구 모드에서:

  ```bash
  csrutil enable --without debug
  csrutil allow-research-guests enable
  ```

  macOS로 다시 시작한 후:

  ```bash
  # amfidont 사용:
  xcrun python3 -m pip install amfidont
  sudo amfidont --path [PATH_TO_VPHONE_DIR]
  
  # 또는 amfree 사용:
  brew install retX0/tap/amfree
  sudo amfree --path [PATH_TO_VPHONE_DIR]
  ```

**의존성(Dependencies) 설치:**

```bash
brew install aria2 ideviceinstaller wget gnu-tar openssl@3 ldid-procursus sshpass keystone autoconf automake pkg-config libtool cmake
```

`scripts/fw_prepare.sh` 는 더 빠른 다중 연결 다운로드를 위해 `aria2c` 를 우선 사용하고, 필요하면 `curl` 또는 `wget` 으로 폴백합니다.

**Submodules** — 이 저장소는 리소스, Swift 의존성, `scripts/repos/` 아래 툴체인 소스를 git submodule로 관리합니다. 클론 시 다음 명령어를 사용하세요:

```bash
git clone --recurse-submodules https://github.com/Lakr233/vphone-cli.git
```

## 빠른 시작

```bash
make setup_machine            # "First Boot"까지의 전체 과정 자동화 (복원/Ramdisk/커스텀 펌웨어 포함)
# 옵션: NONE_INTERACTIVE=1 SUDO_PASSWORD=...
```

## 수동 설정

```bash
make setup_tools              # brew 의존성 설치(aria2c 포함), submodule 소스에서 trustcache + insert_dylib + libimobiledevice 빌드, Python venv 생성
make build                    # vphone-cli 빌드 및 서명
make vm_new                   # VM 디렉토리 및 매니페스트(config.plist) 생성
# 옵션: CPU=8 MEMORY=8192 DISK_SIZE=64
make fw_prepare               # IPSW 다운로드, 추출, 병합, manifest 생성
make fw_patch                 # 부트 체인 패치 (일반 변형)
# 또는: make fw_patch_dev     # 개발 변형 (+ TXM 권한/디버그 우회)
# 또는: make fw_patch_jb      # 탈옥 변형 (dev + 전체 보안 우회)
```

### VM 설정

v1.0부터 VM 설정은 `vm/config.plist`에 저장됩니다. VM 생성 시 CPU, 메모리, 디스크 크기를 설정하세요:

```bash
# 사용자 정의 설정으로 VM 생성
make vm_new CPU=16 MEMORY=16384 DISK_SIZE=128

# 부팅 시 config.plist에서 설정 자동 로드
make boot
```

매니페스트 파일은 모든 VM 설정(CPU, 메모리, 화면, ROM, 저장소)을 저장하며 [security-pcc의 VMBundle.Config 형식](https://github.com/apple/security-pcc)과 호환됩니다.

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

## 커스텀 펌웨어 설치

터미널 1의 DFU 부팅을 중단(Ctrl+C)한 다음, 램디스크를 위해 다시 DFU로 부팅합니다:

```bash
# 터미널 1
make boot_dfu                 # 계속 실행 유지
```

```bash
# 터미널 2
sudo make ramdisk_build       # 서명된 SSH 램디스크 빌드
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
# 또는: make cfw_install_jb        # 탈옥 변형
```

## 첫 부팅

터미널 1의 DFU 부팅을 중단(Ctrl+C)한 후 다음을 실행합니다:

```bash
make boot
```

`cfw_install_jb` 실행 후 탈옥 변형은 첫 번째 부팅 시 **Sileo**와 **TrollStore**를 사용할 수 있습니다. Sileo에서 `openssh-server`를 설치하여 SSH 접근을 활성화할 수 있습니다.

일반/개발 변형의 경우, VM에서 **direct console**이 나타납니다. `bash-4.4#`이 보이면 엔터를 누르고 다음 명령어를 실행하여 쉘 환경을 초기화하고 SSH 호스트 키를 생성하세요:

```bash
export PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/bin/X11:/usr/games:/iosbinpack64/usr/local/sbin:/iosbinpack64/usr/local/bin:/iosbinpack64/usr/sbin:/iosbinpack64/usr/bin:/iosbinpack64/sbin:/iosbinpack64/bin'

mkdir -p /var/dropbear
cp /iosbinpack64/etc/profile /var/profile
cp /iosbinpack64/etc/motd /var/motd

# SSH 호스트 키 생성 (SSH 작동에 필수)
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
iproxy 2222 22222    # SSH (dropbear)
iproxy 2222 22       # SSH (탈옥: Sileo에서 openssh-server를 설치한 경우)
iproxy 5901 5901     # VNC
iproxy 5910 5910     # RPC
```

다음을 통해 연결합니다:

- **SSH (탈옥):** `ssh -p 2222 mobile@127.0.0.1` (password: `alpine`)
- **SSH (일반/개발):** `ssh -p 2222 root@127.0.0.1` (password: `alpine`)
- **VNC:** `vnc://127.0.0.1:5901`
- [**RPC:**](http://github.com/doronz88/rpc-project) `rpcclient -p 5910 127.0.0.1`

## VM 백업 및 전환

여러 VM 환경(예: 다른 iOS 빌드 또는 펌웨어 변형)을 저장하고 전환할 수 있습니다. 백업은 `vm.backups/`에 저장되며 `rsync --sparse`를 사용하여 희소 디스크 이미지를 효율적으로 처리합니다.

```bash
make vm_backup NAME=26.1-clean    # 현재 VM 저장
rm -rf vm && make vm_new          # 새로운 빌드를 위해 초기화
# ... fw_prepare, fw_patch, restore, cfw_install, boot
make vm_backup NAME=26.3-jb       # 새 VM도 저장
make vm_list                      # 모든 백업 목록 보기
make vm_switch NAME=26.1-clean    # 백업 간 전환
```

> **참고:** 백업/전환/복원 전에 반드시 VM을 중지하세요.

## FAQ

> **무엇보다 먼저 — `git pull`을 실행하여 최신 버전인지 확인하세요.**

**Q: 실행하려고 하면 `zsh: killed ./vphone-cli` 오류가 발생합니다.**

AMFI/디버그 제한이 올바르게 우회되지 않았습니다. 다음 중 하나를 선택하세요:

- **방법 1 (AMFI 완전 비활성화):**

  ```bash
  sudo nvram boot-args="amfi_get_out_of_my_way=1 -v"
  ```

- **방법 2 (디버그 제한만 비활성화):**
  복구 모드에서 `csrutil enable --without debug`(완전한 SIP 비활성화 없음)를 사용한 다음, [`amfidont`](https://github.com/zqxwce/amfidont) 또는 [`amfree`](https://github.com/retX0/amfree)를 설치/로드하여 AMFI의 나머지 기능은 활성 상태로 유지합니다.

**Q: 시스템 앱(App Store, 메시지 등)을 다운로드하거나 설치할 수 없습니다.**

iOS 초기 설정 시 지역을 **일본** 또는 **유럽 연합**으로 선택하지 **마세요**. 이 지역에서는 추가적인 규제 검사(사이드로딩 공개, 카메라 셔터음 등)가 적용되는데, 가상 머신은 이러한 요건을 충족할 수 없어 시스템 앱의 다운로드 및 설치가 불가능합니다. 이 문제를 피하려면 다른 지역(예: 미국)을 선택하세요.

**Q: "Press home to continue" 화면에서 멈췄습니다.**

VNC(`vnc://127.0.0.1:5901`)로 접속하여 화면의 아무 곳이나 우클릭(Mac 트랙패드에서는 두 손가락 클릭)하세요. 이것이 홈 버튼 누르기를 시뮬레이션합니다.

**Q: SSH 접근을 활성화하려면?**

Sileo에서 `openssh-server`를 설치하세요 (탈옥 변형 첫 부팅 후 사용 가능).

**Q: openssh-server를 설치했는데 SSH가 작동하지 않습니다.**

VM을 재부팅하세요. 다음 부팅 시 SSH 서버가 자동으로 시작됩니다.

**Q: `.tipa` 파일을 설치할 수 있나요?**

네. 설치 메뉴는 `.ipa`와 `.tipa` 패키지를 모두 지원합니다. 드래그 앤 드롭 또는 파일 선택기를 사용하세요.

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
