# 영구 셰이더 캐시

머신은 컴파일된 GPU 셰이더를 부팅 간에 유지하므로, 애니메이션은 처음 몇 번 실행할 때 셰이더가 컴파일되는 동안에만 끊깁니다. 기존 머신에서 캐시를 켜거나 초기화하려면 이 페이지를 읽으세요.

Standard 프리셋으로 만든 새 머신은 Task3 커널 패치와 게스트 Metal 캐시 재사용을 자동으로 활성화합니다. 호스트는 캐시를 `<machine>/ShaderCache`(예: `~/.vphone/machines/Lychee/ShaderCache`)에 저장합니다. 실행 파일이 바뀌면 새 호스트 캐시 식별 정보를 받습니다.

## 기존 머신에서 켜기

이 기능이 포함된 Core Bundle을 설치하고, 중지된 머신을 그 번들에 연결합니다. 그런 다음 게스트 환경과 커널을 업데이트합니다. 두 업데이트 모두 게스트의 데이터를 유지하며, 복원이나 `fw patch`가 필요하지 않습니다.

### Launchpad에서

1. 머신의 동작 메뉴에서 **Update Guest Environment**를 선택합니다.
2. 머신의 **Patches** 인스펙터에서 **Update Kernel**을 선택합니다.

이제 Standard는 **GPU Task3 shader cache**를 자동으로 선택합니다. 머신별로 명시적으로 해제한 설정은 유지되므로, 패치 선택이 해제되어 있다면 먼저 편집기에서 활성화하세요.

### Launchpad CLI로

```sh
# Replace <version> with the installed Core Bundle version from bundle list.
vphone-launchpad-cli vm stop Lychee
vphone-launchpad-cli vm set-bundle Lychee <version> --update-environment
vphone-launchpad-cli cfw update-kernel Lychee
vphone-launchpad-cli vm start Lychee --wait
```

- `--update-environment`는 게스트 라이브러리와 캐시 재사용 표시 파일을 다시 배포합니다.
- `cfw update-kernel`은 `FirmwareOriginals`에 있는 원본 커널을 현재 선택으로 다시 패치하고 Preboot의 kernelcache를 교체합니다.

Core Bundle 연결만 바꿔서는 설치된 커널이 업데이트되지 않습니다.

### vphone-cli만으로

머신을 끈 상태에서 새 번들의 명령을 root 권한으로 실행합니다.

```sh
sudo vphone-cli cfw update-environment Lychee
sudo vphone-cli cfw update-kernel Lychee
```

`vphone-cli fw patches Lychee`는 대기 중인 패치를 표시합니다. 두 업데이트 명령 모두 머신의 현재 선택을 적용하며, 대기 중인 다른 게스트나 커널 변경도 함께 적용됩니다.

### 원본 커널이 없는 이전 머신

`FirmwareOriginals`에 원본 커널이 없는 머신은 먼저 새 번들로 `fw prepare`와 `fw patch`를 실행하여 대체용 복원 트리에 업데이트된 커널이 들어가게 해야 합니다. 그런 다음 `cfw update-kernel`을 실행합니다. `restore`는 실행하지 마세요.

## 호스트 캐시 초기화

머신을 중지한 뒤 `ShaderCache` 디렉터리를 삭제합니다. 다음에 시작하면 새 호스트 캐시로 시작합니다.

게스트 Metal 캐시는 `Disk.img` 안의 별도 파일이므로, 호스트 캐시를 지운다고 해서 첫 실행 때의 끊김이 모두 재현되지는 않습니다.

## 제한 사항

- Task3는 cloudOS 26.4 커널에만 적용되며, tvOS 프리셋에서는 비활성화되어 있습니다.
- macOS 27보다 이전의 호스트에서는 게스트가 호스트 자체의 최대 버전으로 협상하고 그 버전의 기능을 유지하므로, 호스트 캐시가 부팅마다 새로 만들어집니다.
- 실행 검증은 macOS 27.0.1, cloudOS 26.4, iOS 27.0.1 및 26.6.2 게스트에서 이루어졌습니다. 이전 호스트는 실제로 실행하지 않고 프레임워크 코드로 확인했습니다.

## 함께 보기

- [코어 번들](../launchpad/core-bundles.md)
- [Launchpad CLI](../launchpad/launchpad-cli.md)
- [보관함, 펌웨어, 백업](library-and-backups.md)
