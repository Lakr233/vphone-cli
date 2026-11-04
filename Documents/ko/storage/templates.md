# 템플릿

템플릿은 `vm create`가 새 머신을 복제해 내는 완성되고 고정된 머신입니다. 특정 옵션 조합으로 처음 생성할 때 템플릿이 만들어지며, 이후 같은 옵션으로 생성하면 몇 초 만에 끝나고 아무것도 내려받지 않습니다. 템플릿을 만들고, 경량화하고, 정리하는 방식을 제어하려면 이 페이지를 읽으세요.

## 템플릿에서 머신 만들기

`vm create`는 기본적으로 템플릿을 사용합니다.

```sh
vphone-cli vm create phone-a --iphone-source … --cloudos-source …   # builds the template, clones phone-a
vphone-cli vm create phone-b --iphone-source … --cloudos-source …   # clones phone-b, no restore
vphone-cli vm create phone-c --template 3f2a91c0d4e7 --cpu 4 --memory 6144
```

- 일치하는 템플릿이 있으면 `vm create`는 새 식별 정보로 머신을 복제하고, 요청한 CPU, 메모리, 네트워크를 지정한 뒤, 한 번 부팅하여 vphoned를 확인합니다. root 권한도 IPSW도 필요하지 않습니다.
- 없으면 필요에 따라 IPSW를 내려받고, 준비 폴더에서 전체 파이프라인을 실행하여 템플릿을 만들고 고정한 뒤, 그 템플릿에서 머신을 복제합니다.
- `--template <id>`는 식별자 또는 네 자리 이상의 고유한 접두사로 지정한 템플릿에서 복제하며, IPSW 옵션을 받지 않습니다. `--device`, `--preset`, `--disk-size`와 경량화 스위치를 지정하면 템플릿과 일치해야 합니다. 복제본에서는 이를 바꿀 수 없습니다.
- `--no-template`은 머신을 자체 키로 단독 복원하며, 경량화 스위치를 받지 않습니다.

가상 머신을 직접 템플릿으로 만들거나, `vm create`가 어떤 템플릿을 사용할지 확인하거나, Launchpad가 템플릿을 만드는 방식을 보려면 [템플릿 만들기와 찾기](template-building.md)를 읽으세요.

## 템플릿을 일치시키는 방법

무엇이든 복원하기 전에 `vm create`는 옵션과 두 IPSW로 템플릿 키를 계산합니다. 키에는 다음이 포함됩니다.

- 게스트 기기
- iOS 및 cloudOS 버전과 빌드
- 패치 프리셋과 그 프리셋이 결정하는 부트 체인 패치. 번들에 포함되지 않은 프리셋(프리셋 파일 또는 `~/.vphone/patches_presets`에 있는 프리셋)이라면 게스트 패치를 포함해 그 프리셋이 결정하는 모든 패치가 포함됩니다. 이런 프리셋은 같은 식별자로도 내용이 바뀔 수 있고, 복제본은 템플릿의 게스트 패치를 그대로 유지하기 때문입니다.
- 번들 시리즈(2.9.x라면 `2.9`)
- 디스크 크기
- 게스트의 System 볼륨에서 정리하는 항목(`--trim`)과 유지하는 언어
- 아래의 경량화 스위치

CPU, 메모리, 화면, 네트워크는 키에 포함되지 않습니다.

빌드 정보는 IPSW가 로컬 파일이거나 이미 IPSW 캐시에 있으면 IPSW에서 가져옵니다. 그렇지 않으면 `vm template find`가 계산하는 방식대로, 같은 두 소스로 기록된 템플릿에서 가져옵니다([템플릿 만들기와 찾기](template-building.md)의 '템플릿 찾기' 참고). 삭제된 로컬 IPSW는 없는 것으로 간주합니다.

### 템플릿 만들기

일치하는 템플릿이 없으면 전체 파이프라인이 `.templates/.building-<id>-<uuid>/`에서 실행됩니다. `cfw install`, 오프라인 정리, 설정 부팅 순서입니다. 결과는 고정된 뒤 한 번에 `<library>/.templates/<id>/`로 이름이 바뀝니다.

- 복원 트리는 `--keep-artifacts`와 관계없이 고정 전에 삭제됩니다. 약 11 GB에 달하는 복원 트리가 템플릿이 존재하는 동안 계속 남게 되는데, 어떤 복제본도 이를 사용할 수 없기 때문입니다. `--keep-artifacts`는 `--no-template`과 함께 쓸 때만 복원 트리를 보존하며, `vm template adopt`도 이를 삭제합니다.
- 같은 키로 두 번째 `vm create`를 실행하면 두 번째 사본을 복원하지 않고 첫 번째가 끝나기를 기다립니다.
- 실패한 빌드는 조사할 수 있도록 준비 폴더에 남습니다.

