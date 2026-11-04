# 호스트 설정

권한(entitlement)이 부여된 가상 머신 프로세스 `vphone-vm`을 실행할 수 있도록 Mac을 준비합니다. Mac마다 한 번만 하면 되며, 허용 목록 단계는 `vphone-vm`의 서명이 바뀔 때마다 반복합니다.

macOS 15 이상을 실행하는 Apple Silicon Mac이 필요합니다. PV=3 연구용 게스트는 중첩된 macOS 가상 머신 안에서는 실행되지 않습니다.

## 호스트 점검

사용하는 `VPhone.bundle`에서 사전 점검을 실행합니다.

```sh
vphone-cli host preflight
```

가상 머신을 시작하기 전에 권한이 부여된 `vphone-vm`을 점검합니다. AMFI가 `vphone-vm`을 거부하면, 오류 메시지에 해당 번들에 맞는 `sudo .../vphone-escalator allow .../vphone-vm` 명령이 그대로 표시됩니다.

## 보안 구성 선택

`vphone-vm`에는 Apple 비공개 가상화 권한이 있으므로 macOS가 이를 허용해야 합니다. 아래 두 방법 모두 macOS 복구에서 Research Guests를 활성화해야 합니다. 하나를 선택하세요.

### 방법 A: SIP를 유지하고 디버깅 제한만 완화

1. macOS 복구로 시동하고 터미널을 열어 다음을 실행합니다.

   ```sh
   csrutil enable --without debug
   csrutil allow-research-guests enable
   ```

2. macOS로 재시동합니다.
3. 현재 `vphone-vm`을 허용 목록에 추가합니다. 배포된 번들이라면 `vphone-cli host preflight`를 실행하고 출력된 명령을 실행합니다. 소스 체크아웃에서는 다음과 같습니다.

   ```sh
   bundle=.build/XcodeBundle/Build/Products/Debug/VPhone.bundle
   sudo "$bundle/Contents/MacOS/vphone-escalator" allow "$bundle/Contents/MacOS/vphone-vm"
   "$bundle/Contents/MacOS/vphone-escalator" status
   "$bundle/Contents/MacOS/vphone-cli" host preflight
   ```

> [!WARNING]
> 빌드할 때마다 `allow` 명령을 다시 실행하세요. 서명만 바뀌는 재빌드도 마찬가지입니다. 허용 목록에는 `vphone-vm`의 cdhash가 저장되는데, 서명이 바뀌면 cdhash도 바뀝니다.

허용 목록을 되돌리려면 다음을 실행합니다.

```sh
sudo "$bundle/Contents/MacOS/vphone-escalator" off
```

`off`는 `vphone-escalator`가 추가한 해시만 제거하고 amfid를 재시작합니다. 환경설정 자체와 그 밖의 값은 유지됩니다.

제한된 권한이 필요한 다른 서명된 호스트 바이너리도 같은 `allow` 명령에 함께 넘길 수 있습니다. 권한이 없는 `vphone-cli`에는 필요하지 않습니다.

### 방법 B: SIP와 AMFI 비활성화

더 많은 것을 허용하는 구성입니다.

1. macOS 복구로 시동하고 터미널을 열어 다음을 실행합니다.

   ```sh
   csrutil disable
   csrutil allow-research-guests enable
   ```

2. macOS로 재시동하고 부트 인자를 설정한 뒤 다시 재시동합니다.

   ```sh
   sudo nvram boot-args="amfi_get_out_of_my_way=1 -v"
   ```

> [!WARNING]
> 기존 `boot-args`를 덮어씁니다. 먼저 `nvram boot-args`로 확인하세요.

## Launchpad를 사용할 때

Launchpad의 번들 사전 점검은 SIP 디버깅 제한이 해제되었는지(또는 SIP가 완전히 꺼졌는지)와 Research Guests가 활성화되었는지 확인합니다. `vphone-escalator`를 직접 실행할 필요는 없습니다.

- AMFI가 설치된 `vphone-vm`을 차단하면, Launchpad의 도우미가 해당 호스트 설정을 다시 확인하고, root 소유 번들과 기록된 cdhash를 검증한 뒤, 그 번들의 `vphone-escalator allow`를 root로 실행합니다. 그런 다음 Launchpad가 사전 점검을 다시 실행합니다.
- 새 번들 서명은 각각 따로 확인하고 허용합니다.
- 더 새로운 Launchpad에 더 새로운 도우미가 포함되어 있으면, 시작할 때 도우미를 업데이트하기 위해 관리자 인증을 요청합니다.

단독으로 사용하는 `vphone-cli`는 여전히 직접 실행할 명령을 알려 줍니다.

## 소스에서 빌드

배포된 `VPhone.bundle`은 실행 시 Homebrew, Python, Xcode가 필요하지 않습니다. 소스에서 빌드하려면 `vphoned`를 컴파일할 Xcode와 iPhoneOS SDK가 필요합니다. 체크아웃에서 다음을 실행합니다.

```sh
xcodebuild -workspace VPhone.xcworkspace -scheme VPhone \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/XcodeBundle build
.build/XcodeBundle/Build/Products/Debug/VPhone.bundle/Contents/MacOS/vphone-cli host preflight
```

`VPhone` 스킴은 모든 프로그램이 포함된, 애드혹 서명된 번들을 만듭니다. 방법 A를 사용한다면 새로 빌드할 때마다 허용 목록에 추가하세요.

## 허용 목록이 변경하는 것

`vphone-escalator allow`는 AMFI 코드 요구 사항 환경설정이 없으면 새로 만듭니다. 이미 있으면 그 `Entitlements` 요구 사항에 현재 `vphone-vm`의 cdhash를 추가하며, 다른 cdhash와 환경설정 키는 유지하고 이미 있는 해시는 건너뜁니다. 기존 `AllowUnsafeDynamicLinking` 값은 건드리지 않으며, 그 키가 없을 때만 `false`를 기록합니다. amfid의 힙에서 1바이트를 바꿔 amfid가 이 요구 사항을 참조하도록 합니다.

## 번들에 포함된 것

- `vphone-cli`는 비공개 권한 없이 작업 전체를 조율하며, `vphone-cli archive`로 아카이브를 처리합니다.
- `vphone-vm`은 서명되고 권한이 부여된 가상 머신 및 창 프로세스입니다.
- `vphoned`는 빌드 시 iOS용으로 컴파일되며, 생성되는 각 게스트에 설치됩니다.

구현 경위는 [바이너리 분리에 관한 연구 기록](../../../Research/Host/host_binary_split.md)을 참고하세요.

## 함께 보기

- [빠른 시작](quick-start.md)
- [가상 머신 생성 및 실행](../machines/create-and-run.md)
- [문제 해결](../help/troubleshooting.md)
