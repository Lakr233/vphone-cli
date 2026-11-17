# 펌웨어 준비

펌웨어를 패치하기 전에 `vm create`와 `fw prepare`가 두 IPSW로 하는 일과, vphone600 구성 요소가 없는 cloudOS에 필요한 추가 단계를 설명합니다. 단계를 직접 실행하거나, GPU 드라이버를 재사용하거나, 연구용 보드 조합으로 머신을 만들 때 읽으세요.

## GPU 드라이버

`fw prepare`는 하이브리드 iPhone 복원을 빌드하기 전에 cloudOS에서 반가상화 GPU 드라이버를 가져와야 합니다. 그 과정은 다음과 같습니다.

1. 네트워크 장치가 없는 임시 vphone 가상 머신을 만들고 DFU로 시작합니다.
2. 선택한 cloudOS IPSW를 vphone 자체의 복원 백엔드로 그 가상 머신에 복원합니다.
3. 복원된 System 볼륨을 읽기 전용으로 마운트하고 GPU 번들을 추출합니다.
4. 임시 가상 머신을 삭제합니다.

추출한 번들은 cloudOS 빌드별로 `~/.vphone/gpu-drivers/`에 캐시되므로, 같은 cloudOS를 사용하는 이후 머신은 임시 복원을 건너뜁니다.

이전에 추출한 번들을 재사용하려면 `vm create`나 `fw prepare`에 넘기세요.

```sh
vphone-cli fw prepare myphone \
  --gpu-driver-bundle /path/to/AppleParavirtGPUMetalIOGPUFamily.bundle
```

CLI는 번들의 iPhoneOS 플랫폼 버전을 선택한 cloudOS 버전과 대조합니다. 각 복원은 자신의 티켓을 온라인으로 받습니다.

번들에는 arm64e GPU 컴파일러 플러그인도 포함되어 있습니다. `fw prepare`는 패치와 설치 전에 이를 준비된 GPU 번들에 복사합니다.

## 연구용 보드 조합

26.4 베타 이후의 cloudOS에는 vphone600 구성 요소가 없으므로 연구용 보드가 그 역할을 대신합니다([호환성](compatibility.md)의 '사용할 cloudOS' 참고). 연구용 보드의 kernelcache는 vphone600 가상화 kext를 넣어 다시 빌드됩니다. 모든 단계가 사용자 권한으로 실행되며 sudo가 필요하지 않습니다.

1. 평소처럼 `fw prepare`를 실행합니다.
2. 믹스를 빌드합니다.

   ```sh
   vphone-cli fw kernelcache myphone
   ```

3. `fw patch`로 계속합니다. `fw patch`는 캐시에서 믹스를 가져옵니다. 사용자 권한으로 실행하면 `fw patch`가 믹스를 직접 빌드하기도 하며, root로 실행하면 캐시에서 가져오기만 합니다.

`fw kernelcache`의 이전 `--ipsw` 인자는 여전히 받지만 무시됩니다.

## 믹스를 링크하는 kmutil

커널은 Apple이 링크한 레이아웃으로만 부팅되며, 그 레이아웃은 링크하는 kmutil이 정합니다. macOS 15와 26.0~26.3은 커널을 앞에, macOS 26.4 이상은 뒤에 두고, macOS 27은 kext의 auth stub도 남깁니다. 모든 kernelcache에는 Apple이 빌드할 때 사용한 kmutil 버전이 기록되어 있으므로, `fw kernelcache`는 어떤 macOS에서든 같은 버전으로 믹스를 링크합니다.

| kernelcache | kmutil | 출처 |
| --- | --- | --- |
| iOS 18.1~18.3.1 | 463.40.2 | macOS 15.1 (24B83) |
| iOS 18.5~18.7.2 | 463.100.7 | macOS 15.6.1 (24G90) |
| iOS 26.4~26.7, watchOS 26.4, HomePod 26.5 | 487.100.11 | macOS 26.5 (25F71) |
| iOS 27.2 | 514.40.8 | macOS 27.2.1 (26B131) |

이 Mac의 kmutil이 그 버전이면 그것을 사용합니다. 그렇지 않으면 해당 macOS의 복구 이미지(약 1GB)를 Apple의 IPSW에서 한 번 내려받아, 그 안의 kmutil과 커널 컬렉션 빌더를 `~/.vphone/kernelcache/kmutil/<version>`(몇 MB)에 보관하고 이미지는 삭제합니다. 아무것도 설치되지 않으며 호스트 설정도 바뀌지 않습니다. 다른 Mac에서 ssh로 링크하던 `VPHONE_KMUTIL_SSH`는 더 이상 사용하지 않습니다.

## 함께 보기

- [펌웨어 호환성](compatibility.md)
- [머신 생성 및 실행](../machines/create-and-run.md)
- [보관함, 펌웨어, 백업](../storage/library-and-backups.md)
- [kernelcache 레시피](../../../VPhoneExecutable/VPhoneVirtualization/Resources/kernelcache_recipes/README.md)
