# Прогоны на живых системах

Пробник — `tools/wqprobe.m` (arm64, app sandbox, `get-task-allow=1`). Запуск: `xcrun devicectl device process launch --console <bundle> <режим>`. Полный вывод — `out_13.txt`, `out_17.txt`.

## 1. `task_for_pid` и порт ядра, режим `tfp`

| | iPhone 13, 26.5.2 | iPhone 17 Pro Max, 27.2.1 | Basil, 27.2 (VM) |
|---|---|---|---|
| `csops` | `flags=0x22003305 platform=0` | `flags=0x22003305 platform=0` | `flags=0x2600100d platform=1` |
| `task_for_pid(0)` | failure | failure | failure |
| `task_for_pid(1)` | failure | failure | failure |
| `task_for_pid(2)` | failure | failure | failure |
| `task_for_pid(100)` | failure | failure | failure |
| `task_for_pid(<свой pid>)` | failure | failure | failure |
| `host_get_special_port(4)` | invalid argument | invalid argument | invalid argument |

Вывод: гейт закрыт на всех трёх системах. На Basil это неожиданно при том, что патч `kernel-cfw-task_for_pid` числится применённым (см. `05_open_questions_and_next.md`, вопрос 1).

## 2. Enumeration контейнеров (`fsgetpath` по inode), часть `worse_query`

| | iPhone 13, 26.5.2 | iPhone 17 Pro Max, 27.2.1 |
|---|---|---|
| Диапазон inode | 10M…60M из ~297M, шаг 10M | 89 180 808…91 180 808 (fsid 16777228) |
| Найдено | **0** | **674** (404 `Data/Application`, 270 `Shared/AppGroup`) |
| Время | остановлен после 60M | 160 с, resolved = 951 115 |

Оговорки: на iPhone 13 просканирована только пятая часть диапазона и без шага 1 — «0» означает «не найдено в проверенном окне», а не «утечки нет». На 17 Pro Max окно в 2M inode; полный список требует сканирования всего диапазона. Сами токены sandbox extension (шаг 3–5 `worse_query`, нужен App Group) в этом прогоне **не проверялись**.

## 3. Recovery-serial iPhone 13

`pymobiledevice3 lockdown recovery`: `SDOM:01 CPID:8110 CPRV:11 CPFM:03 SCEP:01 BDID:0A ECID:00096C803C31801E IBFL:3D`. `CPFM:03` = SecurityMode | ProductionMode, то есть обычный розничный чип. Устройство возвращено в iOS (`set_autoboot(True)` + `reboot`).

## 4. Root внутри Basil с хоста (сделано в ходе заметки)

Сокет `~/.vphone/machines/Basil/vphone.sock`, кадр JSON `{"t":"rpc","method":…,"params":…}`; обёртка — `tools/vrpc.py`. HTTP API у Basil выключен (запущен без `--api-listen`), сокет работает без токена.

| Вызов | Результат |
|---|---|
| `script.eval` → `fs.stat("/private/var/db/vphoned")` | `uid=0`, `mode=755`, directory |
| `processes.list` | `kernel_task` pid 0, `launchd` pid 1 … |
| `script.eval` → `proc.run("/usr/bin/id")` | `No such file or directory` (в госте нет этого файла) |
| `proc.run("/bin/launchctl")`, `/usr/sbin/sysctl` | `No such file or directory` |
| `fs.ls("/System/Library/Caches/com.apple.kernelcaches")` | `[]` |

Вывод: канал до root-сессии в госте работает (JS-контекст JavaScriptCore, глобали `ObjC`, `fs`, `proc`, `api`; `ObjC.import` отсутствует — это не Frida). Запуск программ упирается в отсутствие бинарников в базовом образе, а не в права.

## 5. Что не запускалось

`kprobe.app` (перебор `host_info`, `host_statistics{,64}`, `task_info`, `proc_info`, `host_processor_info` с двухпроходным сравнением) собран: Release — `/tmp/jbresearch/dd-kprobe/Build/Products/Release-iphoneos/kprobe.app`. На устройствах не устанавливался и не запускался; KASLR-утечка на 23F84/24B156 таким образом **не проверена**.
