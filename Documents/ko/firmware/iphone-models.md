# 다른 iPhone 모델

iPhone17,3(iPhone 16) 대신 다른 iPhone의 복원 IPSW에서 iOS를 가져오는 게스트를 실행하는 방법입니다. 특정 모델의 사용자 영역, 패널 크기, 식별 정보가 필요할 때 사용하세요.

[iPad 게스트](ipados.md)와 마찬가지로 가상 하드웨어는 그대로입니다. 부트 체인, 커널, SEP, 디바이스 트리는 여전히 PCC cloudOS IPSW(`vresearch101ap` / `vphone600ap`)에서 가져옵니다. 사용자 영역만 선택한 모델의 IPSW에서 가져오며, 게스트가 부팅하는 디바이스 트리를 그 모델로 보이도록 다시 씁니다.

## 만들기

Launchpad에서 **New Machine**을 선택하고 **Device**에서 모델을, **iOS**에서 릴리스를 선택합니다.

터미널에서 Launchpad를 통해 만들려면 다음을 실행합니다.

```sh
vphone-launchpad-cli vm create iphone17pro --device iPhone18,1
```

`vphone-cli`를 사용할 때는 모델의 IPSW와 cloudOS를 넘깁니다.

```sh
vphone-cli vm create iphone17pro \
  --iphone-source 'https://updates.cdn-apple.com/2026SummerFCS/f768ecdf-e037-44e6-bfa6-949b6d127c4f/iPhone18,1_26.6.2_23G90_Restore.ipsw' \
  --cloudos-source 'https://updates.cdn-apple.com/private-cloud-compute/c0ecdb4b310cf5239ab2b248dd3098eec297dc5aa3bbe6ada27273262b0b8b64'
```

iPhone 모델마다 자체 IPSW가 있으므로, 소스를 명시하면 `--device`가 필요하지 않습니다.

릴리스를 찾으려면 `fw catalog`를 실행합니다. iPhone 16 및 17 모델의 26.0~27.0.1 릴리스(iPhone 17e는 26.3.1부터)와 iPhone 18 Pro의 27.0.1을, 같은 릴리스의 iPhone17,3이 사용하는 cloudOS와 함께 표시합니다. 모델 하나의 릴리스만 보려면 다음을 실행합니다.

```sh
vphone-cli fw catalog --device iPhone18,1
```

## 지원 기기

| 제품 | 모델 | 보드 | 패널 | 포인트 @3x |
| --- | --- | --- | --- | --- |
| `iPhone17,3` | iPhone 16 | D47AP | 1290x2796 @ 460 ppi | 430x932 |
| `iPhone17,4` | iPhone 16 Plus | D48AP | 1290x2796 @ 460 ppi | 430x932 |
| `iPhone17,1` | iPhone 16 Pro | D93AP | 1206x2622 @ 460 ppi | 402x874 |
| `iPhone17,2` | iPhone 16 Pro Max | D94AP | 1320x2868 @ 460 ppi | 440x956 |
| `iPhone17,5` | iPhone 16e | V59AP | 1170x2532 @ 460 ppi | 390x844 |
| `iPhone18,3` | iPhone 17 | V57AP | 1206x2622 @ 460 ppi | 402x874 |
| `iPhone18,4` | iPhone Air | D23AP | 1260x2736 @ 460 ppi | 420x912 |
| `iPhone18,1` | iPhone 17 Pro | V53AP | 1206x2622 @ 460 ppi | 402x874 |
| `iPhone18,2` | iPhone 17 Pro Max | V54AP | 1320x2868 @ 460 ppi | 440x956 |
| `iPhone18,5` | iPhone 17e | V159AP | 1170x2532 @ 460 ppi | 390x844 |
| `iPhone19,2` | iPhone 18 Pro | V63AP | 1206x2622 @ 460 ppi | 402x874 |

iPhone17,3을 포함한 모든 모델은 자체 디바이스 트리에서 패널과 식별 정보를 가져옵니다. iPhone17,3의 패널은 원래부터 사용하던 디스플레이 그대로입니다.

iPhone 17 Pro, 17 Pro Max, 18 Pro는 부팅 검증 기록이 있습니다. [호환성](compatibility.md)의 '다른 iPhone 모델' 절을 참고하세요. iPhone 17 Pro와 17 Pro Max는 iOS 27에서 패치가 필요하며, 그 내용도 같은 곳에 있습니다.

> [!WARNING]
> iPhone19,2는 ARM64E_X1을 사용합니다. X1을 네이티브로 지원하지 않는 호스트에서는 standard 프리셋이 지원되지 않는 명령어를 낮춰 변환하며, 이 때문에 PC에 묶인 포인터 인증이 약해집니다.

## 다른 iPhone에서 달라지는 점

[iPadOS 게스트](ipados.md)의 'iPad에서 달라지는 점'에 나열된 내용이 모두 적용되며, 두 가지가 다릅니다.

- 보드의 `/product` 값이 같은 방식으로 vphone600 자리 표시자를 대체하지만, iPhone 보드는 iPhone 속성을 유지합니다. Dynamic Island, 간편 접근, OLED, 음량 버튼 형상, CarPlay, Watch 페어링은 제거되지 않고 보드에서 가져옵니다. 패치 ID는 `devicetree-cfw-ipad_*`입니다. iPhone에서 사용하기 전에 이름이 정해졌기 때문입니다.
- LLB는 디스플레이 배율 패치를 받지 않습니다. 반가상화 디스플레이의 부트 비디오 워드는 3x이며, 이는 이미 iPhone의 배율입니다.

## 함께 보기

- [iPadOS 게스트](ipados.md)
- [펌웨어 호환성](compatibility.md)
- [머신 생성 및 실행](../machines/create-and-run.md)
