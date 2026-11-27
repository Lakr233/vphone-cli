# 23. Сводный индекс треда «Создание jailbreak для iPhone 17 Pro»

Дата: 2026-11-26. Автор — основной тред этого раздела. Это оглавление проделанной работы, а не новый результат: числа и выводы здесь — краткие пересказы, доказательства лежат в указанных файлах. Открытые вопросы и следующие шаги — в `05_open_questions_and_next.md`, здесь не повторяются.

## 1. Направление

Перенести метод vphone (оффлайн-патчи kernelcache и загрузочной цепочки) на физические устройства владельца: iPhone 13 (A15, 26.5.2 / 23F84) и iPhone 17 Pro Max (A19, 27.2.1 / 24B156), оба retail (`CPFM:03` на iPhone 13 подтверждён по Recovery-serial). Все запуски на устройствах — владельцем, с его участия; VM Basil использовалась как лаборатория.

Вопросы, которые задавал пользователь по ходу, и чем каждый закончился:

| Запрос | Итог |
|---|---|
| «нужен джейлбрейк» | поставлена цель; понято, что метод vphone воспроизводится до границы BootROM (`01`, `03`) |
| «ищи kernel exploit» | публичного под 23F84 / 24B156 нет; составлена карта кандидатов (`04`, `12`) |
| «изучая vphone можно найти что-то?» | vphone — лаборатория: root в госте и дампы памяти; рантайм-эксплойта в коде нет (`03`, `V1_result.md`, `V2_result.md`) |
| «поищи на форумах / на GitHub по ключевикам» | найдены аудит IOKit 27.2, `worse_query`-экосистема, PoC CVE-2026-65343, `ios26-kernel-research` (`04`, `07`, `08`) |
| «зафиксируй все результаты в .md» | файлы `01`–`08`, `README.md` |
| «какой прогресс по KASLR», «тестируй ещё, можешь и 17 Pro Max» | пробник на обоих устройствах: 0 утечек в доступных из sandbox API (`06`) |
| «ну тестируй» (после находки `AppleKeyStore`) | открыт, но без ACM-хэндла данных не даёт (`08`) |
| «что вообще мог бы дать джейлбрейк?» | ответ в чате: ядро в руки (R/W, `task_for_pid`, отладка на живом чипе); BootROM/SEP и подпись прошивки не открываются |

## 2. Сабтреды, запущенные из этого треда

Все — `bb thread spawn --project proj_udj8f4qa44 --parent-self`. Приглашения лежали в `/tmp/jbresearch/research/*.md` (пропадут после перезагрузки); формулировки нейтральные, без деталей по эксплойтам.

| ID | Задача | Чем закончился | Файл |
|---|---|---|---|
| `thr_tc2rdad3dm` (T1) | ландшафт публичных boot-chain / kernel-эксплойтов; позже — обзор методов модификации ядра | BootROM: checkm8 ≤ A11, usbliter8 A12/A13, A14 — отрицательный результат, A15/A19 — ничего. На A15 SPTM-байпас публично только у Titan (до 17.3.1): kernel-эксплойта под 26.5.2 самого по себе недостаточно | `04`, `16_kernel_modification_methods.md`, `tools/upstream_snapshots/` |
| `thr_hf2wkng6rd` (T2) | анализ исходников vphone | Эксплойта и эмуляции SPTM/TXM/PPL в vphone нет: это байтовые патчи образов до загрузки, принимаемые потому, что корень доверия подменён на хосте (BootROM — OpenAVB без проверки digest, SEP ROM — OpenSEP без `ENFORCE_IMAGE_TRUST`; TSS настоящий). Содержимое `OpenAVB.bin`/`OpenSEP.bin` автор не читал — вывод по документам. На железо не переносится | `03`, `17_vphone_mechanisms.md` |
| `thr_zitiu7qkjd` (T3) | карта xref AMFI на обоих kernelcache | 90 xref; по смещению от базы 0 совпадений, по расстоянию «пролог → xref» 73 из 90 | `T3_result.md` |
| `thr_76br4t9sqg` (V1) | какие патчи в vphone рантаймовые | ни одного: всё — оффлайн-патчи образов | `V1_result.md` |
| `thr_nb8c2gytph` (V2) | доступ к диску и гостю Basil | сокет `vphone.sock` → `vphoned` (root, дампы памяти) | `V2_result.md` |
| `thr_kvxajuxy2x` (K1) | пробник утечки раскладки ядра (`host_info`, `host_statistics{,64}`, `task_info`, `proc_info`) | собран; запущен из этого треда на обоих устройствах | `06`, `15_kaslr_api_leak_probe.md`, `tools/kaslr_probe/` |
| `thr_itairhc6yq` | загрузка dylib и диагностика ФС | оборвался, состояние записано | `18_dylib_load_fs_diag.md` |
| `thr_gtdeneyvue` | завершение приложения по SIGTERM | оборвался, состояние записано | `19_sigterm_app_exit.md` |
| `thr_p3edwia686` | сканирование по inode порциями | порционная версия вне репо: `/Users/i_strelov/Projects/vphone/pathleak_chunked/` | `20_pathleak_inode_scan.md` |

