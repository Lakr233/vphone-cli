# 머신 간 연결

한 Mac의 `nat` 머신들은 Bonjour를 포함해 서로 직접 연결됩니다. 가상 Apple Watch도 이 방식으로 가상 iPhone과 페어링합니다. 이 페이지에서는 머신 하나를 분리해 두는 방법을 설명합니다.

## 머신 격리하기

```sh
vphone-cli vm config <name> --nat-peers off   # isolate this guest again
vphone-cli vm config <name> --nat-peers on    # the default
```

Launchpad에서는 머신의 Network 설정에 있는 'Reach other NAT machines'입니다. 변경 사항은 다음 시작부터 적용됩니다.

격리된 게스트는 Mac과 인터넷에는 연결되지만 다른 가상 머신에는 연결되지 않습니다. 격리는 각 머신 자체의 연결에 대한 설정이므로, 해제를 선택한 머신은 다른 머신의 설정과 관계없이 격리된 상태로 남습니다.

## 머신이 속한 네트워크

| 설정 | 공유 네트워크 | Mac의 주소 |
| --- | --- | --- |
| `--nat-peers on`(기본값) | `192.168.65.0/24` | `192.168.65.1` |
| `--nat-peers off` | `192.168.64.0/24` | `192.168.64.1` |

[고정 주소](addresses.md)(`--ip`)는 머신이 참여하는 네트워크에 있어야 합니다. 고정 주소가 첫 번째 네트워크(`192.168.64.0/24`)에 있는 머신은 다른 머신과의 연결을 요청하지 않는 한 격리된 상태로 남으며, 요청하면 두 번째 네트워크의 주소가 필요합니다.

## 배경

기본적으로 Virtualization.framework는 Mac의 공유 네트워크에서 각 `nat` 게스트를 다른 게스트와 격리합니다. vphone은 이 격리를 끄며, 그러면 vmnet이 서로 연결되는 머신들을 첫 번째 네트워크 다음 블록인 두 번째 공유 네트워크에 둡니다. 이 스위치는 Virtualization.framework의 비공개 기능입니다. 이 스위치가 없는 버전에서는 모든 게스트가 격리되며, 가상 머신이 시작될 때 그렇게 알려 줍니다.

## 함께 보기

- [네트워크](overview.md)
- [MAC 및 IP 주소](addresses.md)
- [네트워크상의 이름](names.md)
