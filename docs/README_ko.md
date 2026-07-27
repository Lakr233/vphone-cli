<div align="right"><strong>🇰🇷한국어</strong> | <strong><a href="./README_ja.md">🇯🇵日本語</a></strong> | <strong><a href="./README_zh.md">🇨🇳中文</a></strong> | <strong><a href="../README.md">🇬🇧English</a></strong></div>

# vphone-cli

PCC 리서치 VM 인프라를 사용하여 Apple의 Virtualization.framework로 가상 iPhone을 부팅합니다.

모든 것은 단일 `vphone-cli` 바이너리를 통해 실행됩니다 — VM 생성, 패치, 복원, 설치, 부팅, 관리. 빌드 후에는 `make`가 필요하지 않습니다.

![poc](./demo.jpeg)

## 테스트 환경

| Host            | iPhone                | CloudOS         |
| --------------- | --------------------- | --------------- |
| Mac16,11 27.0b2 | `17,3_18.6.2_22G100`  | `26.1-23B85`    |
| Mac16,8 26.5.1  | `17,3_26.0_23A341`    | `26.1-23B85`    |
| Mac16,8 26.5.1  | `17,3_26.0.1_23A355`  | `26.1-23B85`    |
| Mac16,12 26.3   | `17,3_26.1_23B85`     | `26.1-23B85`    |
| Mac16,12 26.3   | `17,3_26.3_23D127`    | `26.1-23B85`    |
| Mac16,12 26.3   | `17,3_26.3_23D127`    | `26.3-23D128`   |
| Mac16,12 26.3   | `17,3_26.3.1_23D8133` | `26.3-23D128`   |
| Mac16,11 26.2   | `17,3_26.4_23E246`    | `26.4-23E5207q` |
| Mac16,11 26.2   | `17,3_26.5_23F77`     | `26.4-23E5207q` |
| Mac16,11 27.0b2 | `17,3_26.5.2_23F84`   | `26.4-23E5207q` |
| Mac16,6 25.4.1  | `17,3_26.6_23G71`     | `26.4-23E5207q` |
| Mac16,11 27.0b2 | `17,3_27.0_24A5380h`  | `26.4-23E5207q` |
| Mac16,6 25.4.1  | `17,3_27.0_24A5390f`  | `26.4-23E5207q` |

iOS ≤ 26.0.1은 26.1 PCC vphone600 스택에 더해 CFW 단계의 `IOMobileFramebuffer` SwapEnd 페이로드 크기 패치를 사용합니다. iOS 27.0은 26.4 PCC vphone600 스택에 더해 CFW 단계의 force-kern `IOMobileFramebuffer` present-path 패치와 dyld 공유 캐시 `maxSlide` 조정을 사용합니다.

> **참고:** iOS 18.x에서는 GPU/Metal 가속이 작동하지 않습니다 — 18.x의 Metal/IOGPU 프레임워크에 반가상화 GPU 구현이 없기 때문에 Metal로 렌더링되는 콘텐츠(웹 페이지, 이미지, 배경화면)가 표시되지 않습니다. 터치, 네트워크, 앱은 정상적으로 작동합니다.

## 펌웨어 변형

보안 우회 수준이 점점 강해지는 5가지 패치 변형이 있습니다 — 하나를 `--variant`에 전달하세요:

| 변형         | 부트 체인   | CFW       | 참고                                                            |
| ------------ | ----------- | --------- | --------------------------------------------------------------- |
| `less`       | 4 patches   | 2 phases  | Patchless — iOS 완화 기능을 활성 상태로 유지                    |
| `regular`    | 42 patches  | 10 phases | AMFI/SSV/Img4/TXM 우회                                          |
| `dev`        | 53 patches  | 12 phases | + TXM 권한/디버그 우회                                          |
| `jb`         | 113 patches | 14 phases | + 전체 탈옥 (Sileo, TrollStore가 첫 부팅 시 자동 설치)          |
| `exp`        | 141 patches | 18 phases | JB 상위 집합 + VM 탐지 방지 연구 패치                           |

컴포넌트별 상세 분류는 [`research/0_binary_patch_comparison.md`](../research/0_binary_patch_comparison.md)를 참조하세요.

## 사전 요구 사항

**호스트:** macOS 15+ (Sequoia), 중첩되지 않은 Mac (Virtualization.framework는 중첩할 수 없습니다). Private PV=3 권한 + 서명되지 않은 바이너리 워크플로우에는 SIP/AMFI 완화가 필요합니다. 다음 두 가지 방법 중 **하나**를 선택하세요 — SIP 설정과 AMFI 설정은 함께 가야 하므로 섞지 마세요:

**방법 A — SIP를 완전히 비활성화한 후, boot-arg로 AMFI를 비활성화 (가장 관대).** 복구 모드에서 (전원 버튼 길게 누르기 → 터미널):

```bash
csrutil disable
csrutil allow-research-guests enable
```

