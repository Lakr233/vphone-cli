# vphone как лаборатория

Источник: чтение кода vphone-cli и Research-заметок (отчёт `V1_result.md`), Basil на диске и через сокет (отчёт `V2_result.md`). Заявления «проверено / boots» в чужих заметках — заявления авторов, а не результаты этих запусков.

## Что в vphone является обходом

Рантайм-эксплойта ядра в коде нет, кода, использующего уязвимость, — тоже. Обход сделан оффлайн:

1. Хост правит байты в LLB, iBSS, iBEC, AVPBooter, SPTM, TXM и kernelcache и прошивает результат в VM как кастомную прошивку (CFW). Корень доверия при этом заменён: BootROM и SEP ROM в VM не оригинальные (OpenAVB/OpenSEP), поэтому подпись Apple не проверяется.
2. Гость загружает уже ослабленное ядро; в рантайме его никто не трогает.
3. В госте работает только userspace: dylib через `DYLD_INSERT_LIBRARIES` и патчинг чужого userland-кода через `vm_protect`/`vm_write`. Это возможно лишь потому, что ядро заранее ослаблено.

## Что применено в Basil (PatchReceipt.plist)

План — 220 патчей. Применено 165 (LLB 6, iBSS 3, iBEC 4, DeviceTree 29, TXM 7, kernelcache 56, Guest 61), 55 помечены «неприменимы» — это бинарки, которых нет в сборке 24B119 (складные, HomePod, Watch, отладочные библиотеки), плюс один патч сверх плана. Основа — iOS 27.2 (24B119), вариант `jb`.

Среди патчей kernelcache: `kernel-boot-amfi_execve`, `kernel-boot-amfi_trustcache`, `kernel-cfw-task_for_pid`, `kernel-cfw-debugger`, `kernel-boot-kcall10` (syscall 439 → вызов произвольной функции ядра), `kernel-boot-sandbox_ext`, `kernel-boot-vm_map_protect` и др.; в TXM: `developer_mode_bypass`, `trustcache_bypass`, `get_task_allow`, `debugger_entitlement`, `executable_remap`.

Скрытие гипервизора (`kern.hv_vmm_present`, `IsVirtualDevice`) включено вручную: в пресете `standard` оно выключено, потому что роняет `bluetoothd` в crash-loop.

## Доступ к работающему Basil с хоста

| Нужно | Как |
|---|---|
| Любой файл гостя от root | `rpc` → `files.read/write`, `fs.read/write` в `script.eval` |
| Команды, JS + ObjC от root | `script.eval` → `proc.run(path, args, input)`; `processes.spawn` (allowlist `ps`/`launchctl`/`log`) |
| Свой LaunchDaemon | `services.load`, `bootstrap.install` |
| Дамп памяти | `{"t":"memory.dump","path":…}` — `AP.core` по виртуальным адресам ядра, `SEP-coproc.core`; `"physical":true` — `physical.elf`; `process.dump` с `pid` — память одного процесса |
| Отладка ядра | запуск с `--kernel-debug-port` → GDB-stub для LLDB |
| HTTP API | только если VM запущена с `--api-listen`; у Basil выключен |

Сокет — `~/.vphone/machines/Basil/vphone.sock`, одна JSON-строка `{"t":…}` на запрос и ответ; обёртка `tools/vrpc.py`. Дампы не содержат системных регистров (TTBR, PAC-ключи). Запись в память — только через LLDB на debug stub.

## Что это даёт для задачи на железе

- **Проверка офлайн-находок до железа.** Любой сайт патча можно сверить с работающим ядром Basil (дамп памяти, LLDB) и тут же увидеть, сработал ли он.
- **Несовпадение уже найдено.** `kernel-cfw-task_for_pid` применён, а `task_for_pid` из приложения на Basil возвращает failure (`02_live_probes.md`). Значит, патч либо относится к другой проверке, либо требует условий, которых у пробника нет.
- **Не переносится.** Всё, что делает vphone с загрузочной цепочкой, опирается на заменённый BootROM. На iPhone 13 (retail-чип) и на 17 Pro Max это недоступно.
- Бутстрап (apt/SSH) в Basil не установлен; `/usr/bin/id`, `/bin/launchctl`, `/usr/sbin/sysctl` в базовом образе отсутствуют.
