# 펌웨어 호환성

어떤 게스트 펌웨어와 cloudOS 조합이 어떤 호스트에서 부팅되는 것으로 확인되었는지 정리합니다. 새 머신에 사용할 릴리스를 고르기 전에, 또는 생성에 실패해서 그 조합이 테스트된 적이 있는지 알고 싶을 때 확인하세요.

현재 카탈로그가 이 Mac에서 제공하는 항목을 보려면 다음을 실행합니다.

```sh
vphone-cli fw catalog
```

> [!NOTE]
> v2.0.0부터 vphone은 `config.plist`에 `schemaVersion=2`가 있는 머신만 시작합니다. 이전 릴리스에서 만든 머신은 `vm create`로 다시 만드세요. 기존 머신을 그 자리에서 업그레이드하는 방법은 없습니다. 아래 결과는 테스트된 조합을 나타내며, 이전 머신 번들과의 호환성을 뜻하지 않습니다.

## 테스트된 환경

다음은 네이티브 JB 파이프라인으로 처음부터 끝까지 실행한 iPhone17,3 조합입니다. PR #486의 두 행([PR #486](https://github.com/Lakr233/vphone-cli/pull/486))은 잠금 화면까지 도달하고 vphoned ping에 응답했습니다. 새로 실행한 26.6.2 `vm create`도 모든 단계를 마치고 첫 부팅 ping 후 정상적으로 종료되었습니다.

| 검증 | iPhone 복원 IPSW | PCC/cloudOS IPSW | 관찰된 결과 |
| --- | --- | --- | --- |
| PR #486 | `17,3_26.6.2_23G90` | `26.4-23E5207q` | JB 패치, 복원, CFW, 부팅, vphoned ping |
| PR #486 | `17,3_27.0_24A435` | `26.4-23E5207q` | JB 패치, 복원, CFW, 부팅, vphoned ping |
| 연구용 보드 | `17,3_26.6_23G71` | `26.6-23G71` | CLI에서 standard 및 Minimal 프리셋, Launchpad에서 standard(2026-10-20): 디바이스 트리와 SEP 변환, kernelcache 믹스, 복원, CFW, 부팅, vphoned ping |
| 연구용 보드 | `17,3_26.5_23F77` | `26.5-23F75` | CLI에서 standard 프리셋(2026-10-20): 임시 cloudOS 복원으로 얻은 GPU 드라이버, kernelcache 믹스, 복원, CFW, 부팅, vphoned ping |
| 연구용 보드 | `17,3_26.4_23E246` | `26.4-23E244` | CLI에서 standard 프리셋(2026-10-20): 임시 cloudOS 복원으로 얻은 GPU 드라이버, kernelcache 믹스, 복원, CFW, 부팅, vphoned ping |
| 연구용 보드 | `Watch7,18_26.4_23T240` | `26.4-23E244` | CLI와 Launchpad에서 `watchos` 프리셋(2026-10-20): watch kernelcache 믹스, 복원, 부팅, vphoned ping |
| 연구용 보드 | `11,6_18.7.2_22H124` | `18.7.2-22H43` | CLI에서 Minimal 프리셋(2026-10-21): 임시 cloudOS 복원으로 얻은 GPU 드라이버, macOS 15.6.1의 kmutil이 ssh로 링크한 iOS 18 kernelcache 믹스, 복원, 부팅, vphoned ping. 화면, 잠금 화면, 잠금 해제, 홈 스와이프 확인 |
| 연구용 보드 | `11,6_18.1_22B83` | `18.1-22B83` | CLI에서 Minimal 프리셋(2026-10-21): 임시 cloudOS 복원으로 얻은 GPU 드라이버, macOS 15.6.1의 kmutil이 ssh로 링크한 kernelcache 믹스, 복원, 부팅, vphoned. Hello 화면, 잠금 화면, 잠금 해제, 홈 스와이프 확인 |
| 연구용 보드 | `11,6_18.5_22F76` | `18.5-22F76` | CLI에서 Minimal 프리셋(2026-10-21): 임시 cloudOS 복원으로 얻은 GPU 드라이버, macOS 15.6.1의 kmutil이 ssh로 링크한 kernelcache 믹스, 복원, 부팅, vphoned. 잠금 화면, 잠금 해제, 홈 스와이프 확인 |
| 연구용 보드 | `11,6_18.6_22G86` | `18.6-22G86` | Launchpad CLI에서 standard 프리셋(2026-10-24): kernelcache 믹스(캐시 사용), 복원, CFW, 부팅, vphoned, Hello 화면. 두 Frida 패치를 허용한 상태에서 Frida 17.24.3 attach, spawn, Interceptor, Stalker |

