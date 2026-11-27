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


---

## Общие правила (обязательны)

- Отвечай по-русски. Это исследование на устройствах владельца; всё, что не подтверждено первоисточником, помечай `ГИПОТЕЗА`.
- **Не бери ничего из этой инструкции на веру как «факт о билде»**: адреса и смещения ниже — результаты чужого анализа. Перед использованием в живом тесте перепроверь сам по файлу (дизассемблер ниже) и записывай в лог то, что видишь ты.
- **Устройства определяются ТОЛЬКО по devicectl ID.** Разрешены: iPhone 13 `4A8A1186-3B54-5E76-95C0-3E47590416B9` (26.5.2 / 23F84) и iPhone 17 Pro Max `EB205573-B173-5937-B2B1-031211E2944F` (27.2.1 / 24B156). **Запрещено касаться**: `1747203B-5F35-5AB9-A0B4-8649A08FC874` (iPhone-Evgenia-2, чужой), `8F9F654A-C0E6-564F-83DC-2FE5DF9639E2` (Avocado), `75DC7316-88D8-5325-BACA-BEE1C1052302` (Basil — кроме треда C), Apple Watch `14F6CAFF-538C-529F-B891-783450377147`.
- Если нужное устройство `unavailable` — жди не более 15 минут (опрос раз в минуту), затем вернись с `НЕ ВЫПОЛНЕНО` и причиной. **Никогда не подменяй устройство.**
- Рабочие файлы — только в своей папке `/tmp/jbresearch/<своя>/` и в заметках `Research/jb_experiments/` репо `/Users/i_strelov/Projects/vphone/vphone-cli/`. Папку `/tmp/jbresearch/wq2/` не менять (эталон). Чужие папки `/tmp/jbresearch/wq_x13`, `/tmp/jbresearch/wq_x17` — только чтение, кроме треда A (ему выделена `wq_x13` на время работы).
- `support.apple.com` отдаёт 429 после нескольких запросов — не ходить туда; локальные копии адвизори в `/tmp/jbresearch/advisories/` (разобранные по `<h3>`: `cve_index.json`, `entries_by_heading.json`; читаемая версия — `/Users/i_strelov/Projects/vphone/vphone-cli/Research/jb_experiments/ios26-kernel-research/apple_advisory_entries_26.5.2_to_27.2.1.md`).
- Ничего не устанавливать на серверы freehire, кроме явно разрешённого в твоей задаче. Ничего не удалять чужого. Никаких изменений в конфигурацию серверов (ufw, ssh, nginx, systemd) без явного разрешения в задаче.
- В конце: итоговый ответ родителю — кратко: что сделано, вердикт (`подтверждено | опровергнуто | не определено | не выполнено`), пути к артефактам, что осталось открытым. Подробности — в файле заметки.

## Инструменты дизассемблирования (проверено работает)

- `/tmp/jbresearch/mptcp_chk/dump.py <kernelcache> <start_va_hex> <n_ins>` — capstone-листинг диапазона (останавливается на `ret`). venv: `/tmp/jbresearch/venv/bin/python`.
- `llvm-objdump` из Xcode на этих kernelcache дизассемблирует пусто — не трать время.
- `/tmp/jbresearch/igmp/kdiff.py <kc> "<cstring>"` — поиск функции по строке и её xref'ам (`load`, `find_str`, `xrefs`, `func_start`, `dis` — импортируется).
- Kernelcache (несдвинутые статические VA): 23F84 — `/tmp/jbresearch/ipsw/x13/kc.decomp/kernelcache.release.iphone14.decompressed`; 24B156 — `/tmp/jbresearch/ipsw/x17/kc.decomp/kernelcache.release.v54.decompressed`.
- Прежние листинги (чужой анализ, перепроверять): `/tmp/jbresearch/mptcp_chk/x13_soreceive.dis`, `/tmp/jbresearch/mptcp_chk/x17_soreceive.dis`.

## Процедура сборки/подписи/установки пробы на iPhone 13 (проверено в предыдущих прогонах)

Папка проекта `/tmp/jbresearch/wq_x13/` (bundle id `me.strelov.wqprobe`, менять нельзя — профиль только на него). `build.sh` там собирает без подписи (`CODE_SIGNING_ALLOWED=NO`) и подписывает вручную (`sign.entitlements`, сертификат Apple Development, профиль `660687d1-e008-48eb-95d4-739ef6b1f931.mobileprovision`, действует до 2027-11-26). Новый исходник регистрируется в `wqprobe.xcodeproj/project.pbxproj` в четырёх местах (образец — `aio_probe.m`). Установка: `xcrun devicectl device install app --device 4A8A1186-3B54-5E76-95C0-3E47590416B9 <dir>/dd/Build/Products/Debug-iphoneos/wqprobe.app`. Запуск **без** `--console` (с ним виснет на минуты): `xcrun devicectl device process launch --device <ID> me.strelov.wqprobe`; лог забирать: `xcrun devicectl device copy from --device <ID> --domain-type appDataContainer --domain-identifier me.strelov.wqprobe --source tmp/out.txt --destination <свой путь>`. Крэш-логи: `--domain-type systemCrashLogs`. Пример пробы и записи лога: `/tmp/jbresearch/wq_x13/iogpu_l13_probe.m`, `wqprobe.m`.

## Вызовы в ядро на Basil (правило появилось после инцидента 2026-11-26 21:52)

- Инцидент: сабтред C вручную набрал готовый адрес для `kx` (kcall10) с опечаткой — `0xfffffe003550ea78` вместо `0xfffffe0032518a78` (link `0x8cd8a78` + slide `0x29840000`). Результат — Kernel instruction fetch abort, VM в панике. Boot M потерян.
- Адреса ядра **не набирать и не считать руками**. Считать только скриптом из link-адреса по файлу kernelcache и слайда, прочитанного заново после каждой загрузки VM (`tools/basil_kcall/kslide.py --call LINK` / `--read LINK`). Перед вызовом вывести скриптом: link, slide, сумму — и вызвать ровно то, что вывел скрипт.
- Строка `Kernel text exec slide` в panic-логе выражена от другой link-базы; к link-адресам её не прибавлять. Слайд один для всех сегментов.
- Если Basil одновременно используется другим тредом (GDB-stub, shell-сокет) — никаких вызовов через kcall10 без явного предупреждения того треда.
- Если Basil в панике — не перезапускать. Сохранить лог (`~/Library/Logs/vphone-launchpad/Basil.log` перезаписывается при следующем запуске), сообщить родителю; перезапуск — только по решению владельца.
