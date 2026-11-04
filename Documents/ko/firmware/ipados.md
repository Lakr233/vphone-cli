# iPadOS 게스트

vphone 머신에서 iOS 대신 iPadOS를 실행하는 방법입니다. iPad의 사용자 영역, 화면 크기, 멀티태스킹 기능이 필요할 때 사용하세요.

가상 하드웨어는 바뀌지 않습니다. 부트 체인, 커널, SEP, 디바이스 트리는 여전히 PCC cloudOS IPSW(`vresearch101ap` / `vphone600ap`)에서 가져옵니다. 사용자 영역만 iPhone17,3 대신 iPad의 복원 IPSW에서 가져오며, 사용자 영역이 iPad로 인식하도록 디바이스 트리를 다시 씁니다.

![vphone 가상 머신의 iPadOS 홈 화면](../../ipados-demo.jpeg)

## 만들기

### Launchpad에서

1. **New Machine**을 선택합니다.
2. **Device**에서 iPad를, **iPadOS**에서 릴리스를 선택합니다. 권장 cloudOS가 함께 선택됩니다.
3. 카탈로그에 없는 IPSW라면 **Source**를 **Custom IPSWs**로 설정하고, **iPhone IPSW** 필드에 iPad IPSW를, 다른 필드에 cloudOS IPSW를 넣습니다.

**Device** 메뉴는 카탈로그에 iPad가 있는 Core Bundle에서만 나타납니다. 터미널에서는 `vphone-launchpad-cli vm create <name> --device iPad16,1`로 같은 작업을 할 수 있습니다.

### vphone-cli로

iPhone IPSW 자리에 iPad 복원 IPSW를 넘깁니다. cloudOS는 같은 릴리스의 iPhone 게스트가 사용하는 것과 같습니다.

```sh
vphone-cli vm create ipad-mini \
  --iphone-source 'https://updates.cdn-apple.com/2026SummerFCS/cf7db64d-5866-4bf2-bfff-50a32f58bec3/iPad16,1,iPad16,2_26.6.2_23G90_Restore.ipsw' \
  --cloudos-source 'https://updates.cdn-apple.com/private-cloud-compute/c0ecdb4b310cf5239ab2b248dd3098eec297dc5aa3bbe6ada27273262b0b8b64'

# The 13-inch iPad Pro (M5), from the IPSW that also carries the 11-inch
vphone-cli vm create ipad-pro-13 --device iPad17,3 \
  --iphone-source 'https://updates.cdn-apple.com/2026SummerFCS/<…>/iPad17,1,iPad17,2,iPad17,3,iPad17,4_26.6.2_23G90_Restore.ipsw' \
  --cloudos-source 'https://updates.cdn-apple.com/private-cloud-compute/c0ecdb4b310cf5239ab2b248dd3098eec297dc5aa3bbe6ada27273262b0b8b64'
```

릴리스를 찾으려면 다음 명령을 사용합니다.

| 명령 | 표시 내용 |
| --- | --- |
| `vphone-cli fw catalog` | 지원되는 모든 iPad의 iPadOS 릴리스와 각 릴리스의 cloudOS |
| `vphone-cli fw catalog --device iPad16,1` | iPad 한 기종의 릴리스 |
| `vphone-cli fw prepare --device iPad16,1 --list` | 해당 iPad의 내려받을 수 있는 IPSW |
| `vphone-cli fw prepare --device iPad16,1 --iphone-version 26.6.2` | IPSW 하나를 찾습니다 |

`--device`를 지정하고 소스를 지정하지 않으면 `vm create`가 해당 iPad의 릴리스 중에서 선택하도록 보여 줍니다.

### 공유 IPSW에서 모델 선택하기

대부분의 iPad IPSW는 여러 모델을 포함하며, iPad Air와 iPad Pro IPSW에는 두 가지 크기가 모두 들어 있습니다. `--device`가 없으면 `fw prepare`는 IPSW에 나열된 첫 번째 모델(11형)을 사용합니다. 13형을 사용하려면 `fw prepare`나 `vm create`에 `--device iPad17,3`을 넘기세요. Launchpad의 New Machine은 **Device**에서 선택한 모델을 넘기며, **Custom IPSWs**에서는 첫 번째 모델을 사용합니다.

<img src="../../ipados/ipad-pro-13-home.jpg" alt="vphone 가상 머신의 iPad Pro 13형 홈 화면" width="360" />

### 수동 단계

수동 단계는 iPhone 게스트와 같습니다. `vm new`, `fw prepare`, `fw patch`, DFU와 `restore`, `cfw install`, `vm launch` 순서입니다. iPad에서 다르게 동작하는 것은 `fw prepare`와 `fw patch`뿐이며, DFU, `restore`, `cfw install`은 그대로 실행됩니다.

## 지원 기기

| 제품 | 모델 | 보드 | 패널 | 포인트 @2x |
| --- | --- | --- | --- | --- |
| `iPad16,1` | iPad mini(A17 Pro) | J410AP | 1488x2266 @ 326 ppi | 744x1133 |
| `iPad15,7` | iPad(A16) | J481AP | 1640x2360 @ 264 ppi | 820x1180 |
| `iPad15,3` | iPad Air 11형(M3) | J607AP | 1640x2360 @ 264 ppi | 820x1180 |
| `iPad15,5` | iPad Air 13형(M3) | J637AP | 2048x2732 @ 264 ppi | 1024x1366 |
| `iPad16,3` | iPad Pro 11형(M4) | J717AP | 1668x2420 @ 264 ppi | 834x1210 |
| `iPad16,5` | iPad Pro 13형(M4) | J720AP | 2064x2752 @ 264 ppi | 1032x1376 |
| `iPad17,1` | iPad Pro 11형(M5) | J817AP | 1668x2420 @ 264 ppi | 834x1210 |
| `iPad17,3` | iPad Pro 13형(M5) | J820AP | 2064x2752 @ 264 ppi | 1032x1376 |

