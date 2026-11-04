# VPhone 번들 통합

이 페이지는 `vphone-launchpad`처럼 `VPhone.bundle`을 포함해 배포하거나 제어하는 애플리케이션을 만드는 사람을 위한 것입니다. 번들에 무엇이 들어 있고, 통합하는 애플리케이션이 무엇을 책임지는지 설명합니다.

## 빌드 및 검증

```sh
xcodebuild -workspace VPhone.xcworkspace -scheme VPhone \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/XcodeBundle build
```

`VPhone` 스킴은 `VPhone.bundle`을 만들며, 빌드 과정에서 `ValidateBundle.sh`가 이를 검사합니다.

## 통합 방법

- 번들을 그대로 유지하고 `Contents/MacOS/vphone-cli`를 프로세스로 실행하세요. 번들은 실행 파일과 리소스를 담는 컨테이너이며, macOS 앱이나 동적으로 로드되는 플러그인이 아닙니다. CLI는 자신의 실행 파일 경로를 기준으로 짝이 되는 `vphone-vm`을 찾습니다.
- 번들 전체를 버전이 매겨진 하나의 단위로 설치하고 업데이트하세요. 서명된 바이너리를 그 자리에서 다시 쓰지 마세요.
- `vphone-vm`이 바뀌면 cdhash도 바뀝니다. 새 빌드를 실행하기 전에 AMFI 허용을 준비하세요.
- 다운로드, 릴리스 검증, 호스트 인증, 설치, 업데이트 정책은 애플리케이션이 담당합니다. 개발자 도구 접근 권한과 AMFI 인증은 서로 별개인 호스트 결정입니다.
- 가상 머신 보관함과 캐시는 `VPhone.bundle` 밖, 기본적으로 `~/.vphone` 아래에 있습니다. 호스트 쪽 가상 머신 출력물은 root로 실행한 생성 작업 후에도 별도의 워크스테이션 프로세스가 접근할 수 있도록 `0777` 모드를 사용합니다. `Disk.img` 안의 게스트 파일 시스템 권한은 고유의 의미를 유지합니다.

## 번들 내용

| 경로 | 역할 |
| --- | --- |
| `Contents/MacOS/vphone-cli` | 권한이 없는 명령 진입점 |
| `Contents/MacOS/vphone-vm` | 가상 머신 및 창 프로세스. 비공개 가상화 권한 보유 |
| `Contents/MacOS/vphone-escalator` | 현재 가상 머신 cdhash를 위한 AMFI 허용 목록 도구 |
| `Contents/MacOS/libswiftCompatibilitySpan.vphone.dylib` | macOS 15에서 `vphone-vm`이 사용하는 Swift 백디플로이먼트 라이브러리 |
| `Contents/Resources/guest-resources/vphoned` | 자체 권한으로 미리 서명된 게스트 데몬. 번들에 서명되지 않은 사본은 없습니다 |
| `Contents/Resources/guest-resources/*.dylib` | 게스트 라이브러리: launchd 훅, SystemHook, 카메라 훅, GPU 컴파일러 플러그인, 그리고 [`VPhoneGuestComponents`](../../../VPhoneGuestComponents/README.md)에 나열된 수정 사항과 기기 어댑터 |
| `Contents/Resources/guest-resources/*.plist` | 게스트 launch daemon 구성, 카메라 훅 및 MISFix 필터 |
| `Contents/Resources` | 현지화된 문자열. 서명 스크립트나 권한 파일은 포함되지 않습니다 |

`Contents/MacOS`에는 Mac에서 실행되는 프로그램만 있습니다. `guest-resources`에는 게스트에 설치되는 파일만 있으며, 그 안의 모든 Mach-O는 iOS용으로 빌드됩니다. `ValidateBundle.sh`가 두 규칙을 모두 강제합니다.

## 서명

모든 실행 파일은 애드혹 코드 서명을 사용합니다. 비공개 권한은 그것이 필요한 하위 프로세스에만 있습니다. 번들에는 `CFBundleExecutable`, 앱 실행기, SMJobBless 도우미, 설치 프로그램, 암호 입력 창, 자동 root 획득 기능이 없습니다.

## 개인정보 보호 권한

macOS는 책임 프로세스(responsible process)를 대신해 개인정보 보호 권한(마이크, 위치)을 요청하고, 허용 여부를 그 프로세스의 코드 서명에 연결합니다.

- 책임을 포기(disclaim)한 상태로 `vphone-cli`를 시작하면 `vphone-cli`가 `vphone-vm`의 책임 프로세스가 됩니다. 애드혹으로 서명되어 있으므로, 번들을 새로 빌드할 때마다 다시 요청합니다.
- 서명이 안정된 프로세스의 일반 하위 프로세스로, 책임을 포기하지 않고 `vphone-cli`를 시작하면 권한을 한 번만 요청합니다.

Launchpad는 자신의 `Contents/MacOS`에 포함된 `vphone-launchpad-launcher`로 두 번째 방식을 사용합니다. macOS는 그 위치의 도구를 감싸는 앱에 귀속시키므로, 요청 창, 사용 목적 설명, 허용은 모두 앱의 것이 됩니다. 강화된 런타임에서는 앱의 주 실행 파일에 해당 리소스 권한(`com.apple.security.device.audio-input`, `com.apple.security.personal-information.location`)이 있어야 하며, 없으면 macOS가 묻지 않고 요청을 거부합니다.

## 버전 호환성

Launchpad는 `minimumBundleComponents`([`VPhoneLaunchpad/VPhoneLaunchpadShared/VPhoneLaunchpadBundleStore.swift`](../../../VPhoneLaunchpad/VPhoneLaunchpadShared/VPhoneLaunchpadBundleStore.swift)에서 설정)보다 오래된 번들을 거부하며, 이전 번들 레이아웃은 로드하지 않습니다. 번들 2.1.0에서 패치 프리셋(`fw patches`, `fw set-patches`, `fw patch --preset`)과 `vphone-escalator` 실행 파일이 추가되었습니다.

## 함께 보기

- [코어 번들과 로컬 빌드](core-bundles.md)
- [Launchpad 명령줄](launchpad-cli.md)
- [호스트 설정](../get-started/host-setup.md)
