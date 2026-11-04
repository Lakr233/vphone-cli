# 코어 번들과 로컬 빌드

Launchpad의 각 머신은 설치된 `VPhone.bundle` 버전 하나, 즉 코어 번들(Core Bundle)로 실행됩니다. 이 페이지에서는 로컬 빌드를 설치하고, 머신을 그 빌드로 옮기고, 두 빌드를 나란히 비교하는 방법을 설명합니다.

## VPhone.bundle 빌드 테스트하기

1. 저장소 루트에서 번들을 빌드합니다.

   ```sh
   xcodebuild -workspace VPhone.xcworkspace -scheme VPhone \
     -configuration Debug -destination 'platform=macOS,arch=arm64' \
     -derivedDataPath .build/XcodeBundle build
   ```

2. 설치합니다. `<version>-local.<hash>`로 설치되어 기본 번들이 되고, 실행 정책 예외를 받고, 새 `vphone-vm` cdhash가 허용되며, 호스트 사전 점검이 실행됩니다.

   ```sh
   vphone-launchpad-cli bundle install-local .build/XcodeBundle/Build/Products/Debug/VPhone.bundle
   ```

   정확한 버전은 설치 결과와 `bundle list`에 표시됩니다.

3. 기존 머신을 그 빌드로 옮깁니다. `--update-environment`는 새 vphoned와 훅 dylib도 다시 배포하며, 머신이 중지되어 있어야 합니다.

   ```sh
   vphone-launchpad-cli vm set-bundle research-01 2.4.0-local.1a2b3c4d --update-environment
   ```

4. 머신을 시작하고 확인합니다.

   ```sh
   vphone-launchpad-cli vm start research-01 --wait
   vphone-launchpad-cli guest rpc research-01 device.info
   vphone-launchpad-cli guest rpc research-01 apps.list '{}'
   vphone-launchpad-cli vm log research-01 --lines 100
   vphone-launchpad-cli vm stop research-01
   ```

도우미의 인증은 5분 동안 유지됩니다. 만료된 뒤 도우미가 필요한 첫 단계에서는 창에서와 마찬가지로 Mac에서 관리자 암호를 묻습니다.

기존 가상 머신에서 영구 셰이더 캐시를 활성화하기 위한 일회성 커널 및 게스트 업데이트는 [영구 셰이더 캐시](../storage/shader-cache.md)를 참고하세요.

## 두 빌드 비교하기

기본 번들을 바꾸지 않고 둘 다 설치한 뒤, 각각에 머신을 하나씩 지정합니다.

```sh
vphone-launchpad-cli bundle install-local /path/to/A/VPhone.bundle --keep-default
vphone-launchpad-cli bundle install-local /path/to/B/VPhone.bundle --keep-default
vphone-launchpad-cli bundle list        # note both versions

vphone-launchpad-cli vm create cmp-a --bundle 2.4.0-local.aaaaaaaa
vphone-launchpad-cli vm create cmp-b --bundle 2.4.0-local.bbbbbbbb
```

이렇게 만든 머신은 세 계층 모두가 다릅니다(아래 참고). 같은 부트 체인에서 호스트 프로그램과 게스트 환경만 비교하려면, 창에서 머신을 복제하고 사본을 다른 번들에 다시 연결하세요.

```sh
vphone-launchpad-cli vm set-bundle cmp-b 2.4.0-local.bbbbbbbb --update-environment
```

`vm list`는 각 계층이 어느 번들에서 왔는지 표시합니다. `bundle remove`는 머신이 연결된 버전을 거부하므로, 먼저 그 머신을 다른 번들에 연결하거나 삭제하세요.

## 머신이 번들에 연결되는 방식

모든 머신은 설치된 버전 하나에 연결됩니다. 이 버전은 생성할 때 선택되며 머신 폴더의 `launchpad.json`에 저장됩니다. 번들을 설치해도 머신의 연결은 바뀌지 않습니다.

머신은 세 계층으로 이루어지며, 각 계층은 서로 다른 시점에 번들에서 가져옵니다.

| 계층 | 내용 | 출처 |
| --- | --- | --- |
| Host Programs(호스트 프로그램) | `vphone-cli`, `vphone-vm` | 명령을 실행할 때마다 연결된 번들에서. 새 연결은 다음 시작부터 적용됩니다. |
| Guest Environment(게스트 환경) | vphoned와 훅 dylib | 생성 시 `cfw install`, 이후에는 `cfw update-environment`(중지된 머신). |
| Boot Chain(부트 체인) | 패치된 펌웨어, 복원, CFW 패치 | 생성 시 `fw patch`, `restore`, `cfw install`. |

### 나중에 부트 체인 패치 변경하기

`vphone-cli fw set-patches`로 패치 선택을 바꾸고, `vphone-cli fw patches <vm>`으로 아직 게스트에 반영되지 않은 항목을 확인합니다. Launchpad는 인스펙터에 그 개수를 표시합니다. 패치 종류마다 게스트에 반영되는 방식이 다릅니다.

| 패치 | 적용 방법 |
| --- | --- |
| 게스트 패치 | 다음 `cfw update-environment` |
| AVPBooter | 다음 `fw patch` |
| 커널 패치 | `cfw update-kernel`(데이터 유지, 복원 트리 불필요) |
| 나머지 부트 체인(TXM, DeviceTree, LLB) | 게스트를 지우는 복원으로만 가능 |

## 기본 번들

**default**(기본) 번들(이전 이름 "active")이 결정하는 것은 다음뿐입니다.

- `--bundle`을 지정하지 않았을 때 `vm create`가 연결할 버전
- `exec`와 보관함 전체에 적용되는 명령이 실행될 번들

`--keep-default`를 넘기지 않으면 새로 설치한 번들이 기본 번들이 됩니다. Launchpad 세션에서 머신을 처음 시작할 때 번들을 한 번 확인합니다(실행 정책 예외, AMFI, 호스트 사전 점검).

## 버전 이름

로컬 빌드는 `<version>-local.<hash>`로 설치되며, 해시는 번들의 코드 서명 봉인에서 가져오므로 같은 버전의 두 빌드가 나란히 존재할 수 있습니다. 이전 저장소에는 `<version>-local`이나 `<version>-ci.<commit>`이 남아 있을 수 있습니다.

## 함께 보기

- [Launchpad 명령줄](launchpad-cli.md)
- [번들 통합](bundle-integration.md)
- [다운로드](../get-started/downloads.md)
