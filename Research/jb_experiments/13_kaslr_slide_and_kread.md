# 13. Слайд KASLR без паники, чтение памяти ядра, гейты `task_for_pid` (Basil, 24B119)

Дата: 2026-11-26. Объект: Basil VM, iOS 27.2 / 24B119, CFW `jb`, `vresearch101`.
Ядро: Kernel UUID `784F88D3-2AF5-3D4A-AB00-365607646E44`, извлечено заметкой 03.
Живая проверка: boot M, slide `0x29840000` (VM упала в панику 26.11 21:52 из-за вызова по адресу, набранному
вручную с опечаткой; см. 1.1). Слайд действителен только до перезагрузки — перед новыми чтениями читать заново.

## 1. Слайд: `slide = (VBAR_EL1 & 0xffffffff) - 0x8cab000`

GDB-stub vphone отдаёт только регистры. `VBAR_EL1` достаточно: слайд считается по нему, без паники.

| boot | VBAR | slide по VBAR | slide по panic `lr - 0xfffffe0008ca7850` | XNU `Kernel slide` |
|---|---|---|---|---|
| D | `0xfffffe004c5d7000` | `0x4392c000` | `0x4392c000` | — |
| G | `0xfffffe0044883000` | `0x3bbd8000` | `0x3bbd8000` | `0x3bbdc000` |
| H | `0xfffffe00309cb000` | `0x27d20000` | `0x27d20000` | `0x27d24000` |
| I | `0xfffffe004532f000` | `0x3c684000` | `0x3c684000` | `0x3c688000` |
| M | — | — | `0x29840000` | `0x29844000` |
| N | `0xfffffe0033b17000` | `0x2ae6c000` | `0x2ae70000` | `0x2ae70000` |
| O | `0xfffffe0049899000` | `0x3cde0000` | — (паник не было) | — |

- Прямая проверка (boots K, L, M): вызов `mov w0,#1; ret` (link `0xfffffe0008cd8a78`) по `link + slide` вернул `1`, VM жива.
- Boot N (перезапуск 26.11 22:11 после паники): слайд `0x2ae6c000`; тот же контрольный вызов вернул `1`; живые байты гейтов
  `0x91de128/268/26c/2bc` и патча `0x8d087a8` совпали с файлом слово в слово. Подтверждает: адреса верны на любой загрузке, меняется только слайд.
- Boot O (22:28, после паники N): тот же контрольный вызов `r=1`, те же байты гейтов. `kslide.py` теперь сам отправляет `kx` в гость
  (`/private/var/tmp` очищается при загрузке).
- XNU `Kernel slide` = слайд fileset + `0x4000` (заголовок kernelcache, link `0x7008000`).
- Слайд меняется на каждой загрузке. Вызов по слайду прошлой загрузки — fetch abort.
- `0x8cab000` верен только для 24B119; для другого билда его надо искать заново.

Инструмент: `/tmp/jbresearch/kslide.py`. Без аргументов — слайд; `--selftest` сверяет формулу с сохранёнными panic-логами;
`--call LINK [a0..a6]`; `--read LINK...`. Вся арифметика — в скрипте, не вручную.

### 1.1. Паника 26.11 21:52 (boot M потерян): адрес набран вручную с опечаткой

Вызов шёл по `0xfffffe003550ea78`; верный адрес для boot M — `0xfffffe0032518a78` (= link `0x8cd8a78` + слайд
`0x29840000`). Расхождение `0x2ff6000`, instruction fetch abort. Причина — ручной набор готового числа, а не расчёт слайда
(подтверждено файлом вызывающего: `/tmp/jbresearch/tfp13/selftest.txt`).

| регистр в panic-логе | значение | что даёт |
|---|---|---|
| `lr` (сайт возврата из cave, link `0x8ca7850`) | `0xfffffe00324e7850` | слайд `0x29840000` |
| `x8` (`sysent[439].sy_call`, link `0x8ca7804`) | `0x02a27e00324e7804` | `0x8ca7804 + 0x29840000`, тот же слайд |
| `pc` (вызванный адрес) | `0xfffffe003550ea78` | неверный адрес, fetch abort |

Тот же слайд `0x29840000` читается тремя способами: по `VBAR_EL1` (`kslide.py`), по `lr` в panic-логе, по указателю в `sysent`.