템플릿은 만들어지는 동안 설정 부팅을 위해 한 번 부팅하며, 고정된 뒤에는 다시 부팅하지 않습니다.

## 오프라인 정리

`cfw install` 후 템플릿 빌드는 게스트가 전혀 사용하지 않는 시스템 파일을 System 볼륨에서 삭제합니다. 이 작업은 볼륨을 호스트에 마운트하여 오프라인으로 진행합니다. `vm create`의 `--trim`(기본값 `standard`)과 `vm template trim`의 `--tier`로 단계를 선택합니다.

| 단계 | 삭제 대상 | 크기 |
| --- | --- | --- |
| `none` | 없음 | |
| `conservative` | `usr/standalone/update`의 내용(소프트웨어 업데이트 램디스크, 베이스밴드 펌웨어) | 0.35 GB |
| `standard` | conservative에 더해 AirPods/Beats 페어링 에셋(`PreinstalledAssetsV2/RequiredByOs/com_apple_MobileAsset_SharingDeviceAssets`), 시계 페이스(`NanoTimeKit/FaceBundles`), 유지하지 않는 모든 언어의 `LinguisticData/RequiredAssets_*.bundle` | 1.2 GB |
| `aggressive` | 예약됨: 게스트에서 검증될 때까지 거부됩니다 | |

`--keep-languages`(기본값 `en,zh-Hans,zh`, 영어는 항상 유지)로 `standard`가 유지할 언어를 선택합니다. 단계, 목록의 버전, 유지할 언어는 템플릿 키(`standard/1/en,zh,zh-Hans`)에 포함되므로, 다르게 정리된 템플릿은 서로 일치하지 않습니다.

> [!WARNING]
> 정리는 되돌릴 수 없습니다. 복제본에서 파일을 되찾을 수 없습니다.

삭제한 파일은 처음에는 공간을 확보하지 않습니다. 게스트의 원래 시스템 스냅샷(`cfw install`이 남긴 `orig-fs.disabled.rn-*`)이 여전히 모든 블록을 붙잡고 있으며, 호스트에서는 root로도 이를 삭제할 수 없습니다. 설정 부팅이 첫 단계로 이를 삭제해야 비로소 공간이 반환됩니다. 그래서 설정 부팅을 하지 않는 템플릿에는 정리가 거부되며, 정리된 템플릿은 스냅샷이 사라진 뒤에만 고정하거나 채택할 수 있습니다.

`vm template trim`에는 root 권한이 필요하지 않습니다. 템플릿에서 복제되지 않은 중지된 머신이나 완료되지 않은 `.building-…` 폴더에서 실행되며, 고정된 템플릿은 거부합니다.

## 설정 부팅과 경량화

설정 부팅은 모든 복제본이 시작해야 할 상태로 템플릿을 마무리합니다. 템플릿을 한 번 부팅하고 vphoned를 통해 다음을 순서대로 수행합니다.

1. `cfw install`이 남긴 `orig-fs.disabled.rn-*` APFS 스냅샷을 삭제합니다(약 20 MB에 더해, 삭제될 때까지 System 볼륨에서 정리한 모든 파일을 붙잡고 있습니다).
2. 설정 지원을 건너뜁니다(`setup.skip`).
3. 첫 부팅 작업이 안정될 때까지 기다립니다(`setup.settle`, 최대 10분). 첫 부팅 때 installd가 제거 가능한 시스템 앱을 펼칩니다.
4. 시스템 앱을 제거합니다(`apps.remove_system`, 백업은 게스트에 보관).
5. 서비스 프로필을 적용합니다(`services.profile.apply`). 여기에는 로그인 후속 데몬(`followupd`, `appleidsetupd`)을 끄는 것도 포함됩니다.
6. 재시동한 뒤 확인합니다. 스냅샷이 남아 있지 않은지, 설정이 완료되었는지, 프로필의 서비스가 실행 중이지 않은지, 제거한 앱이 사라졌는지, vphoned가 응답하는지 확인합니다.
7. 이 부팅을 위해 `vphone-vm`이 고정한 기기 이름을 지우고 게스트를 정상적으로 종료합니다.

각 단계에는 제한 시간이 있습니다. 단계가 실패하면 가상 머신을 중지하고 아무것도 기록하지 않으며 빌드를 고정하지 않은 상태로 둡니다. `vm create`는 실패한 단계와 다시 시도하는 방법을 알려 줍니다.