### 사용할 cloudOS

특별한 이유가 없다면 cloudOS 26.4 베타(`26.4-23E5207q`)를 사용하세요. 게스트의 커널, SEP, 디바이스 트리가 유래하는 식별 정보인 `vphone600ap`를 포함한 가장 최신 cloudOS이며, `vphone-cli` 외에는 아무것도 필요하지 않습니다.

그 이후의 모든 cloudOS(2026-10-03 확인)에는 PCC 보드와 `vresearch101ap`만 있습니다. `SupportedProductTypes`에서 `iPhone99,11`이 빠졌고, `kernelcache.*.vphone600`, `sep-firmware.vphone600`, `DeviceTree.vphone600ap`도 없습니다. 이런 cloudOS에서는 연구용 보드가 그 역할을 대신합니다(Research Board 패치 세트).

- `fw patch`는 연구용 보드의 디바이스 트리와 SEP를 vphone600용으로 바꾸고, 해당 kernelcache의 레시피에 따라 vphone600 가상화 kext를 넣어 kernelcache를 다시 빌드합니다.
- KDK 추출은 네이티브로 실행되며, 링크만 root 권한이 필요합니다(`vphone-cli fw kernelcache`). [kernelcache 레시피](../../../VPhoneExecutable/VPhoneVirtualization/Resources/kernelcache_recipes/README.md)와 [펌웨어 준비](firmware-preparation.md)를 참고하세요.
- `fw prepare`는 레시피가 없는 cloudOS를 거부합니다.
- `fw catalog`는 각 iOS 릴리스 자체의 cloudOS를 권장 cloudOS 옆에 표시하며, Launchpad는 이를 **Firmware** 아래에서 제공합니다.

| cloudOS | `vresearch101ap` | `vphone600ap` | kernelcache 레시피 |
| --- | --- | --- | --- |
| `26.4-23E5207q`(베타) | 예 | 예 | 필요 없음 |
| `26.4-23E244` | 예 | 아니요 | 예 |
| `26.4.1-23E254` | 예 | 아니요 | 아니요 |
| `26.5-23F75` | 예 | 아니요 | 예 |
| `26.5.2-23F83` | 예 | 아니요 | 아니요 |
| `26.6-23G71` | 예 | 아니요 | 예 |
| `26.6.1-23G82` | 예 | 아니요 | 아니요 |
| `26.7-23H20` | 예 | 아니요 | 예 |

다른 iPhone 및 iPad 버전도 `26.4-23E5207q`에서 동작할 수 있지만, 같은 종단 간 검증은 거치지 않았습니다.

### iOS 18 게스트

iOS 18.1~18.7.2는 해당 릴리스 자체의 cloudOS에서, iPhone XS 계열 IPSW의 사용자 영역으로 실행됩니다.

- `vm create --device iPhone11,6`으로 만듭니다. 기본 프리셋은 Minimal이며, `--preset standard`는 18.6에서 확인했습니다.
- `fw catalog --device iPhone11,6`으로 릴리스 목록을 볼 수 있습니다.
- 이 커널은 kernel-first 레이아웃입니다. macOS 26.4부터는 macOS 15 또는 26.0~26.3을 실행하는 다른 Mac이나 macOS 가상 머신이 ssh로 믹스를 링크합니다(`VPHONE_KMUTIL_SSH`, [펌웨어 준비](firmware-preparation.md) 참고).
- Launchpad는 이를 iPhone XS Max로 제공하며, 그 Mac을 macOS 빌더로 사용합니다.