Две строки слайда в panic-логе — один физический сдвиг, напечатанный от одной link-базы `0x7004000` (заголовок kernelcache,
на `0x4000` ниже `__TEXT`). Проверено на шести логах (G, H, I, K2, L, M), во всех одинаково:

| величина | значение | что это |
|---|---|---|
| `Kernel text base − Kernel slide` | `0x7004000` | link-база |
| `Kernel text exec base − Kernel text exec slide` | `0x7004000` | та же link-база |
| `Kernel text exec slide − Kernel slide` | `0x1ca0000` | смещение `__TEXT_EXEC` (`0x8ca8000 − 0x7008000`) внутри образа |
| `Kernel slide − slide по VBAR` | `0x4000` | сдвиг заголовка (раздел 1) |

`Kernel text exec base` — это адрес `__TEXT_EXEC` в рантайме: `0x7004000 + 0x1ca0000 + Kernel slide`. Второго слайда у текста нет:
`lr` и `x8`, лежащие в `__TEXT_EXEC`, едут на том же слайде, что и `sysent` в `__DATA`. Прибавлять `text exec slide` к link-адресам нельзя.

Правило: адрес для `kx` не набирать и не считать руками — только `kslide.py --call LINK`. Нарушение этого правила и привело к панике.

### 1.2. Первая запись в память ядра (boot N потерян): что показала паника

Примитив записи — гаджет `str x1,[x0]; ret` (link `0xfffffe0008d1ecd8`, сосед аксессоров `str w1,[x0]; ret` /
`ldr x0,[x0]; ret`). Вызов `kx GADGET dst value` доставил аргументы верно, панику дала защита страницы:

| регистр в `panicN.log` | значение | что показывает |
|---|---|---|
| `pc` | `0xfffffe0033b8acd8` | gadget link + slide `0x2ae6c000`: вызов дошёл до цели |
| `x0` | `0xfffffe00325dbcd0` | `sysent[439]` + slide: адрес доставки верен |
| `x1` | `0x1` | значение доставлено верно |
| `far` | `0xfffffe00325dbcd0` | fault на адресе записи |
| `esr` | `0x9600004f` | data abort на записи, permission fault, level 3 |

`sysent` лежит в `__DATA_CONST` (`0x76a0000..0x77d4000` по load commands), а не в `__DATA` — я считал иначе, не проверив,
и потерял загрузку. Вывод: примитив записи работоспособен; цели нужно выбирать по load commands, а не по имени.

### 1.3. Живое чтение `proc` launchd (boot P): какой гейт `task_for_pid` отказывает root

Все отказы `task_for_pid` дают одно значение `kr=5` (`KERN_FAILURE`): `0x91de300`, `0x91de2b8`, `0x91de2d8` — `mov w23,#5`.
Поэтому по возвращаемому значению гейт не определяется; ниже он определён чтением полей `proc` цели.

`proc_find(pid)` = link `0xfffffe00091d3330` (вызов через `kx`, аргумент `x0 = pid`, возвращает `proc*`; heap-адрес, слайдом не смещается).

| поле | значение (launchd, pid 1) | гейт в `task_for_pid` | исход |
|---|---|---|---|
| `p_pid` `+0x60` | `1` | — | — |
| `+0x458` | `0x800002` | `0x91de18c tbz w8,#1` | бит 1 = 1 → проходит |
| `csflags` `+0x464` | `0x5c0` | `0x91de248 tbz w8,#4` / `0x91de24c tbz w10,#4` | бит 4 = 0 → к `0x91de250` |
| **`+0x15`** | **`0x7e`** | **`0x91de250 ldrb [x22,#0x15]; tbz w8,#0 → 0x91de2b8`** | **бит 0 = 0 → отказ `kr=5`** |
| MACF `mac_proc_check_get_task` | — | `0x91de268 bl; cbnz w0` | **не достигается** для root |

Вывод: для root-процесса `task_for_pid` отказывает **первый** гейт — `tbz` по биту 0 байта `+0x15` структуры `proc`, — а не MACF-проверка. Прежняя формулировка (13, 14: «отказ root идёт из MACF») снимается: она была сделана по файлу, без учёта этого гейта и без живого чтения.

