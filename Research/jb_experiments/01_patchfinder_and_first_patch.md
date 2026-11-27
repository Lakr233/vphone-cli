# Patchfinder и первый патч

Метод взят из vphone: `VPhoneExecutable/VPhoneCommand/FirmwarePatcher/Kernel/CustomFirmwarePatches/Process/KernelCustomFirmwarePatchTaskForPid.swift` (строка → xref → функция → сигнатура инструкций → замена) и `KernelCustomFirmwarePatchSandboxExtended.swift` (перенаправление записей 201–316 таблицы операций MACF на заглушку `mov x0,#0; ret`).

Инструменты: `tools/patchfind.py <kernelcache> <entry_id> "<строка>"`, `tools/disasm.py <kernelcache> <entry_id> <va> [count]` (минимальный дизассемблер arm64e: `otool` не разбирает подбинарники fileset). Указатели в chained-fixup: младшие 32 бита — смещение от базы слайда.

## Адреса

| Что | iPhone 13 (23F84, A15) | iPhone 17 Pro Max (24B156, A19) |
|---|---|---|
| xref на строку политики `task_for_pid` (`proc_ro_ref_task`) | `0xfffffff00a3053e4` | `0xfffffe000b15132c` |
| функция политики, вход | `0xfffffff00a305400` | `0xfffffe000b151348` |
| она же в 23G83 (26.6.1, A15) | `0xfffffff00a313e30` (xref на `proc_ro_ref_task` — `0xfffffff00a313e14`) | — |
| `cbz x0, +0x7c` после `bl` (первый патч, **неверный**) | `0xfffffff00a305440` | — |
| `mac_policy_conf` (`Seatbelt sandbox policy`) | `0xfffffff007f7b738` | `0xfffffe0008436680` |
| `mpc_ops` (`+0x28`) | `0xfffffff007f7aca0` | `0xfffffe0008435be4` |
| заглушка `mov x0,#0; ret` (единственная в образе) | `0xfffffff009bc0b38` | `0xfffffe000a93cbd4` |
| база AMFI | `0xfffffff007546c20` | `0xfffffe0007665c40` |
| xref `com.apple.private.amfi.can-load-trust-cache` | `+0x165bec4` | `+0x1c072d8` |
| функция `cs_enforcement_disable` | `+0x1669300` | `+0x1c1503c` |

**Проверка 2026-11-27 (по словам, `tools/kdiff2/fdiff.py`):** функция политики на 23F84, 23G83 и 24B156 — одна и та же по логике, но **не** «инструкция в инструкцию»: 23F84 → 23G83 — 87/87 инструкций, нормализованный дифф пуст (Apple эту функцию в 26.6.1 не трогала); 23F84 → 24B156 — 87 vs 86, единственное расхождение — компилятор иначе записал ту же проверку диапазона адресов (`adrp+ldr` константы → `orr x9,x0,#N`; порядок `ccmp …, hs/ls`), логика идентична. xref `0x…53e4` / `0x…5132c` — это `adrp` на строку `proc_ro_ref_task` внутри **соседнего логгера** (`kern_proc.c`, «proc_ro already has an owning task»), сама функция начинается на `0x1c` байта позже; вход для A19 (`0x…51348`) найден только при этой проверке — раньше в таблице стоял «—», а совпадение «инструкция в инструкцию» было записано без настоящего сравнения.

Чтение строк: цели `adrp` в kernelcache несут сдвиг `+0x200000000` к vmaddr секций (`tools/kcx.py <kc> <va>…` читает cstring по VA из любого fileset-подбинарника). Между AMFI-базами смещения не совпадают ни для одного из 90 xref, совпадает расстояние «пролог → xref» внутри функции (73 из 90) — подробнее в `T3_result.md`.

## Что было сделано и почему это неверно

В `x13/kernelcache.patched` (62 881 792 байта) по адресу `0xfffffff00a305440` инструкция `b40003e0` (`cbz x0, +0x7c`) заменена на `d503201f` (`nop`). Файл отличается от оригинала ровно этими 4 байтами (смещение в файле `0x3301440`).

```
0xfffffff00a305428  aa0803e0  mov x8, x0
0xfffffff00a30542c  52800061  mov w1, #0x3
0xfffffff00a305430  52800182  mov w2, #0xc
0xfffffff00a305434  52800003  mov w3, #0x0
0xfffffff00a305438  d2800004  mov x4, #0x0
0xfffffff00a30543c  97ecb4e8  bl  -0x4d2c60
0xfffffff00a305440  b40003e0  cbz x0, +0x7c     ← заменено на nop
0xfffffff00a305444  aa0003f4  mov x20, x0
0xfffffff00a305448  97ee7c4e  bl  -0x460ec8
0xfffffff00a30544c  b40003c0  cbz x0, +0x78
```

`x0` после первого `bl` — результат поиска процесса, а не решение о разрешении. NOP ведёт не к разрешению, а к падению с `x0 = 0` на следующем `bl`. Сайт для патча не тот.

Сигнатура, которую ищет vphone (`ldr wPid,[xArgs,#8]` … `cbz wPid; mov w1..x4 = 0; bl; cbz x0` на ту же цель), не встречается в `__text` ядра ни разу: на 23F84 (`__text` `0xfffffff009de1000`, размер `0x8493e8`) и на 24B156 (`0xfffffe000ab95000`, размер `0x900618`) — 0 совпадений по полному паттерну и 0 пар «`ldr wRt,[xRn,#8]`, затем `cbz wRt` в пределах 8 инструкций». Причина не установлена: либо сигнатура относится к билду Basil (24B119), либо в этих сборках проверка устроена иначе.

## Почему пропатченный kernelcache всё равно не загружается на железе

BootROM проверяет подпись LLB, далее цепочка до kernelcache проверяет каждая ступень; APTicket привязывает набор хэшей к ECID. Ключ проверки находится в BootROM/SEP, заменить образ на неподписанный нельзя. В vphone это не обходится, а отсутствует: загрузочная цепочка собирается заново и корень доверия заменён (подробно — `03_vphone_as_lab.md`).