18.1, 18.5, 18.7.2는 가상 머신에서 확인했으며, 나머지 네 레시피는 아직 부팅해 보지 않았습니다.

### iOS 27.0.1의 iPhone17,3

iOS 27.0.1(24A446)은 번들 2.5.0 이하에서 첫 부팅에 실패합니다(2026-10-04 재현, 수정하지 않은 Apple launchd로도 동일). TXM의 selector-24 사전 검사가 init 시점에 모든 바이너리를 거부하고, 부팅이 `unexpected SIGKILL of init`으로 패닉합니다. `txm-boot-precheck_admission` 패치가 이를 해결합니다([연구 기록](../../../Research/Firmware/txm_selector24_cms_gate.md) 참고). 이 패치를 적용하면 `26.4-23E5207q`의 iPhone17,3 27.0.1이 게스트까지 부팅되고 vphoned `device.info`에 응답합니다(같은 날 확인). 이 패치가 포함된 첫 릴리스는 번들 2.6.0입니다.

## macOS 26.6.2 호스트

2026-10-23에 Core Bundle 2.12.1로, 2026-10-24에 Core Bundle 2.12.2로 다시 Mac mini M4 호스트(Mac16,10, 16 GB, macOS 26.6.2 25G83)에서 확인했습니다. 모든 머신은 CLI에서 처음부터 만들었습니다. 연구용 보드 조합은 사용자 권한으로 kernelcache 믹스를 준비하고 sudo로 링크한 뒤 `sudo vphone-cli vm create`를 실행했습니다. '기본값'은 이 Mac에서 `fw catalog`가 해당 기기에 제공하는 가장 최신 조합으로, Launchpad의 New Machine이 선택하는 조합입니다. 각 머신은 이후 헤드리스로 두 번 부팅했으며, vphoned가 응답하고 `device.info`가 해당 릴리스를 보고했으며 게스트의 시리얼 로그에 패닉이 없었습니다.

| 게스트 | 펌웨어 | cloudOS | 결과 |
| --- | --- | --- | --- |
| iPhone17,3 | iOS 27.0.1(기본값) | `26.4-23E5207q` | 템플릿 빌드, 복제, 2회 부팅 |
| iPhone18,2 | iOS 27.0.1(기본값) | `26.4-23E5207q` | 템플릿 빌드, 복제, 2회 부팅 |
| iPad16,1 | iPadOS 27.0.1(기본값) | `26.4-23E5207q` | 템플릿 빌드, 복제, 2회 부팅 |
| iPhone17,3 | iOS 26.6.2 | `26.4-23E5207q` | 템플릿 빌드, 복제, 2회 부팅 |
| iPhone17,3 | iOS 26.6.2 | `26.6-23G71` | 연구용 보드: 네이티브 KDK 추출, 인증 스텁이 남지 않은 macOS 26 링크, kernelcache 패치 28개, 2회 부팅 |
| iPhone17,3 | iOS 26.5 | `26.5-23F75` | 연구용 보드, 위와 동일 |
| iPhone17,3 | iOS 26.4 | `26.4-23E244` | 연구용 보드, 위와 동일 |
| iPhone17,3 | iOS 18.6.2 | `26.1-23B85` | 템플릿 빌드, 복제, 2회 부팅 |
| iPhone11,6 | iOS 18.7.2(기본값) | `18.7.2-22H43` | Minimal, macOS 15.7.7 가상 머신의 kmutil이 ssh로 믹스 링크, 2회 부팅 |
| iPhone11,6 | iOS 18.6 | `18.6-22G86` | 위와 동일: 이 레시피의 첫 부팅 |
| iPhone11,6 | iOS 18.7 | `18.7-22H20` | 위와 동일: 이 레시피의 첫 부팅 |
| Watch7,18 | watchOS 26.4(기본값) | `26.4-23E244` | `watchos` 프리셋, watch kernelcache 믹스, 2회 부팅 |
| AppleTV5,3 | tvOS 26.6(기본값) | `26.4-23E5207q` | `tvos` 프리셋, 2회 부팅 |
| AppleTV14,1 | tvOS 26.6(macOS 26에서 기본값) | `26.4-23E5207q` | `tvos-4k` 프리셋, 26.6 OTA 사용자 영역, 2회 부팅 |
| AudioAccessory5,1 | HomePod 소프트웨어 27.0(macOS 26에서 기본값) | `26.4-23E5207q` | `homepod-mini` 프리셋, 2회 부팅 |
| AppleTV14,1 | tvOS 27.0 | — | 다운로드 전에 거부됨: macOS 27 필요 |
| AudioAccessory5,1 | HomePod 소프트웨어 27.2 | — | 다운로드 전에 거부됨: macOS 27 필요 |