Смещения 27.2, уточнённые по дампу: `p_pid` `+0x60`, `p_comm` **`+0x56c`** (не `0x55c`), `csflags` `+0x464` (32-битное).
Байт `+0x15` — не флаговый набор: в ядре есть сайты `mov w8,#1; strb w8,[x,#0x15]` (`0x8d6df8c`, `0x8d6e530`), то есть поле принимает значение 1 целиком; имя поля по бинарнику без символов не определяется.

Что это меняет для проверки: NOP нужен на `0x91de254` (`tbz`), а не только на `0x91de26c` (MACF). Один NOP на MACF результата бы не дал — исполнение до него не доходит.

### 1.4. Патч `kernel-cfw-task_for_pid-root`: написан, не применён

Чтобы проверить, что `tbz` по `+0x15` — единственный отказ root, нужен NOP на `0x91de254` в загружаемом образе:
запись в `__TEXT_EXEC` из ядра закрыта (1.2), `cfw update-kernel` файл не принимает — перепатчивает из `FirmwareOriginals`
по выбору `fw set-patches`. Значит патч надо добавить в набор и пересобрать `vphone-cli`.

Что сделано (не закоммичено, репозиторий публичный):

| файл | изменение |
|---|---|
| `Kernel/CustomFirmwarePatches/Process/KernelCustomFirmwarePatchTaskForPid.swift` | `patchTaskForPidRootGate()`: от якоря `proc_ro_ref_task` ищет форму `ldrb wN,[xM,#0x15]; tbz wN,#0; ldr xK,[xJ,#8]; mov x1,sp; mov x0,xK; mov w2,#0; bl` и NOP-ит `tbz` |
| `Kernel/KernelCustomFirmwarePatcher.swift` | вызов `patchTaskForPidRootGate()` после `patchTaskForPid()` |
| `PatchSets/FirmwareKernelCustomFirmwarePatchSet.swift` | декларация `kernel-cfw-task_for_pid-root` |

Форма, не адрес — переносима между билдами, как и существующий `kernel-cfw-task_for_pid`. Компилируется (`xcodebuild -workspace
VPhone.xcworkspace -scheme VPhone` → `BUILD SUCCEEDED`, модули `FirmwarePatcher`/`VPhoneCommand` собраны).

Что НЕ сделано и почему: схема `VPhone` собирает библиотеки, но не цель `vphone-cli`, а с `CODE_SIGNING_ALLOWED=NO` bundle-фаза
не выполняется — `Products/Release/VPhone.bundle` содержит только `Info.plist`. Рабочие бандлы `2.18.0-local.*` подписаны
(`_CodeSignature`) и содержат `vphone-cli` + `vphone-vm`. Для применения нужна полная процедура: схема, собирающая `vphone-cli`,
подпись, `vphone-launchpad-cli bundle install-local <bundle> --keep-default`, `vm set-bundle Basil <ver> --update-environment`
(VM остановлена), затем `cfw update-kernel Basil` и загрузка. Процедура пересборки в этом репозитории не описана
(`Research/Host/vphone_cli_setup_this_mac.md` — только установка; `5212b4a2` собран другим тредом).

После применения — тест: `task_for_pid(1)` из root. Ожидания: `0` → `tbz` был единственным гейтом; `0xe` (`KERN_MEMORY_FAILURE`... в S2 —
`w23=0xe`) → за ним стоит `task_conversion_eval`; иное значение → гейт не тот.

## 2. Чтение памяти ядра

Гаджет `ldr x0,[x0]; ret` (8 байт), link `0xfffffe0008d1ebc4`. Поиск: `/tmp/jbresearch/basil/krd.py`.

| link | прочитано (LE, по 4 байта) | что там |
|---|---|---|
| `0x8ca7804` | `d503237f d100c3ff` | cave: `pacibsp; sub sp,sp,#0x30` |
| `0x776fcd8` | `0x02a27e00 324e7804` | `sysent[439].sy_call`: низ = cave + slide, старшие биты — PAC |
| `0x91de128` | `1f2003d5 01008052` | `nop; mov w1,#0` |

Указатели в `__DATA` декодированы (не chained-fixups, как в файле) и подписаны PAC.

## 3. Гейты `task_for_pid` (ответ на открытый вопрос 1)

