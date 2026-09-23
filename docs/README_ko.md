<div align="right"><strong>🇰🇷한국어</strong> | <strong><a href="./README_ja.md">🇯🇵日本語</a></strong> | <strong><a href="./README_zh.md">🇨🇳中文</a></strong> | <strong><a href="./README_ru.md">🇷🇺Русский</a></strong> | <strong><a href="./README_pt.md">🇧🇷Português</a></strong> | <strong><a href="../README.md">🇬🇧English</a></strong></div>

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
brew install aria2 wget gnu-tar openssl@3 ldid-procursus sshpass libusb ipsw zstd
```

인터프리터도, 패키지 환경도 필요하지 않습니다. vphone-cli가 실행하는 모든 것은 Swift 또는 C이며 `make build`가 빌드합니다.

## 설치

```bash
brew install zqxwce/tap/vphone-cli
```

## 빌드

```bash
git clone --recurse-submodules https://github.com/Lakr233/vphone-cli.git

./scripts/setup_tools.sh      # brew 의존성 설치, 툴체인 서브모듈 빌드
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

**방법 B — SIP 유지 (디버그만 완화), 실행하는 동안 직접 `amfidont` 띄우기** (그 외의 시간에는, 그리고 허용하지 않은 모든 바이너리에 대해서는 AMFI가 활성 상태 유지).

복구 모드에서:

```bash
csrutil enable --without debug
csrutil allow-research-guests enable
```

그런 다음 macOS로 재부팅합니다.

