# 스냅샷

스냅샷은 중지된 머신의 디스크와 부팅 상태를 저장해 두었다가 나중에 되돌아갈 수 있게 합니다. 깨끗하게 설치한 직후 스냅샷을 만들고, 게스트에서 되돌리기 어려운 작업을 시도한 뒤 되돌리세요.

## 만들기, 목록 보기, 되돌리기, 삭제

1. 머신을 중지합니다. `vphone-cli vm stop myphone`을 실행하거나 창에서 닫습니다.
2. 스냅샷을 만든 뒤 게스트에서 작업합니다. 저장한 상태로 돌아가려면 머신을 다시 중지하고 되돌립니다.

```sh
vphone-cli vm snapshot create myphone clean --note "fresh install"
vphone-cli vm snapshot list myphone
vphone-cli vm snapshot revert myphone clean
vphone-cli vm snapshot delete myphone clean
```

- `revert`와 `delete`는 변경하기 전에 확인을 요청합니다. `--force`를 지정하면 묻지 않습니다.
- 되돌려도 스냅샷은 남아 있으므로 다시 그 스냅샷으로 돌아갈 수 있습니다.
- `list --json`은 `{"name", "created", "note"}` 객체 배열을 오래된 순서로 출력합니다. `created`는 ISO 8601 형식이며, 메모가 없으면 `note`는 생략됩니다.
- `list`와 `delete`는 머신이 실행 중일 때도 동작하며, 둘 다 실행 중인 파일을 건드리지 않습니다.

## 만들기나 되돌리기가 거부될 때

`create`와 `revert`는 머신이 실행 중이거나, 어떤 프로세스든 디스크 이미지, `SEPStorage`, `nvram.bin`을 열고 있으면 거부합니다. 거부 메시지에는 파일을 열고 있는 각 프로세스의 이름이 표시됩니다. 그중 어느 것도 머신을 실행하는 프로세스가 아니라면(백업 도구, Spotlight 등) 그렇다고 알려 주며, 해당 프로세스가 파일을 닫은 뒤 다시 시도하면 성공합니다.

머신이 APFS 볼륨에 있지 않을 때도 `create`는 수십 기가바이트에 이를 수 있는 디스크 이미지를 복사하지 않고 거부합니다.

`Snapshot.plist`에 세 가지 상태 파일이 모두 나열되어 있지 않거나 스냅샷에 속하지 않는 파일이 나열된 스냅샷은, 아무것도 바꾸기 전에 손상된 것으로 거부됩니다.

되돌리기는 전부 성공하거나 전부 실패합니다. 도중에 실패하면 머신의 원래 파일을 제자리에 돌려놓고 오류를 보고하므로, 머신은 이전 상태 그대로입니다. 드물게 원래 파일을 돌려놓는 것까지 실패하면 오류 메시지에 그렇게 표시됩니다. 이 경우 머신을 시작하기 전에 스냅샷으로 다시 되돌리세요.

## 스냅샷에 포함되는 것

| 포함 항목 | 이유 |
| --- | --- |
| 디스크 이미지(`Disk.img`) | 게스트의 시스템과 데이터 |
| `SEPStorage`, `nvram.bin` | Secure Enclave 상태와 부트 체인의 NVRAM. 디스크와 일치해야 합니다 |
| `PatchReceipt.plist` | 게스트에 적용된 패치 |
| `restore-info.json` | 디스크의 iOS 버전과 `cfw install` 완료 여부 |

디스크, `SEPStorage`, `nvram.bin`은 항상 함께 움직입니다. Secure Enclave의 재사용 방지 카운터는 `SEPStorage`에 있고 디스크에는 그에 맞는 상태가 있습니다. 서로 다른 시점의 디스크와 `SEPStorage`를 함께 쓰면 다음 부팅 때 SEP가 패닉합니다.

`PatchReceipt.plist`와 `restore-info.json`은 있을 때만 저장됩니다. 스냅샷을 만들 때 없었던 파일은 되돌릴 때 삭제되므로, 기록은 나중의 설치가 아니라 복원된 디스크를 나타냅니다.

다음은 포함되지 않으며, 되돌려도 바뀌지 않습니다.

- `config.plist`: 기기 식별 정보, CPU, 메모리, 네트워크 등의 설정. 언제든 `vm config`로 변경할 수 있으며, 되돌리기는 이를 취소하지 않습니다.
- 패치 선택(`PatchSelection.plist`), 복원 트리, `FirmwareOriginals/`, ROM. 이들은 게스트 상태가 아니라 Mac에 있는 입력입니다.
- `launchpad.json`. Launchpad는 자체 사본을 스냅샷 폴더에 저장하고 직접 되돌려 놓습니다. CLI는 스냅샷 폴더에 있는 추가 파일을 건드리지 않으며, 스냅샷과 함께 삭제합니다.

## 디스크 공간

스냅샷은 `<vm>/Snapshots/<name>/`에 APFS 복제본으로 저장됩니다. 만들기는 즉시 끝나며 공간을 차지하지 않습니다. 게스트가 쓰기 전까지 머신과 스냅샷은 모든 블록을 공유하며, 쓴 뒤에는 바뀐 블록만 새로 공간을 차지합니다. `du`와 Finder는 각 스냅샷을 디스크 전체 크기로 계산하므로 실제 사용량보다 크게 표시합니다. 볼륨의 여유 공간이 정확한 기준입니다.

스냅샷은 만들 때의 디스크 블록을 유지합니다. 해당 머신의 스냅샷이 이전 블록을 붙잡고 있는 동안에는 `vm rebase`로 공간이 확보되지 않습니다. [가상 머신 간 디스크 공간 공유](sharing-disk-space.md)를 참고하세요.

## 복제, 내보내기, 이름 변경

`vm clone`과 `vm export`는 스냅샷을 가져가지 않습니다. 복제본이나 가져온 머신은 스냅샷 없이 시작합니다. 머신을 삭제하거나 이름을 바꾸면 스냅샷도 함께 삭제되거나 이름이 바뀝니다.

## 함께 보기

- [보관함, 펌웨어, 백업](library-and-backups.md)
- [가상 머신 간 디스크 공간 공유](sharing-disk-space.md)
- [문제 해결](../help/troubleshooting.md)