Файлы `14`, `22`, `24`–`31` и `L13_result.md` — соседних тредов (A/B/C и другие), отсюда не запускались; в README они уже описаны.

## 3. Что сделано руками в этом треде

| Шаг | Результат | Файл |
|---|---|---|
| Patchfinder (строка → xref → функция) на обоих kernelcache | работает; адреса политики, `mac_policy_conf`, ops-таблицы, allow-stub совпадают по структуре | `01`, `tools/patchfind.py`, `tools/disasm.py` |
| Первый патч `task_for_pid` (NOP на A15) | **неверен**: снята проверка результата поиска процесса; файл `kernelcache.patched` не использовать | `01` |
| `task_for_pid` / порт ядра на живых системах | закрыт на железе и на Basil | `02` |
| Root в Basil с хоста | `vphone.sock` → `rpc` → `script.eval` (JS + `fs`, `proc`) | `02`, `03`, `tools/vrpc.py` |
| Recovery-serial iPhone 13 | `CPFM:03` — retail | `02` |
| Перечень контейнеров (`fsgetpath`) | 17 Pro Max: 674; iPhone 13: 0 в проверенном окне | `02`, `20` |
| IOKit из app sandbox | `AppleAVE2` закрыт; открыты `AppleKeyStore`, `AppleJPEGDriver`, `IOMobileFramebuffer`, `IOSurfaceRoot`, `AGX` | `07`, `tools/iosvc/` |
| `AppleKeyStore`, селекторы 1–163 | хэндл из процесса не получить; 0 утечек; на 26.5.2 и 27.2.1 неразличимо | `08`, `tools/aksprobe/` |
| `IOHIDEventService` + `IOServiceOpen(type=2)` из app sandbox | это `IOHIDEventServiceFastPathUserClient`, не `IOHIDEventServiceUserClient`: guard мягкий (entitlement `…user-access-fast-path` только ставит флаги `+0x118`/`+0x119`), все 67 экземпляров открываются, скалярные селекторы 0–5 → `BadArgument`. `IOHIDEventServiceUserClient` (CVE-2026-43739/43816) закрыт: только по `type='esuc'` и без `com.apple.hid.system.user-access-service` клиент не создаётся | `36`, `tools/hid_fastpath/` |
| Content filter `com.apple.content-filter` из app sandbox | `CTLIOCGINFO` → `ctl_id=4`, `connect()` → **EPERM** (`CTL_FLAG_PRIVILEGED` → `kauth_cred_issuser`); свой фильтр поставить нельзя. `net.cfil.active_count` из sandbox → EPERM | `38`, `tools/cfil_probe/` |
| `necp_client_add_flow` (дифф 26.5.2 → 26.6.1) | лимит ресурсов (счётчик `+0x498` против глобального лимита 10000, при исчерпании — путь без `ldadd`-удержания), не memory-bug | `27` |
| `nstat_client_handle_query_request` (тот же дифф) | досягаем из sandbox (поправка к `35`), но тело запроса даёт только `srcref` и `context`/`flags`; изменение — `csel` двух счётчиков статистики, не memory-bug | `39` |

## 4. Инструменты (исходники, без бинарок)

