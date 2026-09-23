<div align="right"><strong>🇰🇷한국어</strong> | <strong><a href="./README_ja.md">🇯🇵日本語</a></strong> | <strong><a href="./README_zh.md">🇨🇳中文</a></strong> | <strong><a href="./README_ru.md">🇷🇺Русский</a></strong> | <strong><a href="./README_pt.md">🇧🇷Português</a></strong> | <strong><a href="../README.md">🇬🇧English</a></strong></div>

# vphone-cli

PCC 리서치 VM 인프라를 사용하여 Apple의 Virtualization.framework로 가상 iPhone을 부팅합니다.

![poc](./demo.jpeg)

## 사전 요구 사항

**실행에 필요한 것:**

- Apple Silicon
- macOS 15+ (Sequoia)
- [서명되지 않은 바이너리로 private PV=3 권한을 허용하기 위한 SIP/AMFI 완화](#sipamfi-완화)

**그 밖에는 아무것도 필요 없습니다.** Homebrew 패키지도, 인터프리터도, 패키지 환경도,
Xcode도 필요하지 않습니다. vphone-cli가 실행하는 모든 것은 `/usr/bin`·`/bin`·`/usr/sbin`·
`/sbin` 아래의 시스템 바이너리이거나 `.app` 안에 들어 있습니다 — 서명기(`ldid`를 대체),
아카이브 처리(`gtar`, `zstd`, `unzip`), 펌웨어 카탈로그와 IM4P/AEA 처리(`ipsw`), 그리고
CFW 설치기가 게스트에 넣는 다섯 개의 iOS 바이너리까지. 이 다섯 개는 빌드 시점에 크로스
컴파일되어 함께 배포되며, 사용자 머신에서 컴파일하지 않습니다. 이 상태를 지키는 관문이
`make check-aux`입니다.

**소스에서 빌드하려면** Xcode(그 다섯 개 게스트 바이너리를 크로스 컴파일할 iOS SDK가
필요합니다)와 `git-lfs`(`git clone`이 `scripts/resources`의 아카이브를 받는 데 필요)가
추가로 있어야 합니다.

## 설치

```bash
brew install zqxwce/tap/vphone-cli
```

## 빌드

```bash
brew install git-lfs
git clone --recurse-submodules https://github.com/Lakr233/vphone-cli.git

./scripts/build.sh            # vphone-cli 빌드 및 서명, 게스트 바이너리 크로스 컴파일, .app 번들 생성

cd .build/vphone-cli.app/Contents/MacOS/
vphone-cli --help
```

`./scripts/setup_tools.sh`는 선택 사항이며 딱 하나, `insert_dylib`만 빌드합니다. Mach-O
테스트가 Swift dylib 주입기를 바이트 단위로 대조하기 위한 독립 참조물이며, 배포물은 이를
실행하지 않습니다.

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

4단계와 5단계는 `vphone-cli` 자체 프로세스에서 실행됩니다. `restore`는 내장된
libirecovery와 idevicerestore를 직접 구동합니다 — 외부 복원 도구도, 첫 실행 전
준비 단계도 없습니다. `--offline`을 붙이면 Apple에 새 ticket을 요청하는 대신 VM
옆에 이미 저장된 `.shsh`로 복원합니다.

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

우선순위: 항목별 재정의 `$VPHONE_LIBRARY_ROOT`가 `$VPHONE_ROOT`보다 우선하고, `$VPHONE_ROOT`는 `~/.vphone` 기본값보다 우선합니다. `ipsws/`, `tools/`, `debs/` 캐시는 항상 현재 활성 루트 바로 아래에 위치합니다.

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

이 방법이 여전히 가장 간단하며, VM 옆에서 무언가를 계속 띄워 둘 필요가 없는 유일한 방법입니다: AMFI가 완화되어 있으면 `vphone-vm`이 혼자서 실행됩니다.

**방법 B — SIP 유지 (디버그만 완화), 이번 빌드를 허용 목록에 넣기** (그 외의 시간에는, 그리고 허용하지 않은 모든 바이너리에 대해서는 AMFI가 활성 상태 유지).

복구 모드에서:

```bash
csrutil enable --without debug
csrutil allow-research-guests enable
```

그런 다음 macOS로 재부팅하고 실행합니다:

```bash
make amfi_allow     # root 필요. 빌드할 때마다 다시 실행하세요
make amfi_status    # 허용 목록과, 이 호스트가 그것을 가질 수 있는지 표시
make amfi_off       # 허용 목록을 제거하고 amfid를 깨끗하게 재시작
```

이것이 실행하는 것은 `vphone-amfi-allow` — 이 저장소 자체의 C 코드로 만들어져 `.app` 안에 함께 배포됩니다. 쓰는 것은 두 가지뿐입니다:

* 두 개의 `vphone-vm` cdhash를
  `/Library/Preferences/com.apple.security.coderequirements.plist`에. 이것은 AMFI가
  원래부터 읽는 파일이며, 구멍이 아니라 AMFI 자신의 기능입니다;
* amfid **힙의 1바이트**. `_isRunningInternalBuild` 플래그를 뒤집어 그 파일을 읽게 만듭니다.

둘 다 필요한 이유는 `make boot`이 둘 다 실행하기 때문입니다: `boot_binary_check`는
`.build/release/vphone-vm`을, 부팅 자체는 `.app` 안의 것을 실행합니다. 서로 다른 식별자로
서명되어 해시도 다르므로, 한쪽만 허용하면 흐름의 절반만 덮게 됩니다.

**빌드할 때마다 다시 실행하세요.** 허용은 cdhash를 기준으로 하며, 서명할 때마다 cdhash가 바뀝니다 — 맨 `swift build`로도 바뀝니다.

허용해야 할 바이너리는 `vphone-vm`입니다. `vphone-cli`는 entitlement가 없어 항상 실행되므로 필요한 것은 그쪽 cdhash가 아닙니다.

> **무엇을 허용하는지 정확히 알아 두세요.** 이것은 cdhash를 기준으로 하는 허용 목록입니다: 지정하지 않은 바이너리에 대해서는 amfid가 계속 검증을 강제합니다. `make amfi_off`가 그 파일을 지우고 amfid를 재시작합니다.
>
> 그 1바이트는 amfid의 `__TEXT`가 아니라 **힙**에 쓰이며, 이것이 이 방식이 통하는 이유의 전부입니다. 이전 방식들은 코드를 고쳤습니다 — `vphone-letmein`은 `-[AMFIPathValidator_macos validateWithError:]`의 `ldrb`를 덮어썼고, LLDB 기반 도구는 중단점을 위해 `BRK`를 심습니다. 둘 다 dirty하고 서명되지 않은 실행 페이지를 남기며, `sysctl vm.cs_system_enforcement`가 1인 호스트 — macOS 27.0 (26A428), arm64e, 위의 `csrutil` 설정 그대로에서 실측 — 에서는 커널이 다음 폴트에 그 페이지를 검증하고 amfid를 종료시키며 게스트까지 함께 죽입니다. 이 sysctl은 런타임에 읽기 전용이므로 "코드에 패치" 방식은 아무리 조심해도 살아남을 수 없습니다. 힙은 코드가 아니므로 강제 검증이 트집 잡을 것이 없습니다.

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
| Mac16,6 26.6.1  | `17,3_26.6.2_23G90`   | `26.4-23E5207q` |
| Mac16,11 27.0b2 | `17,3_27.0_24A5380h`  | `26.4-23E5207q` |
| Mac16,6 26.4.1  | `17,3_27.0_24A5390f`  | `26.4-23E5207q` |
| Mac16,6 26.6.1  | `17,3_27.0_24A5408d`  | `26.4-23E5207q` |
| Mac16,11 27.0b2 | `17,3_27.0_24A5418b`  | `26.4-23E5207q` |
| Mac16,11 27.0b2 | `17,3_27.0_24A5424a`  | `26.4-23E5207q` |
| Mac16,11 27.0b2 | `17,3_27.0_24A5430a`  | `26.4-23E5207q` |
| Mac16,6 26.6.1  | `17,3_27.0_24A435`    | `26.4-23E5207q` |

## FAQ

**`zsh: killed ./vphone-vm`** — AMFI/디버그 제한이 우회되지 않았습니다; [SIP/AMFI 완화](#sipamfi-완화)를 참조하세요 (`amfi_get_out_of_my_way=1` (방법 A), 또는 이번 빌드에 대한 `make amfi_allow` (방법 B)). 마지막 빌드 *전에* 실행했다면 다시 실행하세요: 허용은 cdhash를 기준으로 하고, 서명이 그것을 바꿉니다. 참고로 `vphone-cli` 자체에는 이런 일이 생길 수 없습니다: entitlement가 없으므로 *그것*이 종료되고 있다면 다른 문제가 있는 것입니다.

**`Virtualization is not available on this hardware`** — Mac 자체가 VM입니다; PV=3 게스트 부팅은 중첩할 수 없습니다. 중첩되지 않은 macOS 15+ 호스트를 사용하세요.

**"Press home to continue"에서 멈춤** — VNC로 접속하여 우클릭(두 손가락 클릭)으로 홈 버튼을 시뮬레이션하세요.

**시스템 앱이 설치되지 않음** — iOS 초기 설정 시 지역으로 일본이나 EU를 선택하지 마세요 (VM이 충족할 수 없는 추가 규제 검사가 있습니다); 예를 들어 United States를 선택하세요.

**앱이 실행 시 `EXC_GUARD` / `GUARD_TYPE_MACH_PORT`로 충돌** — `vphone-cli fw patch <name> --variant <v> --force-exc-guard`로 다시 패치한 다음, 다시 복원/설치하세요 ([#291](https://github.com/Lakr233/vphone-cli/issues/291)). iOS 18 베이스에서는 항상 켜져 있습니다.

**`.ipa`/`.tipa` 설치** — 실행 중인 VM의 Install 메뉴를 사용하세요 (드래그 앤 드롭 또는 파일 선택기).

## 자동화

`vphone-cli`는 프로그래밍 방식 제어를 위한 호스트 제어 소켓(`<bundle>/vphone.sock`)을 노출합니다 — 스크린샷, 터치, 스와이프, 하드웨어 키, 클립보드 — 각 동작은 AI 주도 E2E 테스트를 위해 인라인 스크린샷을 반환합니다. 이를 감싸는 MCP 서버는 [vphone-mcp](https://github.com/pluginslab/vphone-mcp)를 참조하세요.

## 감사의 말

- [wh1te4ever/super-tart-vphone-writeup](https://github.com/wh1te4ever/super-tart-vphone-writeup)