tvOS 27.0(24J361)과 HomePod 소프트웨어 27.2(24K120) OTA는 페이로드를 LZRAVEN으로 압축하며, 이를 풀 수 있는 것은 macOS 27뿐입니다. 이전 Mac에서는 `fw catalog`가 이들을 제외하므로, 해당 기기에 대한 Launchpad의 기본값은 tvOS 26.6과 HomePod 소프트웨어 27.0이 되고, 이 중 하나를 직접 지정하면 다운로드 전에 거부됩니다.

Apple TV 4K(4세대), `AppleTV18,1` / `J265AP`는 초기 구동(bring-up) 용도로만 제공되며, tvOS 27.2 베타(`24K120`)를 사용합니다. Apple TV HD 26.6 복원 기반 위에 그 전체 OTA를 얹고 cloudOS 26.4 베타(`23E5207q`)를 사용합니다. macOS 27과 `tvos-4k` 프리셋이 필요합니다. 2026-10-24에 머신 하나를 복원하고 커스텀 펌웨어를 설치한 뒤 두 번 콜드 부팅하여 vphoned와 기존 TVSetup의 4K 언어 화면까지 도달했지만, 설정 자체는 완료하지 않았습니다. 위의 테스트 표에는 포함되지 않습니다. [초기 구동 기록](../../../Research/Firmware/tvos_support.md#apple-tv-4k-4th-generation)을 참고하세요.

cloudOS 26.7(23H20)에는 짝을 이룰 iPhone 릴리스가 없습니다. iOS 26.6.2의 사용자 영역으로 준비하면 믹스가 링크되고 kernelcache 패치 28개가 적용되지만, CFW 패치 `_vm_fault_enter_prepare`가 그 커널에서 적용 위치를 찾지 못합니다. 아직 부팅되지 않았습니다.

> [!TIP]
> `vphone-escalator`는 허용 목록을 amfid의 메모리에 보관하므로, amfid가 재시작되면 허용 목록이 사라집니다. 이 호스트에서도 실행 도중 한 번 그런 일이 있었습니다. Launchpad는 AMFI가 번들을 거부하면 다시 허용합니다. CLI에서는 `host preflight`가 출력하는 `vphone-escalator allow` 명령을 다시 실행하세요.

## 다른 iPhone 모델

iPhone17,3 이외의 모델은 [다른 iPhone 모델](iphone-models.md)에서 설명합니다.

| 호스트 | iPhone 복원 IPSW | PCC/cloudOS IPSW | 관찰된 결과 |
| --- | --- | --- | --- |
| Mac17,9 (M5 Pro) 27.0.1 | `18,1_26.6.2_23G90` (iPhone 17 Pro) | `26.4-23E5207q` | Launchpad `vm create`(2.5.1 로컬 번들): 준비, 패치, 복원, CFW, 402x874 pt @3x 홈 화면까지 부팅, `model` iPhone18,1, vphoned ping |
| Mac17,9 (M5 Pro) 27.0.1 | `18,2_27.0.1_24A446` (iPhone 17 Pro Max) | `26.4-23E5207q` | `kernel-boot-shared_region_size` 패치로 **부팅됨**(2026-10-06, 번들 2.6.0-local.0d5e6f90): `dyld cache mapped system-wide`, 패닉 0회, vphoned가 27.0.1로 응답, 440x956 pt @3x 홈 화면 |
| Mac17,7 (M5 Max) 26.4 | `19,2_27.0.1_24A446` (iPhone 18 Pro) | `26.4-23E5207q` | 통합된 ARM64E_X1 호환성으로 **부팅됨**(2026-10-17): 깨끗한 오프라인 복원, 루트 봉인 검증, vphoned ping, 설정, Safari, 계산기 실행 |

### iOS 27의 iPhone18,1 및 iPhone18,2

이 기기에는 `kernel-boot-shared_region_size` 패치가 필요합니다([이슈 #596](https://github.com/Lakr233/vphone-cli/issues/596), 27.0 및 27.0.1). 2026-10-06부터 iOS 27 기반의 `standard` 프리셋에서 켜져 있습니다.

27.0.1에서 이 기기의 dyld 공유 캐시는 `sharedRegionSize`를 `0x185804000`으로 기록하는데, 이는 cloudOS 26.4 게스트 커널의 공유 영역 `0x180000000`보다 큽니다. 그래서 `dyld-boot-maxslide`로 슬라이드를 없애도 캐시를 매핑할 수 없습니다. 패치가 없으면 launchd가 첫 부팅에서 `Library not loaded: /usr/lib/libSystem.B.dylib`로 패닉합니다. iPhone17,3의 27.0.1 캐시(`0x17D508000`)는 여전히 들어갑니다.

이 패치는 arm64 영역을 `0x1C0000000`으로 넓힙니다. 26.4 커널 자체의 태스크 맵 상한 아래에 머무는 가장 큰 크기입니다. 머신의 커널에 패치가 들어 있으면(`PatchReceipt.plist`에 기록됨) `cfw install`이 넓어진 영역을 기준으로 캐시를 측정하므로, 이 기기들도 설치되고 부팅됩니다. 위와 같이 iPhone18,2 27.0.1에서 검증했습니다.

패치가 없으면(이전 번들이거나 패치 선택을 해제한 경우) `cfw install`은 패닉하는 게스트를 남기지 않고 이 설명과 함께 해당 캐시를 거부합니다. iOS 27에는 iPhone17,3을 사용하거나, 이 기기에서는 iOS 26을 사용하세요.

## iPadOS

iPad 게스트는 [iPadOS 게스트](ipados.md)에서 설명합니다.

| 호스트 | iPad 복원 IPSW | PCC/cloudOS IPSW | 관찰된 결과 |
| --- | --- | --- | --- |
| Mac17,9 (M5 Pro) 27.0.1 | `iPad16,1,iPad16,2_26.6.2_23G90` | `26.4-23E5207q` | 준비, 패치, 복원, CFW(2.2.5 도우미), 744x1133 pt @2x iPadOS 홈 화면까지 부팅, `model` iPad16,1, vphoned ping |
| Mac17,9 (M5 Pro) 27.0.1 | `iPad16,1,iPad16,2_27.0.1_24A446` | `26.4-23E5207q` | 카탈로그에서 Launchpad `vm create --device iPad16,1`(2.4.0 번들): 준비, 패치, 복원, CFW, 744x1133 pt @2x iPadOS 홈 화면까지 부팅, `model` iPad16,1, `ios_version` 27.0.1, vphoned ping |

## 이전에 보고된 조합

이전 README에 기록된 호스트와 펌웨어 조합입니다. 현재의 단일 모드 흐름보다 앞서거나 같은 vphoned 검증 근거가 없으므로, 현재 지원 범위가 아닌 연구 이력으로 취급하세요.

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

모든 패치와 각 패치가 적용되는 위치는 [패치 목록](../../../Research/0_binary_patch_comparison.md)을 참고하세요.

## 함께 보기

- [펌웨어 준비](firmware-preparation.md)
- [다른 iPhone 모델](iphone-models.md)
- [iPadOS 게스트](ipados.md)
- [머신 생성 및 실행](../machines/create-and-run.md)