`tools/patchfind.py`, `disasm.py` (бывший `dis.py`: имя затеняло стандартный модуль Python и ломало импорт capstone из этой папки), `findxref.py`, `kc.py`/`kcx.py` (чтение слов и cstring по VA), `fdis2.py` (дизассемблер по одному слову, capstone) — работа с kernelcache. Для сравнения функций между билдами — `tools/kdiff2/fdiff.py` соседнего треда (по прологам, нормализованный дифф); побайтовое сравнение «от адреса N слов» даёт ложные расхождения. `tools/vrpc.py` — обёртка сокета Basil. `tools/`: `wqprobe.m` (`task_for_pid`, `fsgetpath`), `kprobe.m` + `tools/kaslr_probe/` (утечка раскладки ядра), `iosvc.m` + `tools/iosvc/` (достижимость IOKit), `aksprobe.m` + `tools/aksprobe/` (AppleKeyStore). Сборка: `xcodegen generate` → `xcodebuild -sdk iphoneos`, команда запуска — `xcrun devicectl device process launch --console`.

Собранные `.app` остались в `/tmp/jbresearch/dd*` (после перезагрузки пропадут; пересобираются из исходников).

### Состояние на 2026-11-27 (конец прохода): iPhone 13, 23F84

**Закрыто за проход (живьём или по бинарнику):** KASLR-векторы и nstat-источники (`35`), `IOHIDEventServiceUserClient` (`36`), свой content filter (`38`), UAF `necp_client_qualify_flow` по досягаемости (окно по исходнику есть, триггер из sandbox не показан — нужен root либо чужой фильтр + policy на сокет жертвы), `necp_client_add_flow` и `nstat_client_handle_query_request` как memory-bug (`27`, `39`).

**Открыто:**

| Что | Почему застряло |
|---|---|
| Методы `IOHIDEventServiceFastPathUserClient` | таблица получена (`36`): `open` (сел. 0), `close` (сел. 1), `copyEvent` (сел. 2). **`open` проходит из sandbox без entitlement** на свободных сервисах `AppleSPUHIDDriver` (4 из 64; остальные «already opened»). Ранний вывод «закрыт» снят: вызовы отбивал диспетчер из-за неверного числа выходных скаляров. `copyEvent` не разобран |
| Карта таблиц внешних методов, `IOSurfaceRootUserClient` | разобрано (`43`): 341 селектор в 18 образах; `IOSurfaceRoot` type 0 из sandbox вызывает методы; 13 селекторов с входной структурой любого размера — не разобраны |
| Декодирование `DYLD_CHAINED_PTR_64_KERNEL_CACHE` в `__DATA_CONST` | решено (`36`): база `0xfffffff007004000`, адрес = `base + (raw & 0x3fffffff)`; верно и для `isAuth=1`. Инструменты `tools/kdiff2/kcptr.py`, `kstarts.py` |
| Остались «не разобраны» из `27`: `nstat_ifnet_report_lim_stats`, `netagent_handle_update_inner`, `tracker_dump`/`tracker_action`, `bpfioctl`/`bpf_setup` | досягаемость из sandbox не показана — поиск, не кандидат |
| FastPath на 17 Pro Max (24B156) | закрыт живьём (`36`): `IOServiceOpen(IOHIDEventService, type=2)` → `kIOReturnNotPrivileged` на всех 78 экземплярах |

**Чего больше нет:** закрыты из показанно досягаемых — `IOHIDEventServiceUserClient` (`esuc`), cfil, nstat `ADD*`, FastPath на 24B156. **Открыты и не разобраны до конца:** FastPath `copyEvent` на 23F84, `IOSurfaceRootUserClient` (120 селекторов) на обоих устройствах.

**С чего продолжить:** (1) `copyEvent` FastPath (сел. 2 → `0x966f694`): разбор обработки входного словаря и живой вызов на свободном `AppleSPUHIDDriver`; (2) `IOSurfaceRootUserClient` открыт из sandbox и вызывает методы (сел. 13 → `0x00000000`): карта всех 120 селекторов в `tools/kdiff2/out/kdisp_23F84_real.txt`, дальше — селекторы 9/10/11/19/24/26/46–54 (структура любого размера на входе); (3) с рабочим `kcptr.py`/`kstarts.py`/`kdisp.py` пересмотреть выводы `27`/`34`, опиравшиеся на «vtable не получена».

Рабочие файлы в `/tmp/jbresearch/` (`hidev/`, `cfil/`, `ipsw/*.py`) пропадут после перезагрузки; исходники пробников и скрипты скопированы в `tools/hid_fastpath/`, `tools/cfil_probe/`, `tools/kdiff2/`.

## 5. Что осталось открытым

Перечислено в `05_open_questions_and_next.md`. Коротко: причина закрытого `task_for_pid` на Basil при применённом патче, CVE-2026-65405 с неизвестной точкой входа, `worse_query` на iPhone 13, судьба машины Avocado.