그런 다음 macOS로 재부팅하고 AMFI boot-arg를 설정합니다 (적용되려면 SIP가 완전히 꺼져 있어야 합니다):

```bash
sudo nvram boot-args="amfi_get_out_of_my_way=1 -v"   # 이후 재부팅
```

**방법 B — SIP 유지 (디버그만 완화), 그런 다음 amfidont로 바이너리를 허용 목록에 추가** (AMFI는 시스템 전체에서 활성 상태 유지). 복구 모드에서:

```bash
csrutil enable --without debug
csrutil allow-research-guests enable
```

그런 다음 macOS로 재부팅하고 [`amfidont`](https://github.com/zqxwce/amfidont) (또는 [`amfree`](https://github.com/retX0/amfree))로 저장소를 허용 목록에 추가합니다:

```bash
sudo amfidont --path <repo>
```

> `less` (patchless) 변형은 방법 A, 또는 `amfidont -S`를 포함한 방법 B(`sudo amfidont -S --path <repo>`)가 필요합니다.

**의존성:**

```bash
git clone --recurse-submodules https://github.com/Lakr233/vphone-cli.git
brew install python@3.13 aria2 wget gnu-tar openssl@3 ldid-procursus sshpass keystone libusb ipsw zstd
```

(최신 `python3` — 3.11+ — 이 필요합니다; 앱은 이를 사용하여 자체 Python 환경을 빌드합니다. [Python 런타임](#python-런타임)을 참조하세요.)

## 빌드

두 개의 일회성 부트스트랩 스크립트(컴파일된 바이너리는 스스로를 빌드할 수 없습니다)를 실행하면, 그 다음부터는 모든 것이 `vphone-cli`입니다:

```bash
./scripts/setup_tools.sh      # 의존성 설치, 툴체인 서브모듈 빌드, Python venv 생성
./scripts/build.sh            # vphone-cli 빌드 및 서명, .app 번들 생성, vphoned 크로스 컴파일
```

아래 예제가 그대로 작동하도록 바이너리를 `PATH`에 추가하세요:

```bash
cd .build/release
vphone-cli --help
```

## 빠른 시작

하나의 명령으로 VM을 처음부터 끝까지 생성합니다 (다운로드 → 패치 → DFU 복원 → CFW 설치 → 첫 부팅):

```bash
vphone-cli vm create myphone -V jb        # -V / --variant
```

소스 플래그가 없으면 기본적으로 테스트된 iPhone + cloudOS 쌍을 다운로드합니다. 특정 펌웨어를 선택하려면 **`-i`/`--iphone-source`**와 **`-c`/`--cloudos-source`**를 전달하세요 — 각각 **URL** 또는 **로컬 `.ipsw` 경로**를 받습니다 (검증된 쌍은 [테스트 환경](#테스트-환경)을 참조하세요):

```bash
# 로컬 IPSW에서
vphone-cli vm create myphone -V jb \
  -i ~/ipsws/iPhone17,3_26.1_23B85_Restore.ipsw \
  -c ~/ipsws/cloudOS_26.1-23B85.ipsw

# 또는 URL에서 — 다운로드되어 ~/.vphone/ipsws 아래에 캐시됨
vphone-cli vm create myphone -V jb \
  -i "https://updates.cdn-apple.com/.../iPhone17,3_26.1_23B85_Restore.ipsw" \
  -c "https://updates.cdn-apple.com/private-cloud-compute/<id>"
```

CFW 설치 단계는 root(호스트 디스크 마운트)가 필요하며 `sudo`를 요청합니다; 무인 실행을 위해서는 `-s <pw>`(`--sudo-password`)를 전달하세요. 복원 과정을 보려면 `-v`(pmd3 로그, 색상 표시), pmd3 디버그 상세 정보는 `-vv`, vphone-cli의 내부 추적은 `-vvv`를 추가하세요. 그런 다음 부팅합니다:

```bash
vphone-cli vm launch myphone
```

VM은 `~/.vphone/VMs/`의 **라이브러리**에 저장됩니다 (어떤 명령이든 `--library-root <dir>`로 재정의할 수 있습니다). 이름 없이 VM 명령을 실행하면 (예: `vphone-cli vm launch`) VM 목록 메뉴에서 선택할 수 있습니다.

## 명령어

`vphone-cli vm create`는 전체 파이프라인을 실행합니다; 아래 개별 단계들을 사용하면 수동으로 진행하거나 한 단계만 다시 실행할 수 있습니다.

### 관리

```bash
vphone-cli vm list                         # VM 목록 표시 (스크립팅용 --json)
vphone-cli vm info myphone                  # VM 하나 표시
vphone-cli vm new myphone                   # 빈 번들 생성 (cpu/mem/disk 옵션)
vphone-cli vm config myphone --cpu 8 --memory 8192
vphone-cli vm clone myphone myphone-2       # 빠른 APFS 복제, 새로운 기기 식별자
vphone-cli vm export myphone --out myphone.tar.xz   # xz -9; restore 디렉토리 + 스테이징 파일 건너뜀
vphone-cli vm import --in myphone.tar.xz --name restored
vphone-cli vm rename myphone iphone16
vphone-cli vm delete iphone16
```

### VM 수동 빌드 (`vm create`가 자동화하는 작업)

```bash
vphone-cli vm new myphone                              # 1. 빈 번들
vphone-cli fw prepare myphone --iphone-version 26.1     # 2. IPSW 다운로드 + 병합
vphone-cli fw patch myphone --variant jb                # 3. 부트 체인 패치

vphone-cli vm launch myphone --dfu &                    # 4. DFU로 부팅 (백그라운드)
vphone-cli restore myphone --get-shsh                   #    SHSH 가져오기
vphone-cli restore myphone                              #    DFU 복원
vphone-cli vm stop myphone                              #    DFU 부팅 중지

vphone-cli cfw install myphone --variant jb             # 5. CFW 설치 (호스트 마운트; sudo 요청)
vphone-cli vm launch myphone                            # 6. 첫 부팅
```

최신 iOS로 업데이트하려면 `fw prepare`를 IPSW로 지정하세요: `--iphone-source /path/to.ipsw --cloudos-source /path/to.ipsw`.

## 실행 및 연결

`vphone-cli vm launch <name>`은 VM 창을 엽니다; `vphone-cli vm stop <name>`은 종료합니다. 게스트는 포트 `22222`에서 SSH 서버(dropbear)를, `5901`에서 VNC를 실행하며, VM의 NAT IP로 접근할 수 있습니다 (`bridge100`에서 `arp -a`로 찾으세요):

- **SSH (탈옥):** `ssh -p 22222 mobile@<vm-ip>` (비밀번호 `alpine`)
- **SSH (regular/dev):** `ssh -p 22222 root@<vm-ip>`
- **VNC:** `vnc://<vm-ip>:5901`

`jb`/`exp` 변형의 경우, Sileo와 TrollStore가 첫 부팅 시 자동으로 설치됩니다 (`/var/log/vphone_jb_setup.log`로 모니터링).

## Python 런타임

일부 단계(DFU 복원, IPSW 처리)는 Python을 통해 실행됩니다. 최초 사용 시,
vphone-cli는 번들된 `requirements.txt`를 사용하여 최신 호스트 `python3`(3.11+)로부터
`~/.vphone/venv`에 독립적인 venv를 프로비저닝합니다 — 따라서 서명된
`.app`은 **이식 가능**합니다: 어디든(예: `/Applications`) 복사하면 저장소
없이도 실행됩니다. 프로비저닝은 자동으로 이루어집니다; 미리 실행하려면 `vphone-cli setup`을
실행하세요. 특정 인터프리터를 지정하려면 `VPHONE_PYTHON=/path/to/python3`을,
venv 위치를 변경하려면 `VPHONE_VENV_DIR=/path`를 사용하세요.

## FAQ

**`zsh: killed ./vphone-cli`** — AMFI/디버그 제한이 우회되지 않았습니다; [사전 요구 사항](#사전-요구-사항)을 참조하세요 (`amfi_get_out_of_my_way=1` 또는 `amfidont`).

**`Virtualization is not available on this hardware`** — Mac 자체가 VM입니다; PV=3 게스트 부팅은 중첩할 수 없습니다. 중첩되지 않은 macOS 15+ 호스트를 사용하세요.

**"Press home to continue"에서 멈춤** — VNC로 접속하여 우클릭(두 손가락 클릭)으로 홈 버튼을 시뮬레이션하세요.

**시스템 앱이 설치되지 않음** — iOS 초기 설정 시 지역으로 일본이나 EU를 선택하지 마세요 (VM이 충족할 수 없는 추가 규제 검사가 있습니다); 예를 들어 United States를 선택하세요.

**앱이 실행 시 `EXC_GUARD` / `GUARD_TYPE_MACH_PORT`로 충돌** — `vphone-cli fw patch <name> --variant <v> --force-exc-guard`로 다시 패치한 다음, 다시 복원/설치하세요 ([#291](https://github.com/Lakr233/vphone-cli/issues/291)). iOS 18 베이스에서는 항상 켜져 있습니다.

**`.ipa`/`.tipa` 설치** — 실행 중인 VM의 Install 메뉴를 사용하세요 (드래그 앤 드롭 또는 파일 선택기).

## 자동화

`vphone-cli`는 프로그래밍 방식 제어를 위한 호스트 제어 소켓(`<bundle>/vphone.sock`)을 노출합니다 — 스크린샷, 터치, 스와이프, 하드웨어 키, 클립보드 — 각 동작은 AI 주도 E2E 테스트를 위해 인라인 스크린샷을 반환합니다. 이를 감싸는 MCP 서버는 [vphone-mcp](https://github.com/pluginslab/vphone-mcp)를 참조하세요.

## 감사의 말

- [wh1te4ever/super-tart-vphone-writeup](https://github.com/wh1te4ever/super-tart-vphone-writeup)