| 스위치 | 기본값 | 효과 |
| --- | --- | --- |
| `--slim on\|off` | on | `off`는 아무것도 정리하지 않고 모든 앱과 서비스를 유지합니다. 설정 부팅은 여전히 실행되어 설정 지원을 건너뛰고 스냅샷을 삭제합니다. |
| `--trim none\|conservative\|standard` | standard | 위의 오프라인 정리입니다. |
| `--keep-languages <list>` | `en,zh-Hans,zh` | `--trim standard`가 유지할 언어입니다. |
| `--service-profile trimmed\|none` | trimmed | vphoned의 trimmed 프로필: App Store 데몬과 로그인 후속 데몬을 포함해 약 140개의 launchd 작업을 끕니다. 이 프로필을 사용하는 iPhone은 Apple Watch와 페어링할 수 없습니다(`Research/Guest/watch_pairing.md` 참고). |
| `--remove-apps on\|off` | on | App Store, 홈, TV, 뉴스, FaceTime, iTunes Store, 메시지, 게임, 나의 찾기, 지갑을 제거합니다. 카메라와 전화는 남습니다. |
| `--keep-apps <ids>` | 없음 | 위 목록 중 유지할 번들 ID, 쉼표로 구분(`com.apple.findmy,com.apple.Passbook`). |
| `--accounts-off` | off | `akd`, `amsaccountsd`, `appleaccountd`도 끕니다. 그러면 게스트에서 Apple 계정에 로그인할 수 없습니다. |

각 선택은 키에 포함되므로, 경량화 방식이 다른 템플릿이 나란히 존재하며 각 템플릿은 그 방식을 요청한 생성에만 사용됩니다. 서비스 프로필의 제한은 [Watch 페어링 기록](../../../Research/Guest/watch_pairing.md)을 참고하세요.

제거한 앱과 프로필은 복제본에서 `vphone-launchpad-cli guest rpc` 또는 Launchpad의 **Guest System**으로 되돌릴 수 있습니다.

- `apps.restore_system`은 백업에서 앱을 되돌려 놓습니다.
- `services.profile.apply {"profile":"none"}`은 프로필이 끈 것을 정확히 다시 켭니다.

### 복제본이 물려받는 것

복제본은 템플릿에서 다음을 물려받습니다. 완료된 설정, 설정 부팅이 남긴 상태의 앱과 서비스, installd와 인덱서가 수행한 첫 부팅 작업, 그리고 그 부팅 시점의 Data 볼륨입니다.

기기 이름은 물려받지 않습니다. 템플릿의 고정된 이름은 지워지므로, 복제본은 자신의 가상 머신이 연결하여 복제본의 이름을 고정할 때까지 `iPhone`으로 표시됩니다. 새 식별 정보를 가지므로 Mac에서 '이 컴퓨터를 신뢰하겠습니까?'를 다시 묻습니다.

## 공유되는 비밀 정보

> [!WARNING]
> 한 템플릿에서 복제된 모든 머신은 템플릿은 물론 복제본끼리도 SEP 루트 비밀, Data 볼륨 키, 그리고 복원과 설정 부팅이 기록한 데이터를 공유합니다. 원리상 한 복제본이 다른 복제본의 Data 볼륨을 복호화할 수 있습니다.

여러 기기를 이용한 연구를 위해 Apple 서비스에 로그인하는 경우처럼 자체 키가 필요한 머신은 `--no-template`으로 만들어야 합니다.

복제본은 `vm clone --new-identity`와 마찬가지로 첫 시작 때 새 ECID, UDID, MAC 주소를 받습니다. APFS에서는 변경되지 않은 모든 블록을 템플릿과 공유합니다. 새 복제본은 쓰기를 시작하기 전까지 거의 공간을 차지하지 않으며, 경량화된 템플릿에서는 첫 부팅 때 쓸 작업도 적습니다.

## 템플릿 관리

```sh
vphone-cli vm template list              # id, key summary, STALE with the reasons
vphone-cli vm template show <id> --json
vphone-cli vm template trim myphone --tier standard   # trim a stopped VM before adopting it
vphone-cli vm template setup myphone     # the setup boot, on a stopped VM
vphone-cli vm template adopt myphone     # freeze a stopped, newly created VM into a template
vphone-cli vm template delete <id>
```

### 오래된 템플릿

