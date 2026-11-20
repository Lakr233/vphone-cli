# 메모리 덤프

메모리 덤프는 실행 중인 게스트의 메모리와 프로세서 상태를 Mac의 파일로 저장해, LLDB나 직접 만든 도구로 오프라인 분석할 수 있게 합니다. 메모리를 복사하는 동안 게스트가 일시 정지되고, 그 후 멈췄던 곳에서 이어서 실행됩니다.

덤프에는 세 종류가 있습니다.

| 종류 | 시작하는 곳 | 저장하는 내용 |
| --- | --- | --- |
| 커널과 vCPU 코어 | **Diagnostics > Save Memory Dump…** | 커널의 가상 주소로 본 게스트 RAM, 모든 vCPU의 레지스터, Secure Enclave의 메모리 |
| 물리 메모리 이미지 | 같은 패널의 체크박스 | 게스트 RAM 전체를 물리 주소로 |
| 프로세스 하나 덤프 | Processes 창의 **Save Memory Dump…** | 프로세스 하나의 상주 메모리를 그 프로세스의 주소로 |

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

## 물리 메모리 이미지

Save Memory Dump 패널에서 **Physical memory image**를 선택하면 코어 대신 `physical.elf`를 저장합니다. 이 파일은 ELF 코어 파일로, 게스트 DRAM과 그 아래에 있는 펌웨어 카브아웃에 각각 `PT_LOAD`가 하나씩 있고, 각 세그먼트의 주소는 게스트 물리 주소입니다. `VPHONE` 노트(타입 `0x5650`)에는 머신, 게스트 커널, 그 물리 주소, 페이지 테이블의 루트를 담은 JSON이 들어 있습니다. 물리 메모리를 읽는 도구에 쓰거나, 게스트의 페이지 테이블을 직접 따라가 주소를 변환할 때 쓸 수 있습니다.

게스트가 한 번도 쓰지 않은 페이지는 파일에서 빠집니다. 이미지 전체를 다 쓸 때까지 게스트는 일시 정지된 상태이며, Mac의 메모리가 넉넉하면 보통 10~20초입니다.

터미널에서는 `memory.dump`에 `"physical":true`를 추가합니다.

```sh
printf '%s\n' '{"t":"memory.dump","path":"/Users/me/Dumps/myphone-2","physical":true}' | nc -U ~/.vphone/machines/myphone/vphone.sock
```

## 프로세스 하나 덤프

1. **Diagnostics > Processes**를 선택하고 프로세스 하나를 선택합니다.
2. 도구 막대나 컨텍스트 메뉴에서 **Save Memory Dump…**를 선택한 다음 폴더를 선택합니다. 새 폴더 이름에는 `myphone SpringBoard (36) Memory 2026-11-20 at 10.02.03`처럼 머신, 프로세스, pid가 들어갑니다.

vphone은 게스트의 도움 없이 Mac에서 프로세스의 메모리를 읽습니다. 게스트 RAM에서 게스트 커널을 찾고, 프로세스 목록을 따라가 해당 pid를 찾은 뒤, 프로세스의 페이지 테이블이 매핑한 페이지를 모두 복사합니다. 그동안 게스트는 일시 정지되며, 보통 몇 초입니다. vphoned는 선택할 프로세스 목록만 제공합니다. 저장하는 시점에 그 pid가 다른 프로세스의 것이 되었다면 덤프는 거부됩니다. 목록을 새로 고친 뒤 다시 시도하세요.

폴더에는 프로세스 이름을 붙인 Mach-O 코어와 `info.json`이 들어 있습니다. LLDB는 코어를 열고, 그 안의 dyld 데이터에서 프로세스의 이미지를 찾습니다.

```sh
lldb -c "myphone SpringBoard (36) Memory 2026-11-20 at 10.02.03/SpringBoard.core"
(lldb) image list
(lldb) memory read 0x104218000
```

코어에는 프로세스의 상주 페이지만 들어 있습니다. 한 번도 건드리지 않은 페이지, 게스트가 압축하거나 페이지 아웃한 페이지, 스레드와 레지스터는 들어 있지 않습니다. 각 세그먼트의 권한은 페이지 테이블 항목에서 가져옵니다.

터미널에서는 pid를 지정해 `process.dump`를 보냅니다. `name`은 생략할 수 있으며, 지정하면 프로세스 이름이 그와 같지 않을 때 덤프가 거부됩니다.

```sh
printf '%s\n' '{"t":"process.dump","pid":36,"name":"SpringBoard","path":"/Users/me/Dumps/springboard"}' | nc -U ~/.vphone/machines/myphone/vphone.sock
```

프로세스 덤프는 vphone에 포함된 커널캐시 레시피(iOS 18.1~27.2) 가운데 하나의 커널로 실행되는 게스트에서 동작합니다. vphone은 그 커널의 심볼 맵에서 주소 두 개를 사용합니다. 그 밖의 커널이면 커널을 알 수 없다고 알려 줍니다.

## 용량과 시간

- `AP.core`는 게스트 RAM보다 조금 크며, 8 GB 게스트에서는 8.6 GB입니다. 모두 0인 블록은 파일에서 빠지므로 APFS 볼륨에서는 데이터만큼의 공간만 차지하며, 보통 게스트 RAM의 대부분입니다.
- 볼륨의 여유 공간이 게스트 RAM보다 조금 더 큰 양에 못 미치면, 게스트를 일시 정지하기 전에 저장을 거부합니다. 프로세스 덤프는 4GB를 요구합니다.
- 게스트가 일시 정지된 동안 macOS가 그 메모리의 사본을 보관합니다. 메모리가 부족한 Mac에서는 일시 정지와 쓰기가 더 오래 걸립니다.
- 일시 정지된 동안 게스트의 시계는 멈춰 있습니다. 게스트가 다시 실행되면 `vphone-vm`이 곧바로 게스트의 시계를 Mac의 시각으로 맞춥니다.
- 한 머신의 덤프는 한 번에 하나만 저장됩니다.

커널과 vCPU 코어에는 Virtualization 프레임워크가 메모리 코어를 쓸 수 있는 macOS가 필요합니다. macOS 27.2는 지원합니다. 지원하지 않는 macOS에서는 메뉴 항목을 사용할 수 없고 `memory.dump`가 그렇다고 알려 줍니다. 물리 메모리 이미지와 프로세스 덤프는 가상 머신을 실행하는 Virtualization 프로세스에서 게스트 RAM을 읽으므로, System Integrity Protection의 디버깅 제한이 꺼져 있어야 합니다. 이는 [호스트 설정](../get-started/host-setup.md)에서 이미 요구하는 설정입니다.

덤프를 만드는 방법과 측정 결과는 [`Research/Host/memory_dump.md`](../../../Research/Host/memory_dump.md)와 [`Research/Host/process_memory_dump.md`](../../../Research/Host/process_memory_dump.md)를 참고하세요.

## 함께 보기

- [가상 머신 생성 및 실행](create-and-run.md)
- [기기 이름과 시계](device-name-and-clock.md)
