# 메모리 덤프

메모리 덤프는 실행 중인 게스트의 메모리와 프로세서 상태를 Mac의 파일로 저장해, LLDB나 직접 만든 도구로 오프라인 분석할 수 있게 합니다. 메모리를 복사하는 동안 게스트가 일시 정지되고, 그 후 멈췄던 곳에서 이어서 실행됩니다.

## 덤프 저장하기

1. 가상 머신 창에서 **Diagnostics > Save Memory Dump…**를 선택합니다.
2. 폴더를 선택합니다. 그 안에 `myphone Memory 2026-11-19 at 15.20.11`처럼 머신 이름과 시각이 붙은 새 폴더가 만들어집니다.
3. 덤프가 저장된 위치를 알려 주는 알림이 나타날 때까지 기다립니다. 게스트는 처음 부분에서만 일시 정지되며, 보통 10~20초입니다. 파일을 쓰는 동안에는 게스트가 다시 실행되며, 쓰기에 1분 정도 더 걸릴 수 있습니다.

터미널에서는 머신의 [제어 소켓](create-and-run.md#제어-소켓)에 만들 폴더를 지정해 `memory.dump`를 보냅니다. 그 폴더는 아직 없어야 하고, 상위 폴더는 있어야 합니다.

```sh
printf '%s\n' '{"t":"memory.dump","path":"/Users/me/Dumps/myphone-1"}' | nc -U ~/.vphone/machines/myphone/vphone.sock
```

응답은 파일 쓰기가 끝난 뒤에 옵니다. 각 파일의 크기와 실제로 담긴 바이트 수, 캡처와 쓰기에 걸린 시간이 들어 있습니다. `vphone-launchpad-cli guest send`는 2분이 지나면 기다리지 않으므로, 8 GB를 쓰는 데 그보다 오래 걸리는 Mac에서는 위와 같이 `nc`를 사용하세요.

## 덤프에 들어 있는 것

| 파일 | 내용 |
| --- | --- |
| `AP.core` | 커널의 가상 주소로 본 게스트 RAM, vCPU에서 실행 중이던 프로세스의 사용자 메모리, 모든 vCPU의 범용 레지스터 |
| `SEP-coproc.core` | Secure Enclave의 메모리(약 20 MB) |
| `info.json` | 머신, 시각, vphone과 macOS 버전, 각 파일의 크기 |

두 코어 모두 Mach-O 코어 파일입니다. LLDB는 `AP.core`를 바로 열며, vCPU마다 스레드가 하나씩 있습니다.

```sh
lldb -c "myphone Memory 2026-11-19 at 15.20.11/AP.core"
```

`thread list`, `register read`, `memory read`, `bt`는 다른 준비 없이 동작합니다. 심볼이 필요하면 게스트가 부팅한 커널 캐시를 추가하고 `target modules load --file <kernelcache> --slide <slide>`로 게스트의 KASLR 슬라이드에 로드합니다.

덤프에는 물리 주소, 변환 테이블 베이스나 포인터 인증 키 같은 시스템 레지스터, 커널이 매핑하지 않은 메모리가 들어 있지 않습니다.

## 공간과 시간

- `AP.core`는 게스트 RAM보다 조금 크며, 8 GB 게스트에서는 8.6 GB입니다. 모두 0인 블록은 파일에서 빠지므로 APFS 볼륨에서는 데이터만큼의 공간만 차지하며, 보통 게스트 RAM의 대부분입니다.
- 볼륨의 여유 공간이 게스트 RAM보다 조금 더 큰 양에 못 미치면, 게스트를 일시 정지하기 전에 저장을 거부합니다.
- 게스트가 일시 정지된 동안 macOS가 그 메모리의 사본을 보관합니다. 메모리가 부족한 Mac에서는 일시 정지와 쓰기가 더 오래 걸립니다.
- 일시 정지된 동안 게스트의 시계는 멈춰 있습니다. 게스트가 다시 실행되면 `vphone-vm`이 곧바로 게스트의 시계를 Mac의 시각으로 맞춥니다.
- 한 머신의 덤프는 한 번에 하나만 저장됩니다.

덤프에는 Virtualization 프레임워크가 메모리 코어를 쓸 수 있는 macOS가 필요합니다. macOS 27.2는 지원하며, 지원하지 않는 macOS에서는 메뉴 항목을 사용할 수 없고 `memory.dump`가 그렇다고 알려 줍니다.

덤프를 만드는 방법과 측정 결과는 [`Research/Host/memory_dump.md`](../../../Research/Host/memory_dump.md)를 참고하세요.

## 함께 보기

- [가상 머신 생성 및 실행](create-and-run.md)
- [기기 이름과 시계](device-name-and-clock.md)