이 `vphone-cli`가 다른 번들 시리즈에 속하거나, 키가 이전 형식이거나, 프리셋이 이제 다른 부트 체인 패치로 결정되거나, 패치 영수증이 계획과 일치하지 않으면 템플릿은 오래된(stale) 것으로 표시됩니다. 오래된 템플릿은 사용되지 않으며, 그 키로 `vm create`를 실행하면 해당 템플릿을 지목하며 실패합니다. 다음 `vm create`가 새 템플릿을 만들게 하려면 오래된 템플릿을 삭제하세요.

### 가상 머신 채택하기

`vm template adopt <vm>`은 중지된 가상 머신을 그 자체 기록이 제공하는 키로 템플릿으로 만듭니다. 기록은 `restore-info.json`, `PatchPlan.plist`, `config.plist`, 디스크 이미지, Launchpad의 `launchpad.json`, 그리고 `vm template trim`과 `vm template setup`이 `Template.plist`에 기록한 단계입니다. 이 가상 머신은 `vm list`에서 사라집니다.

가상 머신은 설정 부팅 직후에 채택하세요. 그 이후 게스트가 한 일은 모든 복제본이 물려받습니다. 스냅샷이 있는 가상 머신은 거부되며, 오래된 템플릿이 될 가상 머신도 `--force`를 지정하지 않으면 거부됩니다.

### 고정된 템플릿은 부팅하지 않습니다

`vm launch`와 `vphone-vm`은 DFU를 포함해 고정된 템플릿의 부팅을 거부합니다. 어떤 머신 이름으로도 `.templates` 안을 가리킬 수 없으므로 `vm launch`, `clone`, `export`, `rename`, `delete`가 실수로 템플릿을 선택하는 일은 없습니다. 고정된 뒤 템플릿이 부팅하면 이후의 모든 복제본이 물려받을 블록에 상태를 기록하게 되고, 그 전에 만든 복제본은 더 이상 블록을 공유하지 않게 됩니다.

### 템플릿을 사용하는 머신

템플릿에서 복제된 머신은 `TemplateSource.plist`에 템플릿을 기록합니다. 그 머신을 `vm clone`하면 기록이 유지되고(사본도 템플릿의 블록을 공유하므로), `vm export`는 기록을 제외합니다(가져온 머신은 아무것도 공유하지 않으므로). 기록에는 템플릿의 빌드도 들어 있으므로, 템플릿을 삭제하고 같은 키로 다시 만들면 이전 템플릿에서 복제된 머신은 새 템플릿의 블록을 전혀 공유하지 않으므로 사용 중인 머신으로 계산되지 않습니다.

`vm template list`와 `show`는 각 템플릿을 사용하는 머신과 디스크상의 크기를 표시하고, `vm info`는 머신의 템플릿을 표시합니다. `vm delete`가 아직 존재하는 템플릿에서 복제된 마지막 머신을 삭제하면 그 사실을 알려 주며, 템플릿 자체는 절대 삭제하지 않습니다.

```text
note: template 3f2a91c0d4e7 (~17.40 GB) is no longer used by any machine; remove it with `vphone-cli vm template delete 3f2a91c0d4e7`
```

### 템플릿 삭제하기

`vm template delete <id>`는 템플릿을 삭제하며, 그 템플릿에서 복제된 머신은 계속 동작합니다. 머신이 아직 템플릿과 공유하는 블록은 그 머신이 블록을 변경하거나 삭제될 때만 해제되므로, 복제본이 남아 있는 동안 템플릿을 삭제하면 템플릿 크기보다 적은 공간이 확보됩니다.

출력되는 메모는 어느 경우에 해당하는지 알려 줍니다. 템플릿을 사용하는 머신이 있어 공유 블록이 그 머신이 변경하거나 삭제될 때까지 할당된 채로 남는 경우, 또는 현재 템플릿을 사용하는 머신이 없어 삭제하면 블록이 해제되는 경우입니다. 템플릿이 존재할 때 만들어진 로컬 Time Machine 스냅샷은 만료될 때까지 블록을 유지할 수 있습니다. `--json`과 `--force`를 함께 지정하면 같은 정보를 출력합니다.

템플릿은 `vm list`에 표시되지 않지만 디스크 공간을 차지합니다. `~/.vphone/machines/.templates`를 확인하고, `du`는 템플릿과 각 복제본을 모두 전체 크기로 계산한다는 점에 유의하세요.

## 함께 보기

- [템플릿 만들기와 찾기](template-building.md)
- [여러 머신 만들기](many-machines.md)
- [가상 머신 간 디스크 공간 공유](sharing-disk-space.md)
- [보관함, 펌웨어, 백업](library-and-backups.md)
