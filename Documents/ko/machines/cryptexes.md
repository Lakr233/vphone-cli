# Cryptex

Cryptex는 게스트가 실행 중에 마운트하는 서명된 디스크 이미지로, 그 안의 프로그램을 위한 트러스트 캐시를 함께 갖습니다. `minimal` 게스트를 다시 복원하지 않고 자신의 프로그램을 실행할 때 사용합니다.

## 시작하기 전에

- `minimal` 프리셋으로 머신을 만들고, 새 머신의 패치 페이지에서 **Trusted darwinOS environment** 상자를 켭니다. `vphone-launchpad-cli`에서는 `--preset minimal --allow filesystem-exp-trusted_darwinos`입니다. 이 상자는 복원할 때만 적용됩니다. 기존 머신에서 켜려면 머신을 다시 만들어야 합니다.
- iOS 26 또는 iOS 18 IPSW를 사용하세요. iOS 26.5와 cloudOS 26.5, iOS 18.6과 cloudOS 18.6 조합에서 동작합니다. iOS 27은 이 환경에서 부팅되지 않으므로, IPSW가 iOS 27이면 vphone-cli가 복원을 시작하기 전에 이 옵션을 거부합니다.
- macOS Security Research 도구(PCC Virtual Research Environment)를 설치합니다. VM 창은 그 안의 `/System/Library/SecurityResearch/usr/bin/cryptexctl.research`로 cryptex를 빌드합니다.
- 게스트에 네트워크가 필요합니다. cryptex를 설치할 때 Apple의 서명 서버에 이 게스트용 개인화를 요청합니다.

이 환경에서 게스트는 Restricted Execution Mode를 적용하며, 연구용 보드 cloudOS(26.5~26.7)에서 실행되는 게스트는 개발자 모드를 켤 수 없습니다.

## cryptex 설치

1. cryptex에 담을 파일을 cryptex 안에서의 배치 그대로 폴더에 넣습니다. 예:

   ```
   mycryptex/
     usr/bin/server
     Library/LaunchDaemons/server.plist
   ```

   각 프로그램에 필요한 인타이틀먼트를 붙여 임시(ad hoc) 서명합니다(`codesign -s - --entitlements entitlements.plist usr/bin/server`).
2. VM 창에서 **Apps › Install Cryptex…**를 선택하고 그 폴더를 고릅니다.

VM 창이 이 게스트용 cryptex를 빌드해 업로드하고, 게스트가 이를 개인화해 설치합니다. 폴더 이름(확장자 제외)이 cryptex의 식별자가 됩니다. cryptex는 `/private/var/DarwinDataCenterSupportImage/<identifier>`에 마운트됩니다. 위 예의 폴더 `mycryptex`라면 `usr/bin/server`는 게스트에서 `/private/var/DarwinDataCenterSupportImage/mycryptex/usr/bin/server`입니다. 설치 후 알림에 그 경로가 표시됩니다. cryptex의 `Library/LaunchDaemons`에 있는 실행 데몬은 cryptex에서 시작됩니다.

**Apps › List Cryptexes**에서 설치된 cryptex와 각각의 마운트 지점을 볼 수 있습니다.

VM 창에서 설치한 cryptex는 게스트를 다시 시작할 때까지 유지됩니다. 다시 시작한 후에는 다시 설치하세요. 재시작 후에도 유지하려면 스크립트에서 `persist`로 설치하세요(아래 참고).

여러 cryptex를 동시에 설치할 수 있으며, 각각 자신의 경로를 갖습니다. 폴더 이름이 이미 cryptex로 설치되어 있으면 거부됩니다. 먼저 그 cryptex를 `cryptex.uninstall`로 제거하거나(아래 참조) 폴더 이름을 바꾸십시오.

## `.cxbd`가 아니라 폴더를 선택하십시오

Install Cryptex…는 `.cxbd`도 그대로 설치하지만, 이 게스트용으로 만든 것만 해당합니다. 즉 `cryptexctl.research create`가 `--BORD=0x90 --CHIP=0xfe01`로 만드는, vresearch101 보드용 Cryptex1 cryptex입니다. 그 밖의 경우에는 폴더를 선택하십시오.

Security Research Device iPhone용으로 빌드한 cryptex는 설치되지 않습니다. SRD 예제와 그 Makefile이 사용하는 `cryptexctl create --research`가 이런 종류를 만듭니다. Install Cryptex…는 이를 알려 주고 업로드 전에 중단합니다. 대신 그것을 빌드한 폴더를 선택하십시오. Makefile로 빌드했다면 대개 `build/<identifier>.root`, 즉 그 내용이 디스크 이미지에 들어간 폴더입니다.

## 스크립트에서

vphoned는 [자동화 API](automation-api.md)를 통해 `cryptex.list`, `cryptex.install`, `cryptex.uninstall`을 제공합니다. `cryptex.install`은 `/var/mobile/Documents/vphone-cryptexes` 아래에 업로드된 `.cxbd`와 그것을 만들 때 쓴 variant를 받습니다. `persist: true`를 지정하면 vphoned가 게스트를 다시 시작할 때마다 그 cryptex를 다시 설치합니다. Apple 서명 서버에 다시 요청해야 하면 게스트에 네트워크가 필요합니다. `cryptex.list`는 이런 cryptex를 `persisted`에 보여 주고, `cryptex.uninstall`은 이를 완전히 제거합니다.

구현에 대해서는 [`Research/Firmware/trusted_darwinos_cryptexes.md`](../../../Research/Firmware/trusted_darwinos_cryptexes.md)를 참조하십시오.
