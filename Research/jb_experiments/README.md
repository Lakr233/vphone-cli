# Эксперименты: перенос метода vphone на физические устройства

Дата: 2026-11-26. Все запуски — на устройствах владельца (см. таблицу), с его согласия.

## Статус одним взглядом

| Шаг | Результат |
|---|---|
| Patchfinder (string → xref → функция) на kernelcache обоих устройств | работает, якоря совпадают на A15 и A19 |
| Первый офлайн-патч `task_for_pid` (NOP `cbz x0` на A15) | **неверен**: адрес — проверка результата поиска процесса, а не разрешение `task_for_pid`; файл `kernelcache.patched` не использовать |
| Загрузка пропатченного kernelcache на железе | невозможна: подпись Apple + APTicket, корень доверия в BootROM |
| `task_for_pid` на живом железе (обе машины) | закрыт на всех PID, включая свой |
| `task_for_pid` на Basil (VM, 165 патчей vphone применены) | **тоже закрыт** — см. открытый вопрос №1 |
| Root-доступ в Basil с хоста (сокет → `vphoned`) | работает: fs, процессы, JS от root, дампы памяти |
| BootROM A15/A19 | публичного эксплойта нет; iPhone 13 — retail-чип (`CPFM:03`) |
| Kernel-эксплойт под 23F84 / 24B156 | публичного нет; есть проверяемые кандидаты (файл 04) |
| Sandbox escape `worse_query` | на 17 Pro Max (27.2.1) enumeration путей: 674 контейнера; **сам escape (токен) — работает, но только на `Data/System`**; на iPhone 13 (26.5.2) — 0 и по enumeration (60M/297M inode), и по токену |
| IOKit из app sandbox (оба устройства) | `AppleAVE2` закрыт; открыты `AppleKeyStore`, `AppleJPEGDriver`, `IOMobileFramebuffer`, `IOSurfaceRoot`, `AGX` (`07_…md`) |
| AppleKeyStore / CVE-2026-65343 на обоих устройствах | сервис открывается, но ACM-хэндл из процесса не получить (ctkd/XPC); без хэндла 0 утечек; на 26.5.2 и 27.2.1 поведение неразличимо (`08_…md`) |
| Пробник KASLR-утечки (CVE-2026-65405) на обоих устройствах | запущен на iPhone 13 и 17 Pro Max: 0 попаданий в 34 буферах на каждом при любом сдвиге; `proc_info` заблокирован sandbox — не проверено (`06_…md`) |
| `worse_query` как escape (токен sandbox extension) на обоих | 17 Pro Max: **40/40** на `/private/var/containers/Data/System` (iOS 27 флаг), 0/40 на остальных целях; iPhone 13: 0/80. Токен покрывает всю иерархию `Data/System` (32 контейнера), на соседние пути не распространяется, отзывается (`09_…md`) |
| `nstat` из app sandbox (iPhone 13, 23F84) | сокет `com.apple.network.statistics` открывается без entitlement, но `ADD_ALL`/`ADD_SRC` → EPERM (`PRIV_NET_PRIVILEGED_NETWORK_STATISTICS`, на iOS `nstat_privcheck=1`); `QUERY_SRC` → SUCCESS без данных. Изменённые в 26.6.1 функции nstat: `handle_query_request` досягаем (39), для двух других — не показано. Изменённые в 26.6.1 функции `nstat_*` недостижимы. `28_nstat_reachability.md` |
| `kcall10` на Basil | подтверждён по панике: `syscall(439, 0xdeadbeef…)` → `panic at pc 0xdeadbeefdeadbeef`. Слайд KASLR снимается без паники через GDB-stub (VBAR), `kslide.py`; вызов `mov w0,#1; ret` по слайду вернул 1, VM жива (`12_…md`) |
| Цепочка 26.2 (lightsword) на 23F84 / 24B156 | **не переносится**: AIO-kevent UAF закрыт (knote держит ref, `aio_return` на SIGEV_KEVENT даёт EINVAL; статика обоих билдов + живой прогон 20/20 = контролю), IOGPU hash OOB закрыт (шаг совпадает с аллокацией), «IOMFB 64788» — перепутанный CVE (IOGPUFamily web-content; OOB IOMFB = CVE-2026-64736) (`12_…md`) |
| Способы модификации ядра без BootROM (16) | ни один публичный путь не работает на 23F84/24B156: свой kernelcache и KPF требуют BootROM/подписи, software-jailbreak требует kernel exploit + SPTM-байпас под билд (публичные kernel ≤ 26.0.1, SPTM-байпас на A15 ≤ 17.3.1), SHSH — только при уже работающем jailbreak (`16_…md`) |