[`amfidont`](https://github.com/zqxwce/amfidont)는 사용자가 직접 설치하고 실행하는 별개의 도구입니다. **이 프로젝트는 그것을 포함하지도, 설치하지도, 실행하지도, 관리하지도 않으며** 의존하지도 않습니다 — `vphone-cli`는 `vphone-vm`이 종료되었다는 것을 감지하고 무엇을 실행해야 하는지 알려줄 뿐입니다. 이 저장소에 Python 의존성이 추가되지도 않습니다.

Apple의 Python으로 설치하세요. Homebrew의 Python은 PEP 668으로 거부하며, 이 도구는 Xcode의 `python3`를 다시 exec 하므로 Xcode가 설치되어 있어야 합니다:

```bash
xcrun python3 -m pip install --user amfidont
# ~/Library/Python/3.9/bin에 설치됩니다 — $PATH에 추가하세요
```

`vphone-vm`의 cdhash를 구합니다. entitlement를 가진 쪽은 이것입니다. `vphone-cli`는 entitlement가 없어 항상 실행되므로 필요한 것은 그쪽 cdhash가 아닙니다:

```bash
VPHONE_BIN="$PWD/.build/vphone-cli.app/Contents/MacOS"   # vphone-vm이 있는 디렉터리
codesign -dv --verbose=4 "$VPHONE_BIN/vphone-vm" 2>&1 | sed -n 's/^CDHash=//p' | head -1
```

별도의 터미널에서 데몬을 띄우고 그대로 두세요:

```bash
sudo amfidont daemon --path "$VPHONE_BIN" --cdhash <cdhash> --spoof-apple --verbose
```

그런 다음 다른 터미널에서 평소대로 실행합니다 — `vphone-cli vm launch myphone`.

`--path` / `-p`와 `--cdhash` / `-c`는 모두 여러 번 지정할 수 있고, `~/.amfidont/paths`와 `~/.amfidont/cdhashes`에 저장된 허용 목록과 병합됩니다. `amfidont add-path <dir>`와 `amfidont add-cdhash <hash>`로 한 번 기록해 두면 (`remove-path` / `remove-cdhash`로 취소) 그 뒤로는 `sudo amfidont daemon --spoof-apple`만으로 충분합니다. 다시 빌드하면 cdhash가 바뀌므로 cdhash만으로 만든 허용 목록은 `make build`를 실행할 때마다 낡게 됩니다. `--path` 허용 목록은 그렇지 않습니다.

> **무엇을 허용하는지 정확히 알아 두세요.** 이것은 경로 접두사와 cdhash를 기준으로 하는 허용 목록입니다: 지정하지 않은 대상에 대해서는 amfid가 계속 검증을 강제합니다. `--spoof-apple`은 허용된 바이너리가 Apple이 서명한 것으로 보고되게 하며, private PV=3 entitlement에 필요한 것이 바로 이 동작입니다. 예외는 `--allow-all`로, 이를 넘기면 데몬이 실행되는 동안 amfid가 검사하는 *모든* 서명이 유효하다고 보고됩니다. 어느 쪽이든 메모리에만 존재합니다: 데몬을 멈추거나 재부팅하면 amfid는 원래대로 돌아갑니다.
>
> `amfidont`는 `vphone-letmein`을 대체했습니다. 후자는 amfid의 `__TEXT`에 써넣는 방식으로 창을 열었습니다. `sysctl vm.cs_system_enforcement`가 1인 호스트에서는 — macOS 27.0 (26A428), arm64e, 위의 `csrutil` 설정 그대로에서 실측 — 커널이 그 dirty 페이지 때문에 amfid를 종료시키고 게스트까지 함께 죽으며, 이 sysctl은 읽기 전용입니다. `amfidont`는 LLDB를 통해 amfid를 제어하므로 중단점이 CPU의 디버그 레지스터에 놓이고 페이지는 전혀 쓰이지 않습니다. 강제 적용 환경에서 패치 방식은 안 되지만 이것은 동작하는 이유가 바로 이것입니다.

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

**`zsh: killed ./vphone-vm`** — AMFI/디버그 제한이 우회되지 않았습니다; [SIP/AMFI 완화](#sipamfi-완화)를 참조하세요 (`amfi_get_out_of_my_way=1` (방법 A), 또는 `vphone-vm`을 허용 목록에 넣은 `amfidont`를 띄워 두기 (방법 B)). 참고로 `vphone-cli` 자체에는 이런 일이 생길 수 없습니다: entitlement가 없으므로 *그것*이 종료되고 있다면 다른 문제가 있는 것입니다.

**`Virtualization is not available on this hardware`** — Mac 자체가 VM입니다; PV=3 게스트 부팅은 중첩할 수 없습니다. 중첩되지 않은 macOS 15+ 호스트를 사용하세요.

**"Press home to continue"에서 멈춤** — VNC로 접속하여 우클릭(두 손가락 클릭)으로 홈 버튼을 시뮬레이션하세요.

**시스템 앱이 설치되지 않음** — iOS 초기 설정 시 지역으로 일본이나 EU를 선택하지 마세요 (VM이 충족할 수 없는 추가 규제 검사가 있습니다); 예를 들어 United States를 선택하세요.

**앱이 실행 시 `EXC_GUARD` / `GUARD_TYPE_MACH_PORT`로 충돌** — `vphone-cli fw patch <name> --variant <v> --force-exc-guard`로 다시 패치한 다음, 다시 복원/설치하세요 ([#291](https://github.com/Lakr233/vphone-cli/issues/291)). iOS 18 베이스에서는 항상 켜져 있습니다.

**`.ipa`/`.tipa` 설치** — 실행 중인 VM의 Install 메뉴를 사용하세요 (드래그 앤 드롭 또는 파일 선택기).

## 자동화

`vphone-cli`는 프로그래밍 방식 제어를 위한 호스트 제어 소켓(`<bundle>/vphone.sock`)을 노출합니다 — 스크린샷, 터치, 스와이프, 하드웨어 키, 클립보드 — 각 동작은 AI 주도 E2E 테스트를 위해 인라인 스크린샷을 반환합니다. 이를 감싸는 MCP 서버는 [vphone-mcp](https://github.com/pluginslab/vphone-mcp)를 참조하세요.

## 감사의 말

- [wh1te4ever/super-tart-vphone-writeup](https://github.com/wh1te4ever/super-tart-vphone-writeup)
