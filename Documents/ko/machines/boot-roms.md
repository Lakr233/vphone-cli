# 부트 ROM

가상 머신이 시작할 때 사용할 부트 ROM과 SEP 부트 ROM을 선택합니다. 이 페이지에서는 가상 머신이 사용하는 ROM을 확인하거나 오픈 소스 ROM과 Apple의 ROM 사이에서 전환하는 방법을 설명합니다.

## 확인 및 전환

```sh
vphone-cli vm info myphone                                    # shows rom and seprom
vphone-cli vm config myphone --rom openavb --seprom opensep   # open-source ROMs
vphone-cli vm config myphone --rom apple --seprom apple       # Apple's ROMs
```

전환은 복원 없이 가상 머신의 다음 시작부터 적용되며, 어느 방향으로든 가능합니다.

| 옵션 | 값 | ROM |
| --- | --- | --- |
| `--rom` | `openavb` | 번들에 포함된 OpenAVB |
| `--rom` | `apple` | Virtualization.framework의 AVPBooter(머신에 패치된 사본이 있으면 그 사본) |
| `--rom` | 파일 경로 | 그 밖의 부트 ROM |
| `--seprom` | `opensep` | 번들에 포함된 OpenSEP |
| `--seprom` | `apple` | Virtualization.framework의 AVPSEPBooter |
| `--seprom` | 파일 경로 | 그 밖의 SEP 부트 ROM |

두 부트 ROM은 같은 패치된 LLB를 로드하고, 두 SEP ROM은 복원 때 설치된 SEP 펌웨어를 로드합니다. 그래서 복원이 필요하지 않습니다.

> [!NOTE]
> OpenAVB로 부팅하는 가상 머신을 복원하려면 `VPhone.bundle` 2.10.1 이상이 필요합니다.

## 가상 머신이 사용하는 ROM

새 가상 머신은 Virtualization.framework에 포함된 비공개 ROM 대신 두 가지 오픈 소스 ROM으로 시작합니다.

- [OpenAVB](https://github.com/owngoal-dev/OpenAVB)는 부트 ROM인 AVPBooter를 대신합니다. 패치가 필요 없으므로 `fw patch`가 건드리지 않습니다.
- [OpenSEP](https://github.com/owngoal-dev/OpenSEP)는 SEP 부트 ROM인 AVPSEPBooter를 대신합니다.

둘을 함께 쓰면 iBoot와 SEPOS 이전에 실행되는 코드 중 Apple이 작성한 것은 없습니다. 이전 버전에서 만든 가상 머신은 전환하기 전까지 Apple의 ROM을 계속 사용합니다.

## ROM의 출처

두 ROM 모두 고정된 업스트림 커밋에서 미리 빌드되어 `VPhone.bundle`에 포함됩니다. 각 README에 다시 빌드하고 바이트 단위로 대조하는 방법이 있습니다.

- [OpenAVB README](../../../VPhoneExecutable/VPhoneVirtualization/Resources/OpenAVB/README.md)
- [OpenSEP README](../../../VPhoneExecutable/VPhoneVirtualization/Resources/OpenSEP/README.md)

자세한 내용은 [OpenAVB](../../../Research/Firmware/openavb_boot_rom.md)와 [OpenSEP](../../../Research/Firmware/opensep_sep_rom.md)에 관한 연구 기록을 참고하세요.

## 함께 보기

- [가상 머신 생성 및 실행](create-and-run.md)
- [펌웨어 준비](../firmware/firmware-preparation.md)
- [문제 해결](../help/troubleshooting.md)