`task_for_pid`: link `0xfffffe00091de0e8`, размер `0x464`. Вся функция сверена: файл и живая память совпадают.

| сайт | link | инструкция | статус |
|---|---|---|---|
| S1 `pid == 0` | `0x91de128` | `nop` | пропатчен (`kernel-cfw-task_for_pid`) |
| port → task | `0x91de13c` | `bl` + `cbz x0` → kr=5 | штатно |
| `proc_find` | `0x91de14c` | `bl` + `cbz x0` → kr=5 | штатно |
| `posix_check` | `0x91de17c` | `bl` + `cbz w0` → kr=5 | root проходит |
| **S3 MACF** | `0x91de268` | `bl 0xfffffe00094cf514` (`mac_proc_check_get_task`) | штатно |
| **S3** | `0x91de26c` | `cbnz w0` (`35000260`) → `x21=0; w23=5` | **не пропатчен: отказ для root** |
| upcall | `0x91de430` | `bl` + `cbnz w0` | после MACF, к отказу root не ведёт |
| S2 conv eval | `0x91de4dc` | `bl 0xfffffe00091de66c` → `b task_conversion_eval_internal` | провал → `w23=0xe` |

Вывод: патч убирает только S1. Отказ даёт MACF-хук `mac_proc_check_get_task` (S3).
Рядом в `__cstring` (`0x7087d46` и далее): `tfp`, `com.apple.system-task-ports.name.safe`,
`com.apple.private.debug_port`.

Для root без entitlements нужен NOP на `0x91de26c`: `60 02 00 35` → `1f 20 03 d5`.
Это адреса 24B119, не готовый патч: по гардам патчера сайт надо искать структурно (форма входа `ldr w0,[x0]; ldr w24,[x8,#8];
ldr x19,[x8,#0x10]` + `bl` + `cbnz w0` + следующий `ldr w8,[x26,#0x18]; cmp w8,#0`).

S6 (`ios26-kernel-research/task_for_pid_gate.md`) даёт ту же причину, но другие адреса: в ней база `0xfffffff0…`,
сверка с Basil — по смещениям, не по VA.

## 4. Инструменты

Все копии — в `Research/jb_experiments/tools/basil_kcall/`; рабочие копии во `/tmp/jbresearch/` пропадут после перезагрузки.

| Файл | Назначение |
|---|---|
| `kslide.py` | слайд по `VBAR_EL1`; `--selftest`, `--call LINK [a0..a6]`, `--read LINK...` |
| `vsp.py` | клиент GDB-stub. Протокол: `+`, `QStartNoAckMode`, `?`, `QThreadSuffixSupported`, чтения, `D` |
| `kx.c` | драйвер kcall10: `svc #0x80` в inline-asm, возврат 64 бита (libc `syscall()` возвращает `int` и обрезает указатели) |
| `krd.py` | поиск 8-байтовых функций-гаджетов в `__text` |
| `bsh.sh` | исполнить скрипт в госте через shell-сокет (root) |
| `panic_slides.md` | выжимка слайдов из panic-логов G, H, I, K2, L, M (полные логи не переносятся: в них ECID и UDID гостя) |

- Сборка `kx`: `xcrun -sdk iphoneos clang -arch arm64 -miphoneos-version-min=14.0 -o kx kx.c; codesign -s - --force kx`.
- `kx` пишет в `/private/var/tmp/kx.out` (append). Вывод `r=0x%016llx`. Результат забирать `pull` по файлу, не через PTY.
- Выгрузка `task_for_pid` и `task_conversion_eval`: 0xa00 байт из `kernelcache.kc` по смещению `link - 0xfffffe0007008000 + 0x4000`, начиная с `0x91de0e8`.
- Гость очищен: в `/private/var/tmp` нет ни `kf`, ни `kx`, ни `kx.out` (листинг пуст, 26.11). Для нового чтения `kx` запушить заново.
- `Basil.log` перезаписывается при `vm launch` — копировать до перезапуска.

## 5. Не сделано

- Записи в память ядра нет. Для NOP на S3 в памяти нужен гаджет записи.
- `0x8cab000` и адреса сайтов проверены только на 24B119.
- PAC с указателей не снимался.
- vphone-патч `kernel.info` (`filesetSlide`) не нужен для цели и не работает на этом хосте (`mach_vm_remap: 57`).
