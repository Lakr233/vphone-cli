# 문제 해결

보이는 증상이나 오류 메시지를 찾은 뒤 그 아래의 해결 방법을 따르세요. 네트워크 문제는 [네트워크](../networking/overview.md)를 참고하세요.

## 가상 머신이 열리기 전에 `vphone-vm`이 종료됨

1. 호스트 사전 점검을 실행합니다.

   ```sh
   vphone-cli host preflight
   ```

   CLI에는 권한이 없으므로 계속 실행되며, 서명된 짝 프로그램 `vphone-vm`을 AMFI가 거부한 이유를 설명할 수 있습니다.
2. 번들을 다시 빌드했다면 cdhash가 바뀐 것입니다. [호스트 설정](../get-started/host-setup.md)에 설명된 대로 번들에 포함된 도우미로 새 바이너리를 허용하세요.

## `Virtualization is not available on this hardware`

PV=3 게스트는 중첩할 수 없습니다. 다른 macOS 가상 머신 안이 아니라 Apple Silicon Mac에서 실행하세요.

## `vm create`가 vphoned 성공을 출력했지만 실행 중인 가상 머신이 없음

정상입니다. 생성 과정은 임시 GUI 부팅을 시작해 실제 ping을 보낸 뒤, 반환하기 전에 그 부팅을 중지합니다. 사용하려면 가상 머신을 시작하세요.

```sh
vphone-cli vm launch <name>
```

## "Press home to continue"에서 멈춤

가상 머신 창의 제목 막대에 있는 홈 버튼을 클릭하세요. 현재 JB 작업 흐름은 VNC 서버를 설치하지 않습니다.

## 앱이 `EXC_GUARD` / `GUARD_TYPE_MACH_PORT`로 종료됨

커널 패치 `kernel-boot-thread_guard_violation`은 치명적인 Mach 포트 가드 전달을 막습니다. 이 패치는 부팅에 필요한 iOS 18 기반에서만 적용되며, 그곳에서는 모든 프리셋이 이를 켭니다. 다른 기반에서는 선택할 수 없으므로, 26.x 기반에서 이 가드에 걸리는 앱은 여전히 종료됩니다. [이슈 #291](https://github.com/Lakr233/vphone-cli/issues/291)을 참고하세요.

## 복원 또는 첫 부팅 실패

- 수동 흐름에서는 `restore`가 끝날 때까지 가상 머신을 DFU 상태로 유지하세요.
- 온라인 티켓 요청이 Apple에 도달할 수 있는지 확인하세요.
- 전체 파이프라인은 **새 이름**과 도구 세부 정보를 위한 `-v`로 `vm create`를 다시 실행하세요.
- 메모리나 디스크가 부족하면 가상 머신을 동시에 여러 개 만들지 마세요.
- iPhone IPSW와 PCC 이미지를 조합하기 전에 [펌웨어 호환성](../firmware/compatibility.md)을 확인하세요.

## 게스트는 부팅되지만 생성 중에 vphoned가 응답하지 않음

첫 부팅 확인은 300초 후 시간 초과됩니다. 새로 복원한 게스트는 첫 헤드리스 부팅에서 vphoned를 띄우지 못할 수 있으므로, 생성 과정에서는 GUI 부팅을 사용합니다. 성공 표시가 무엇을 확인하는지는 [생성 및 실행](../machines/create-and-run.md)을 참고하세요.

## 함께 보기

- [호스트 설정](../get-started/host-setup.md)
- [생성 및 실행](../machines/create-and-run.md)
- [펌웨어 호환성](../firmware/compatibility.md)