## Устройства

| | iPhone 13 | iPhone 17 Pro Max | Basil (VM) |
|---|---|---|---|
| iOS | 26.5.2 (23F84) | 27.2.1 (24B156) | 27.2 (24B119) |
| SoC | A15, D17AP, CPFM:03 retail | A19 (t8150), V54AP | iPhone17,3 |
| CoreDevice | `4A8A1186-3B54-5E76-95C0-3E47590416B9` | `EB205573-B173-5937-B2B1-031211E2944F` | `75DC7316-88D8-5325-BACA-BEE1C1052302` |
| UDID | `00008110-00096C803C31801E` | `00008150-001014840138401C` | — |

## Файлы

Правило индекса: каждый тред пишет в свой файл с уникальным номером. Строку для своего файла в эту таблицу добавляет автор файла; чужие строки не редактировать. Следующий свободный номер — 43.

| Файл | Что внутри |
|---|---|
| `01_patchfinder_and_first_patch.md` | метод vphone, адреса на обоих kernelcache, почему первый патч неверен |
| `02_live_probes.md` | прогоны пробника на железе и на Basil, сырые результаты |
| `03_vphone_as_lab.md` | что даёт vphone как лаборатория: root в госте, дампы памяти, что в коде является эксплойтом (ничего) |
| `04_public_exploit_landscape.md` | что есть публичного, применимость к 23F84 и 24B156 |
| `05_open_questions_and_next.md` | открытые вопросы, следующие шаги |
| `06_kaslr_probe_23F84.md` | прогон KASLR-пробника на iPhone 13: что проверено, что нет |
| `kprobe_13.txt`, `kprobe_17.txt` | сырой вывод пробника с дампами буферов |
| `07_iokit_reachability.md`, `iosvc_out.txt` | что открывается из sandbox по IOKit на обоих устройствах |
| `08_applekeystore_cve_65343.md`, `aks_13.txt`, `aks_17.txt` | AppleKeyStore: селекторы, захват ACM-хэндла, результат |
| `10_cve_2026_86916_site.md`, `ios26-kernel-research/igmp_v3_query_*.dis` | CVE-2026-86916: advisory (26.7/27.0, Kernel, без сайта), дифф XNU 26.5→26.6 и binary-дифф IGMP-функций 23F84 vs 24B156 — сайт не в IGMP |
| `09_worse_query_escape.md`, `wq_escape/*.txt` | worse_query как escape: 40 попыток на цель, что покрывает токен, `kcall10` на Basil |
| `11_sileo_on_basil.md` | Sileo на Basil: работает, база 1273 пакетов, причина краша и исправление |
| `12_chain_26_2_port.md` | порт цепочки 26.2 на 23F84 / 24B156: все kernel-примитивы закрыты, адреса сайтов фиксов |
| `15_kaslr_api_leak_probe.md`, `tools/kaslr_probe/` | пробник утечки слайда через host_info/proc_info/task_info: методика, сборка xcodegen, VM (слайд по VBAR, утечка не нужна) vs железо (слайд не получен), что не проверено |
| `16_kernel_modification_methods.md`, `tools/upstream_snapshots/` | обзор всех способов выполнить модифицированный код ядра на A15/A19 без BootROM (boot chain, KPF, SHSH, SPTM/PPL): что требует, что работает на 23F84/24B156 (ничего), гипотезы (Trellix, PZ) и неисследованное (инъекция в kernel-память вне KIP через kcall/physrw); снимки цитируемых файлов Dopamine/XPF/PongoOS/palera1n с коммитами |
| `13_kaslr_slide_and_kread.md` | Basil: слайд KASLR по VBAR_EL1, чтение памяти ядра через kcall10, гейты `task_for_pid` (24B119); живое чтение `proc` launchd: root отказывает `tbz` по биту 0 байта `+0x15`, MACF не достигается (1.3); примитив записи через `str x1,[x0]; ret` — аргументы доходят, `__DATA_CONST`/`__TEXT_EXEC` защищены (1.2) |
| `14_basil_task_for_pid_live.md` | сабтред C: независимая проверка гейтов `task_for_pid` (Basil 24B119 + 23F84/24B156), что реально дают патчи `kernel-cfw-*` |
| `22_mptcp_86962_live.md` | сабтред A: живой тест MPTCP (кандидат CVE-2026-86962) на iPhone 13, сервер на Linux-хосте freehire-ops |
| `16_kernel_modification_methods.md` | обзор методов модификации ядра iOS и их применимость к 26.5.2 / 27.2.1 (сабтред) |
| `17_vphone_mechanisms.md` | механизмы vphone-cli: BootROM, OpenSEP, OpenAVB, доверие, SEPStorage (сабтред) |
| `18_dylib_load_fs_diag.md` … `21_frida_devicectl_state.md` | четыре рано оборвавшихся этапа: загрузка dylib и диагностика ФС, завершение приложения по SIGTERM, сканер путей по inode, Frida через devicectl — состояние на момент остановки |
| `23_jb17pro_thread_index.md` | сводный индекс треда «Создание jailbreak для iPhone 17 Pro»: направления, сабтреды, открытые вопросы |
| `24_code_analysis_error_state.md` | «Анализ и оптимизация кода»: на чём остановился и с какой ошибкой |
| `25_vphone_cli_setup_this_mac.md` (в `Research/Host/`) | установка и запуск vphone-cli на этом Mac: команды, шаги в Recovery, правка скрипта, что не проверено |
| `26_php2shell_vphone_analog.md` | php2shell / java4shell: почему прямое воспроизведение в Basil невозможно и что является аналогом (`script.eval`, root PTY) |
| `28_yandex_music_mod_state.md` – `31_rea_setup_and_ipa_analysis_state.md`, `32_youtube_tweak_state.md` | состояние сторонних работ на Basil: мод Яндекс Музыки (28), IPA Spotify и apt/dpkg (29), клон VM с новым ID (30), установка rea и анализ IPA (31, один файл на два треда — оба раздела дописаны), твик YouTube (32). Только текст и команды; бинарии, скриншоты, учётки и токены не переносятся |
| `tools/basil_kcall/` | `kslide.py`, `vsp.py`, `kx.c`, `krd.py`, `bsh.sh`, `panic_slides.md` — слайд по VBAR, клиент GDB-stub, драйвер kcall10, чтение памяти ядра |
| `T1_result.md` … `V2_result.md` | отчёты сабтредов (как получены) |
| `27_kdiff_26_5_2_to_26_6_1.md`, `tools/kdiff2/` | дифф kernelcache 23F84 → 23G83 (26.5.2 → 26.6.1): 249 изменённых функций ядра с именами, карта по кекстам; NECP-парсер досягаем из app sandbox (живой прогон на iPhone 13); поправка: ядро 26.x — `xnu-12377.*`, а не `11417` Nyxian 0.11.4 (видео про Sileo на 27) переподписан wildcard-профилем без привилегированных entitlements и запущен на iPhone 13: ставится, поднимает LiveProcess.appex, bootstrapping проходит до конца — среда разработки в песочнице, не вектор. |
| `35_nstat_reachability.md`, `tools/nstat_probe/` | nstat из sandbox на iPhone 13: connect проходит, все пути создания источников — EPERM; закрыто создание источников; `handle_query_request` досягаем (39) |
| `33_github_sweep_issues_prs.md` | повторный обход GitHub по репозиториям, issues и PR: Liter8/usbliter8 (A13 до 24B156), doublera1n, Tims-Cooked, трекер Calif, порт Titan на 26.0.1, патч-анализ 27.0.1 → 27.2; для A15/A19 новых кандидатов нет |
| `34_hid_necp_closed_by_source.md` | два «живых» кандидата 27 на 23F84 закрыты по исходнику: `IOHIDInterface::GetElementValues` — `continue` в невыполнимой ветке, OOB write нет; `necp_client_qualify_flow` — окно UAF есть, но единственный вызывающий — привилегированный content-filter control socket, из sandbox недосягаем |
| `36_hid_fastpath_user_client.md` | `IOServiceOpen(IOHIDEventService, type=2)` из sandbox создаёт `IOHIDEventServiceFastPathUserClient` (23F84), таблица методов получена: `open`/`close`/`copyEvent`; **`open` проходит без entitlement** на свободных `AppleSPUHIDDriver` (ранний вывод «закрыт» снят — вызовы отбивал диспетчер из-за неверного счётчика выходных скаляров). На 24B156 `type=2` → `NotPrivileged`. `IOHIDEventServiceUserClient` (CVE-2026-43739/43816) закрыт. Chained-fixup расшифрован (`kcptr.py`, `kstarts.py`) |
| `37_cve_43689_site_procargs.md` | CVE-2026-43689 (Kernel, permissions → root, fix 26.7) **не локализован**: единственное изменение `sysctl_procargsx` 23F84→23G83 — буфер синтетического ответа перенесён со стека в кучу; «новая привилегия 2053» из первой версии — ошибка (это размер `kalloc`). GitHub-след: write-up нет, два репозитория с номером — фейки. `find_priv.py` ищет не `priv_check_cred` |
| `38_cfil_reachability.md` | `connect()` к `com.apple.content-filter` из sandbox → EPERM (`CTL_FLAG_PRIVILEGED` → `kauth_cred_issuser`); свой content filter поставить нельзя, `net.cfil.active_count` из sandbox не читается. UAF `necp_client_qualify_flow` (27): окно есть, триггер из sandbox не показан — нужен чужой фильтр + policy; 37 занят (`37_cve_43689_site_procargs.md`) |
| `39_nstat_query_request.md` | `nstat_client_handle_query_request` досягаем из sandbox (поправка к 35: `QUERY_SRC` → SUCCESS, закрыты только `ADD*`), но тело запроса используется лишь как `srcref` и `context`; изменение 26.6.1 — `csel` двух счётчиков статистики, не memory-bug |
| `40_astra_worker_procargs_recheck.md` | Astra (gpt-6.2-astra) как worker вместо Claude: слепой diff `sysctl_procargsx` 23F84↔23G83 подтвердил заметку 37; находка `tbz`→`cbz` снята; Opus 5.5 / Fable 5.2 — HTTP 400 `claude refusal (cyber)`. §5: GLM-5.4 на том же листинге не отвечает ни за шлюзом (504, лимит `zai` 120 с), ни напрямую (47 999 reasoning tokens, пустой ответ; принимает iOS за Linux); только planner |
| `41_kext_wide_diff_iosurface_pool.md` | Дифф всех 249 кекстов 23F84→23G83 (таблица: измен./новые/удал. по каждому). Кандидаты: IOSurface `IOSurfaceMemoryPool`/`taskCanUsePool` (третий вызов проверки появился в 23G83; уязвимость **не доказана**, приоритет понижен) и **AppleMatch** — regex-движок Sandbox.kext: в 23F84 ёмкость grow-буфера читается из поля `+0x60`, которое никто не пишет, в 23G83 вычисляется и капается `0xffff`; досягаемость из приложения не проверена. sandbox/AMFI — мелкие правки. Не запускалось. |
| `42_applematch_sandbox_reachability.md` | Досягаемость кандидата AppleMatch (41 §7): regex в компилятор попадает только из sandbox-профиля. Вход — MAC-хук `mpo_cred_label_update_execve` (опознан по таблице `mac_policy_ops`), на этом пути свой профиль принимается только с `com.apple.private.sandbox.profile` (`:embedded`); spawn-атрибут `posix_spawn` в компилятор не идёт. Источник буфера у 5 других вызывающих компилятора (`0x9bc0f9c`, `0x9bd54bc`, `0x9bdb610`, `0x9bdc83c`) не прослежен — до этого «закрыто» условно. Не запускалось. |
| `43_dispatch_tables_map_and_iosurface_reach.md` | Карта таблиц `IOExternalMethodDispatch2022` на 23F84 (`kdisp.py`): 18 образов, 341 селектор; `IOSurfaceRootUserClient` открыт из sandbox и вызывает методы (сел. 13 → 0); FastPath `open` проходит без entitlement на свободных `AppleSPUHIDDriver`; в `copyEvent` видна граница `n-4` без защиты от `n<4` (не доказано) |
| `ios26-kernel-research/*.md` | выгрузка `HiItsMe2117/ios26-kernel-research` (чужое исследование, на 26.6.1/A18) |
| `out_13.txt`, `out_17.txt` | сырой вывод пробника wqprobe с устройств |
| `tools/` | `patchfind.py`, `disasm.py` (бывший `dis.py`), `findxref.py`, `kdiff.py`, `fdump.py`, `funclist.py` (строковый якорь → xref → функция → нормализованный дифф двух kernelcache; нужен capstone), `vrpc.py`, `wqprobe.m`, `wqprobe_escape.m` + `worse_query.m/.h`, `pathleak.m/.h` (GPLv3, forcequitOS), `kprobe.m`, `aksprobe.m`, `iosvc.m` |

Рабочие каталоги на этом Mac (во `/tmp`, пропадут после перезагрузки): `/tmp/jbresearch/` — kernelcache (`ipsw/x13`, `ipsw/x17`), собранные приложения (`dd/`, `dd-kprobe/`), приглашения сабтредов (`research/*.md` без `_result`). Скопировано только то, что перечислено выше.

## Главный вывод

Метод vphone воспроизводится на железе ровно до границы BootROM: patchfinder, таблица операций sandbox и allow-stub переносимы, а загрузка пропатченного ядра — нет. На железе остаётся один путь: эксплойт ядра под точный билд и применение патчей в памяти. Публичного эксплойта под 23F84 и 24B156 на дату заметки нет.
