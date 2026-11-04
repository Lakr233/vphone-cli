# 네트워크

각 가상 머신에는 네트워크 모드가 하나 있습니다. 이 페이지에서는 모드를 고르는 방법과 실행 중인 가상 머신의 네트워크를 분리하는 방법을 설명합니다. 이 섹션의 다른 페이지에서는 터널 모드, 주소, 포트 포워딩, 이름, 머신 간 연결을 다룹니다.

## 네트워크 모드

| 모드 | 게스트가 인터넷에 연결되는 방식 | 사용하는 경우 |
| --- | --- | --- |
| `nat` | Virtualization.framework에 내장된 NAT | 기본값입니다. Mac에 VPN이 없거나, VPN이 게스트의 트래픽을 전달할 필요가 없을 때. |
| `bridged` | Mac의 물리 인터페이스에 직접 연결되며, 그 네트워크에서 자체 주소를 가짐 | LAN의 다른 컴퓨터에서 게스트에 접근해야 할 때. |
| [`tunnel`](tunnel.md) | `vphone-vm`이 Mac에서 여는 일반 연결을 통해 | Mac의 트래픽이 VPN이나 프록시 앱을 거치고, 게스트의 트래픽도 그 경로를 따라야 할 때. |
| `none` | 네트워크 장치 없음 | 게스트를 오프라인으로 유지해야 할 때. |

모드는 가상 머신의 `config.plist`에 저장되고 가상 머신이 시작될 때 읽히므로, 변경 사항은 다음 시작부터 적용됩니다.

## 모드 선택하기

Launchpad에서는 다음과 같이 합니다.

1. 머신을 중지합니다.
2. `⋯` 메뉴나 오른쪽 클릭 메뉴에서 Settings…를 선택합니다.
3. Network 섹션에서 모드를 선택합니다.

New Machine에서는 Advanced Options에서 모드를 설정합니다. 머신을 하나 선택하면 Settings…에 Address와 Port Forwarding 섹션도 있습니다.

명령줄에서는 다음과 같습니다.

```sh
vphone-cli vm config <name> --network tunnel
# or through Launchpad
vphone-launchpad-cli exec vm config <name> --network tunnel
```

`tunnel`에는 `vphone-cli vm config --help`에 이 모드가 나열되는 `VPhone.bundle`이 필요합니다. 이전 번들은 이 설정을 거부합니다.

## 실행 중인 가상 머신의 네트워크 분리하기

`vm network`는 실행 중인 가상 머신에 작용하며, 변경 내용은 저장되지 않습니다.

```sh
vphone-cli vm network <name>               # state of the NIC
vphone-cli vm network <name> --link down   # unplug the cable
vphone-cli vm network <name> --link up     # plug it back in
```

게스트에서는 링크가 끊겼다가 다시 연결되는 것으로 보입니다. 같은 요청을 `vphone.sock`에서 `{"t":"network"}`에 `"link":"down"` 또는 `"link":"up"`을 붙여 보낼 수도 있습니다.

> [!NOTE]
> 실행 중인 가상 머신은 다른 네트워크로 옮길 수 없습니다. Virtualization은 변경을 받아들인 뒤 내부 오류로 가상 머신을 중지하므로, `vm network`는 가상 머신이 시작할 때의 네트워크만 다시 연결합니다. 모드를 바꾸려면 `vm config`를 사용하고 가상 머신을 다시 시작하세요.

## 함께 보기

- [터널 모드](tunnel.md): VPN이나 프록시 앱을 사용하는 Mac
- [MAC 및 IP 주소](addresses.md): 저장된 MAC, 이전 MAC이 차지한 임대, 고정 주소
- [포트 포워딩](port-forwarding.md): Mac의 포트를 게스트로 전달하기
- [네트워크상의 이름](names.md)과 [머신 간 연결](peers.md)
