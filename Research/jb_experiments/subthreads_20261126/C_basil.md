# Задача C: почему на Basil `task_for_pid` закрыт, хотя патчи применены; проверка гипотезы третьего гейта

## Цель
На виртуальной машине vphone «Basil» (iOS 27.2 / 24B119) установить, какая именно инструкция запрещает `task_for_pid` для root-процесса без entitlement, и проверить, устраняет ли её замена отказ. Результат нужен как проверка таблицы патчей S6 (адреса per-build) и как ответ на вопрос 1 из `05_open_questions_and_next.md`.

## Контекст (проверенные факты о стенде)
- Basil: devicectl `75DC7316-88D8-5325-BACA-BEE1C1052302`, iOS 27.2 / 24B119, запущена headless (`vphone-vm … Basil --headless`, pid см. `ps`), запущена **без** `--kernel-debug-port`. Гостевой RPC — unix-сокет `~/.vphone/machines/Basil/vphone.sock`, протокол JSON `{"t":"rpc","method":…,"params":…}` (примеры: `/tmp/jbresearch/wq2/brpc.py`, `ev.py`, `basil.py`).
- Применённые kernel-патчи Basil (из `~/.vphone/machines/Basil/PatchPlan.plist`): `kernel-cfw-task_for_pid`, `kernel-boot-task_conversion_eval`, `kernel-cfw-debugger`, `kernel-cfw-proc_pidinfo`, `kernel-cfw-sandbox_*` и др. (полный список: `plutil -p ~/.vphone/machines/Basil/PatchPlan.plist | grep kernel-`).
- Kernelcache Basil: `/tmp/jbresearch/basil/kc.decomp/` (разобранный, 24B119).
- Прежний результат (чужой анализ, перепроверить): `task_for_pid` для root возвращает `kr=5` даже с обоими патчами. Статический анализ S6 (заметка `Research/jb_experiments/ios26-kernel-research/task_for_pid_gate.md`) утверждает для 24B119: отказ даёт единственная инструкция — `cbnz w0` после `mac_proc_check_get_task` (`0xfffffff00b1ab140`, байты `e0070035`); предложенные патчи: NOP в `task_for_pid` на `cbz` (pid==0), NOP на этом `cbnz`, и `cmp x0,x9 → cmp xzr,xzr` в `task_conversion_eval_internal`.

## Ограничения (жёсткие)
- **Не останавливай, не перезапускай Basil и не меняй её патчи без отдельного разрешения владельца.** Чтение памяти ядра через GDB-stub требует `--kernel-debug-port` при запуске — этого флага сейчас нет. Твоя работа в этом треде: всё, что можно сделать **без** перезапуска.
- На Basil сейчас работает Sileo (pid 96764, на переднем плане) и Procursus в `/var/jb` — не сносить, не переустанавливать. Папку `/var/jb` не менять.
- Не трогать другие машины (`Avocado`) и физические устройства.

## Порядок работы
1. Прочитай заметки: `Research/jb_experiments/05_open_questions_and_next.md` (вопрос 1), `ios26-kernel-research/task_for_pid_gate.md`, `Research/KernelCustomFirmwarePatches/patch_task_for_pid.md`, `patch_task_conversion_eval_internal.md`, `RuntimeVerification/runtime_verification_summary.md`.
2. Сверь статическую таблицу S6 с kernelcache Basil (24B119): дизассемблируй `task_for_pid` (по S6 — `0xfffffff00b1ab060`) и `task_conversion_eval_internal` (`0xfffffff00ac8c188`) через `/tmp/jbresearch/mptcp_chk/dump.py`, подтверди адреса и байты каждой точки отказа. Составь полный список всех `kr=5`-выходов и условий их достижимости для root без entitlement.
3. Установи, что реально применено в работающей системе: по `PatchReceipt.plist` (`~/.vphone/machines/Basil/PatchReceipt.plist`) и по описанию патчей в `Research/KernelCustomFirmwarePatches/` определи, какие инструкции меняют `kernel-cfw-task_for_pid` и `kernel-boot-task_conversion_eval` (какие байты, по каким адресам/сигнатурам). Сопоставь с тем, что нашёл S6.
4. **Проверка без перезапуска**: если гостевой API позволяет прочитать память ядра или выполнить код с привилегиями (`proc.run`, `script.eval`), попробуй прочитать байты по адресам гейтов **в работающей системе** — так мы узнаем, применены ли патчи фактически. Если API этого не позволяет (как прежде — «mach_vm_remap: 57»), зафиксируй это.
5. Если байты в памяти прочитать не удалось — дай ответ на уровне статики: какие инструкции в 24B119 дают `kr=5` for root, и какой минимальный набор патчей нужен (адрес/байты/замена), чтобы `task_for_pid` вернул порт для root-процесса без `task_for_pid`-entitlement. И оцени, что произойдёт после снятия гейта (`convert_task_to_port` → `task_conversion_eval_internal` → IP_DEAD).
6. Гостевые проверки, которые можно сделать без перезапуска: запусти в госте от root (`proc.run` через RPC) небольшую программу, вызывающую `task_for_pid` на живом процессе и печатающую kr; повтори с `task_name_for_pid`. Сравни с таблицей отказов. Сравни с физическими устройствами нельзя — Basil это не они.

## Результат
Заметка `Research/jb_experiments/14_basil_task_for_pid_live.md` с таблицей «адрес → байты в файле → что должно быть после патча → что в памяти (если прочтено)». Вердикт: применяется ли `kernel-cfw-task_for_pid` фактически, применяется ли `kernel-boot-task_conversion_eval`, и какая инструкция закрывает `task_for_pid` (kr=5) на 23F84 и 24B156 — и какая в Basil (24B119) — с адресами и байтами. Родителю — кратко.