셀룰러 모델(`iPad16,2`, `iPad15,4`, `iPad15,6`, `iPad16,4`, `iPad16,6`, `iPad17,2`, `iPad17,4`)은 대응하는 Wi-Fi 모델과 IPSW를 공유하며 그 모델로 실행됩니다. 가상 머신에는 베이스밴드가 없습니다. `iPad15,8`은 Wi-Fi 보드가 없는 별도의 IPSW로 배포되며 지원되지 않습니다.

테스트된 조합은 [호환성](compatibility.md)의 'iPadOS' 절에 있습니다.

## iPad에서 달라지는 점

- **`fw prepare`**는 `SupportedProductTypes`로 IPSW를 인식하고, 게스트 보드에 맞는 지우기 식별 정보와 `DeviceMap` 항목을 가져오며(iPad IPSW에는 여러 보드가 포함됨), 제품 유형과 iPad의 디스플레이를 머신의 `config.plist`(`guestProductType`, `screenConfig`)에 기록합니다. 복원 트리의 이름은 `iPhoneOS_iPad16,1_<version>_<build>_Restore`입니다. `iPhone` 접두사는 기기를 뜻하는 것이 아니라, 모든 읽기 코드가 일치시키는 복원 트리 명명 규칙입니다.
- **두 개의 디바이스 트리.** 하이브리드 매니페스트는 보통 `DeviceTree`와 `RestoreDeviceTree`가 같은 vphone600 파일을 가리킵니다. iPad에서는 `DeviceTree`가 사본인 `Firmware/all_flash/DeviceTree.vphone600ap.guest.im4p`를 가리킵니다. 복원은 `restored_external`이 매니페스트와 대조하는 원래 식별 정보(`iPhone99,11`)로 부팅하고, 게스트는 사본으로 부팅합니다.
- **`fw patch`**는 그 사본에 iPad의 식별 정보와 표시 정보를 넣습니다(패치 세트 `devicetree`, 항목 `devicetree-cfw-ipad_*`).
  - 루트의 `model`, `target-type`, `target-sub-type`은 보드와 같게 하고(iPad mini는 `iPad16,1`, `J410`, `J410AP`), `compatible`은 보드를 첫 번째로, `VPHONE600AP`를 두 번째로 둡니다.
  - `/product`: 보드의 아트워크 idiom, 하위 유형과 배율, 제품 이름, 크롬, 카메라와 버튼 형상, 멀티태스킹 기능(`medusa-overlay-app-capability`, `ui-floating-live-app`, `ui-overlay-app`, `ui-pinned-app`, 그리고 스테이지 매니저가 없는 보드에서는 `disable-chamois`), 제품 유형과 고유 모델. 모두 복원 트리에 보존된 보드의 `DeviceTree.<board>.im4p`에서 읽습니다.
  - iPhone 전용 `syscfg` 자리 표시자(Dynamic Island, 간편 접근, 벨소리 스위치, 음량 버튼 형상, CarPlay, Watch 페어링)는 제거됩니다.

  가상 하드웨어는 vphone600 설명을 유지합니다. GPU 기능 세트, 프레임버퍼, 메모리 등급, 부트 플래그가 그대로입니다.
- **LLB**는 iPad 게스트에서 `llb-cfw-display_scale` 패치를 하나 더 받습니다. LLB는 반가상화 디스플레이의 부트 비디오 워드로 `/chosen/display-scale`을 채우는데, 이 값은 항상 3x이고 MobileGestalt가 이 속성을 화면 배율로 사용하므로, iPad는 496x755 포인트 캔버스를 받게 됩니다. 이 패치는 LLB가 iPad 자체의 배율(2x, iPad mini는 744x1133 포인트)을 쓰도록 합니다.
- **`cfw install`**은 설치된 디바이스 트리를 건드리지 않습니다. iPhone17,3의 복원 후 식별 정보 재작성(`preboot-exp-devicetree_identity`)은 iPad 게스트에서 건너뜁니다.
- **머신 창**은 `screenConfig`를 따르므로 iPad의 화면비로 열립니다.

<img src="../../ipados/display-scale-3x-before.jpg" alt="LLB 패치 전, 3x 디스플레이 배율의 iPad 게스트" width="240" />

## 다른 iPad 추가하기

iPad 모델을 추가하려면 [`VPhoneGuestDevice`](../../../VPhoneKit/VPhoneCoreKit/VirtualMachine/VPhoneGuestDevice.swift)에 제품 유형, 보드, 패널을 담은 한 줄만 추가하면 됩니다. 디바이스 트리에 필요한 나머지는 모두 IPSW에 있는 보드 자체의 `DeviceTree.<board>.im4p`에서 읽습니다.

## 함께 보기

- [다른 iPhone 모델](iphone-models.md)
- [펌웨어 호환성](compatibility.md)
- [머신 생성 및 실행](../machines/create-and-run.md)
