<div align="right"><strong>🇰🇷한국어</strong> | <strong><a href="./README_ja.md">🇯🇵日本語</a></strong> | <strong><a href="./README_zh.md">🇨🇳中文</a></strong> | <strong><a href="../README.md">🇬🇧English</a></strong></div>

# vphone-cli

PCC 리서치 VM 인프라를 사용하여 Apple의 Virtualization.framework로 가상 iPhone을 부팅합니다.

![poc](./demo.jpeg)

## 사전 요구 사항

**호스트:**

- Apple Silicon
- macOS 15+ (Sequoia)
- Xcode + iOS SDK (게스트 데몬 크로스 컴파일용)
- [서명되지 않은 바이너리로 private PV=3 권한을 허용하기 위한 SIP/AMFI 완화](#sipamfi-완화)

**의존성:**

```bash
brew install python@3.13 aria2 wget gnu-tar openssl@3 ldid-procursus sshpass keystone cmake libusb ipsw zstd
```

## 설치

```bash
brew install zqxwce/tap/vphone-cli
```

## 빌드

```bash
git clone --recurse-submodules https://github.com/Lakr233/vphone-cli.git

./scripts/setup_tools.sh      # 의존성 설치, 툴체인 서브모듈 빌드, Python venv 생성
./scripts/build.sh            # vphone-cli 빌드 및 서명, .app 번들 생성, vphoned 크로스 컴파일

cd .build/vphone-cli.app/Contents/MacOS/
vphone-cli --help
```

## 빠른 시작

하나의 명령으로 VM을 처음부터 끝까지 생성합니다 (다운로드 → 패치 → DFU 복원 → CFW 설치 → 첫 부팅):

```bash
vphone-cli vm create myphone -V jb        # -V / --variant

vphone-cli vm launch myphone
```

## 명령어

`vphone-cli vm create`는 전체 파이프라인을 실행합니다; 아래 개별 단계들을 사용하면 수동으로 진행하거나 한 단계만 다시 실행할 수 있습니다.

### 관리

```bash
vphone-cli vm list                         # VM 목록 표시 (스크립팅용 --json)
vphone-cli vm info myphone                  # VM 하나 표시
vphone-cli vm new myphone                   # 빈 번들 생성 (cpu/mem/disk 옵션)
vphone-cli vm config myphone --cpu 8 --memory 8192
vphone-cli vm clone myphone myphone-2       # 빠른 APFS 복제, 새로운 기기 식별자
vphone-cli vm export myphone --out myphone.tzst   # zstd fast by default (--max = xz -9); --out 이 디렉토리면 <vm>.tzst/.txz 자동 명명; restore 디렉토리 + 스테이징 파일 건너뜀
vphone-cli vm import myphone.tzst --name restored
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

## 실행 및 연결

- **SSH (탈옥):** `ssh -p 22222 mobile@<vm-ip>` (비밀번호 `alpine`)
- **SSH (regular/dev):** `ssh -p 22222 root@<vm-ip>`
- **VNC:** `vnc://<vm-ip>:5901`

## 위치

vphone-cli가 생성하는 모든 것은 `~/.vphone/` 아래에 있습니다 — 서명된 번들이 이식 가능하도록 저장소와 `.app` 외부에 보관됩니다. `$VPHONE_ROOT`로 전체 트리를 리디렉션할 수 있습니다:

| 경로              | 내용                                                                                       |
| ----------------- | ------------------------------------------------------------------------------------------ |
| `~/.vphone/`      | 사용자별 데이터 루트 — `$VPHONE_ROOT`로 전체 위치를 재정의합니다.                            |
| `~/.vphone/VMs/`  | VM 번들 — VM마다 하나의 디렉터리. 라이브러리이며, `$VPHONE_LIBRARY_ROOT`로 재정의할 수 있습니다. |
| `~/.vphone/ipsws/`| 다운로드된 iPhone + cloudOS IPSW, 캐시되어 여러 VM에서 재사용됩니다.                          |
| `~/.vphone/tools/`| `fw prepare` 중에 가져온 APFS seal-volume 아티팩트(`apfs_sealvolume_<version>`) 캐시.         |
| `~/.vphone/debs/` | `jb`/`exp` CFW 설치가 게스트에 넣는 `.deb` 패키지 캐시 (Sileo, apt 등).                       |
| `~/.vphone/venv/` | 자동으로 프로비저닝되는 Python 환경 ([Python 런타임](#python-런타임) 참조; `$VPHONE_VENV_DIR`로 재정의). |

우선순위: 항목별 재정의(`$VPHONE_LIBRARY_ROOT`, `$VPHONE_VENV_DIR`)가 `$VPHONE_ROOT`보다 우선하고, `$VPHONE_ROOT`는 `~/.vphone` 기본값보다 우선합니다. `ipsws/`, `tools/`, `debs/` 캐시는 항상 현재 활성 루트 바로 아래에 위치합니다.

## SIP/AMFI 완화

**방법 A — SIP를 완전히 비활성화한 후, boot-arg로 AMFI를 비활성화 (가장 관대).**

복구 모드에서 (전원 버튼 길게 누르기 → 터미널):

```bash
csrutil disable
csrutil allow-research-guests enable
```

그런 다음 macOS로 재부팅하고 AMFI boot-arg를 설정합니다 (적용되려면 SIP가 완전히 꺼져 있어야 합니다):

```bash
sudo nvram boot-args="amfi_get_out_of_my_way=1 -v"   # 이후 재부팅
```

**방법 B — SIP 유지 (디버그만 완화), 그런 다음 amfidont로 바이너리를 허용 목록에 추가** (AMFI는 시스템 전체에서 활성 상태 유지).

복구 모드에서:

```bash
csrutil enable --without debug
csrutil allow-research-guests enable
```

그런 다음 macOS로 재부팅하고:

```bash
vphone-amfidont         # 로컬 빌드의 경우 .build/vphone-cli.app/Contents/Resources/vphone-amfidont
```

## 테스트 환경

| 호스트          | iPhone                | CloudOS         |
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
| Mac16,6 26.4.1  | `17,3_26.6_23G71`     | `26.4-23E5207q` |
| Mac16,11 27.0b2 | `17,3_26.6.1_23G83`   | `26.4-23E5207q` |
| Mac16,11 27.0b2 | `17,3_27.0_24A5380h`  | `26.4-23E5207q` |
| Mac16,6 26.4.1  | `17,3_27.0_24A5390f`  | `26.4-23E5207q` |
| Mac16,6 26.6.1  | `17,3_27.0_24A5408d`  | `26.4-23E5207q` |
| Mac16,11 27.0b2 | `17,3_27.0_24A5418b`  | `26.4-23E5207q` |
| Mac16,11 27.0b2 | `17,3_27.0_24A5424a`  | `26.4-23E5207q` |
| Mac16,11 27.0b2 | `17,3_27.0_24A5430a`  | `26.4-23E5207q` |

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
