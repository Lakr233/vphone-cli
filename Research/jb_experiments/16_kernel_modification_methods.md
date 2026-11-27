# 16. Способы выполнения модифицированного кода ядра на A15 / A19 без BootROM-эксплойта

Дата: 2026-11-26. Объекты: iPhone 13 (A15, 26.5.2 / 23F84) и iPhone 17 Pro Max (A19, 27.2.1 / 24B156). Оба в developer mode, BootROM-эксплойта нет.

Обзор по открытым источникам. Ничего не устанавливалось, не собиралось, к устройствам не подключалось. Пределы методов взяты из кода (снимки в `tools/upstream_snapshots/`), а не из README.

**Ф** — проверено по первоисточнику (файл и строка). **Г** — гипотеза или вывод, первоисточником не подтверждён.

Смежное не дублируется:

| Тема | Где |
|---|---|
| Публичные BootROM/kernel-эксплойты и применимость к 23F84/24B156 (CVE, кандидаты) | `04_public_exploit_landscape.md` |
| Непереносимость цепочки 26.2 на наши билды | `12_chain_26_2_port.md` |
| Почему нельзя загрузить свой kernelcache, offline-патч `task_for_pid` | `README.md`, `01_patchfinder_and_first_patch.md` |
| Слайд KASLR и чтение памяти ядра через kcall на Basil, гейты `task_for_pid` | `13_kaslr_slide_and_kread.md` (для гейтов `task_for_pid` на Basil и железе — `14_basil_task_for_pid_live.md`, упомянут в README; на момент написания файла в каталоге не было) |

## Итог

| Способ | Что требуется | A15 / 26.5.2 (23F84) | A19 / 27.2.1 (24B156) |
|---|---|---|---|
| Свой kernelcache или kext через Recovery / DFU / iBoot | подпись Apple + APTicket под ECID и nonce | Нет | Нет |
| BootROM-эксплойт → pongoOS → KPF → патченный XNU | уязвимость Boot ROM (checkm8 — только ≤ A11) | Нет | Нет |
| KPF внутри restore-ramdisk без BootROM | неподписанный код в ramdisk | Нет | Нет |
| Software-jailbreak: kernel exploit + PAC + PPL/SPTM bypass | эксплойты под точный билд | Нет: kernel ≤ 26.0.1, SPTM bypass на A15 ≤ 17.3.1 | Нет |
| SHSH re-restore на уязвимую версию | blob + generator через jailbreak + совместимый SEP | Нет | Нет |
| Apple Security Research Device | специальный fused девайс | Нет | Нет |
| Developer Mode, devicectl, Xcode | — | не путь (userland) | не путь |

Вывод: единственный потенциальный путь на наших устройствах — software kernel exploit + SPTM-байпас под точный билд. Публичных для 23F84 и 24B156 нет; кандидаты по 23F84 — в файле 04.

## 1. Boot chain

**Ф.** Boot ROM → iBoot → kernelcache; отдельный LLB есть только на A9 и старше. Каждая стадия подписана Apple, корень доверия — Apple Root CA в Boot ROM. Ошибка загрузки → DFU (Boot ROM) или Recovery (iBoot). Boot Progress Register выставляет Boot ROM (DFU, A12+) или iBoot (Recovery, A10+). Источник: Apple Platform Security (APS), август 2026, «Boot process for iPad and iPhone devices», стр. 30.

**Ф.** Персонализация: сервер Apple подписывает measurement образа + ECID устройства + anti-replay-значение; при загрузке проверяется подпись Apple и совпадение measurement + ECID с тем, что покрыто подписью (APTicket). APS, стр. 55. Отсюда же: свой kernelcache не подписать — ключ верификации зашит в Boot ROM, ключ подписи у Apple. В APS не раскрыта структура Image4/Manifest; имя «APTicket» в тексте APS не используется, это термин из инструментов (futurerestore, `-t/--apticket`).

**Ф.** На A15+ SPTM и TXM — отдельные Mach-O внутри kernelcache: XPF загружает их отдельно от ядра и для каждого строит патчфайндер (`XPF_xpf.c:637-666`).

**Ф.** SEP: Secure Enclave выполняет собственную secure boot для sepOS и ограничивает доступ к данным пользователя по Boot Progress Register (APS, стр. 30). SEP в цепочке проверки kernelcache не участвует — он проверяет только свой sepOS.

**Ф.** Developer Mode — userland-переключатель: Dopamine включает его записью `1` в переменную ядра или TXM (`DOJailbreaker.m`, `ensureDevModeEnabled`). Наоборот это не работает: developer mode ничего на уровне ядра не открывает.

**Г.** Как именно iBoot проверяет SPTM/TXM на этапе загрузки — в открытых источниках полноценно не описано, по исходникам не верифицировано.

### Проекты: на чём основаны

| Проект | Опора | Чипы и версии | Источник |
|---|---|---|---|
| checkra1n | BootROM checkm8 (DFU) | A7–A11, T2 | `04_public_exploit_landscape.md` §«Загрузочная цепочка» |
| palera1n | BootROM checkm8 → pongoOS → KPF → XNU | A8–A11, T2; iOS 15+ | `palera1n_README.md` |
| Dopamine 3.x | software: kernel exploit × PAC bypass × PPL/SPTM bypass | arm64e A12–A17 и arm64; iOS 15–18.7.1; 26.0–26.0.1 только A12/A13 | `Dopamine_README.md`, `dp/*.plist` |
| RootHide Bootstrap | software, тот же класс | iOS 15.0–17.0, A8–A17 Pro, M1+M2 | `rh/Bootstrap_README.md` |
| palera1n-roothide | software на arm64 (A8–A11) без DFU | iOS 15–18 по описанию репозитория | <https://github.com/roothide/Palera1n-roothide> |

Два класса: для A8–A11 есть BootROM-эксплойт, и ядро правят до загрузки (KPF); для A12–A17 BootROM-эксплойта нет, и ядро правят после загрузки из userland (exploit + bypass). A15 и A19 относятся ко второму классу.

## 2. kpf (kernel patchfinder)

**Ф.** Где применяется. В palera1n KPF — модуль pongoOS (`checkra1n-kpf-pongo`). После checkm8 palera1n отправляет его командой `modload`, затем ramdisk и overlay, после чего стартует XNU (`p1/pongo_helper.c:66-107`). То есть KPF модифицирует XNU в памяти до его выполнения. Это не «ramdisk при загрузке через DFU», а pongoOS, который запускается из pwned DFU; ramdisk в palera1n — это корневая ФС jailbreak, а не носитель KPF.

**Ф.** Что патчит (`pongo_kpf_main.c`, патчсеты `xnu_pf_maskmatch` / `xnu_pf_ptr_to_data`, строки 149–1666):

| Область | Патчи |
|---|---|
| AMFI | `amfi_execve_tail`, `amfi_sha1`, `amfi_mac_syscall` (+ alt), dyld hook (`kpf_dyld_callback`), `conversion_patch`, `convert_port_to_map` |
| Sandbox kext | `mach_traps`, `sb_ops` → «Seatbelt sandbox policy» |
| VM | `vm_map_protect` (+2), `vm_fault_enter` (варианты под iOS 13, 14.0, 14.2+) |
| VFS / APFS | `dounmount_patch`, `vnode_lookup`, `vnode_getattr`, `vnode_getpath`, `ret0_gadget`, `apfs_patch_mount`, `apfs_patch_rename`, privcheck / AES |
| NVRAM, прочее | `nvram_unlock` (boot-nonce), `find_shellcode_area`, смещение `p_flags` |

**Ф.** Почему неприменимо на A15+ без BootROM: KPF исполняется только внутри pongoOS, а pongoOS запускается только через checkm8. Для A15/A19 публичного BootROM-эксплойта нет (`04_public_exploit_landscape.md`).

**Ф.** Как это делается на A12–A17 вместо KPF: XPF в Dopamine ищет смещения в ядре, SPTM и TXM по файлу kernelcache с диска, причём ядро уже загружено (`XPF_xpf.c`, `DOJailbreaker.m`, `gatherSystemInformation`). Затем kernel exploit даёт kread/kwrite, затем PPL/SPTM bypass даёт physwrite (`DOJailbreaker.m`, `doExploitation`; Titan: `gPrimitives.physwritebuf = titan_physwritebuf`, `dp/Titan_Titan.m`).

**Ф.** XPF — это patchfinding, не bypass: он находит адреса, но ничего не патчит. В `XPF_xpf.c:23-56` есть диапазоны SPTM: `24.3.0` и ниже, `24.4.0`–`27.0.0`, и `27.0.0+`. То есть находить смещения в SPTM iOS 27 XPF умеет, но это не даёт способа обойти SPTM.

## 3. Recovery / restore ramdisk и SHSH

**Ф.** Recovery и DFU на A15+ входят аппаратно (кнопками), но всё, что в них загружается, подписано Apple и персонализировано (§1). Произвольный ramdisk через Recovery/DFU требует либо уязвимости Boot ROM (checkm8: pwned DFU, в futurerestore это `--use-pwndfu` и `--just-boot`), либо подписанного Apple ramdisk с валидным APTicket. Источники: APS стр. 30; `futurerestore_README.md`, таблица опций и разделы 1–3.

**Ф.** SHSH saving — сохранение подписи (blob = APTicket для образа + ECID + generator) с сервера Apple, пока эта версия ещё подписывается. «Re-restore» (Prometheus) — установка сохранённой версии позже. Для него нужно: (а) blob с generator; (б) возможность записать generator в NVRAM (`com.apple.System.boot-nonce`), то есть jailbreak с nonce setter; (в) совместимый подписанный SEP и baseband. Для A7–A8X был вариант с коллизией ApNonce в DFU без jailbreak. Источник: `futurerestore_README.md`, разделы 1–3.

**Ф.** На A15+ generator ставится только при уже работающем jailbreak: NonceSetX в описании — «set the generator on Dopamine (iOS 15-18, 26)» (<https://github.com/ichitaso/NonceSetX>).

**Г.** Вывод для наших устройств: на 23F84 и 24B156 jailbreak отсутствует, значит generator не поставить, и blob бесполезен. Плюс нужно, чтобы целевая версия принимала текущий подписанный SEP. Модель генерации nonce на A15+ я отдельно не проверял.

**Ф.** Про метод «collision» в DFU из README futurerestore: он описан только для A7, A8, A8X; про A12+ в README ничего нет.

## 4. SPTM / PPL

**Ф.** Что это (APS, разделы «Page Protection Layer» и «Secure Page Table Monitor and Trusted Execution Monitor», таблица на стр. 58):

| Механизм | Что делает | Где |
|---|---|---|
| KIP | после инициализации ядра контроллер памяти запрещает запись в область, куда iBoot загрузил ядро и kext | все A |
| PPL | на базе KIP и Fast Permission Restrictions только PPL может менять защищённые страницы: код userland и page tables | A12–A14 (заменён SPTM на A15+/M2+) |
| SPTM | уровень привилегий выше ядра; защищает page tables пользовательских процессов и ядра, «не полагается на доверие к ядру даже при ранней загрузке» | A15+, M2+ |
| TXM | уровень ниже SPTM, применяет политики исполнения кода; компрометация TXM не даёт автоматом обход SPTM | A15+, M2+ |

**Г.** Граница «PPL на A12–A14»: в APS сказано только, что SPTM заменяет PPL на A15+; с какого чипа начинается сам PPL, в прочитанных разделах не указано. Нижняя граница A12 — из общих знаний, не из источника.

**Ф.** Что публично есть по обходу (по `dp/*.plist`, тип `DPExploitType`, и `DOJailbreaker.m`):

| Bypass | Тип в plist | Устройства | Версии | Файл |
|---|---|---|---|---|
| Titan | PPL | A14–A17 | 16.1–17.3.1 | `dp/Titan.plist`, `dp/Titan_Titan.m` |
| momentarius | PPL | A12, A13 | 15.0–26.0.1 | `dp/momentarius.plist` |
| dmaFail | PPL | кроме A15, A16 | 15.0–16.5.1 | `dp/dmaFail.plist` |
| badRecovery | PAC | все | 15.0–15.4.1 | `dp/badRecovery.plist` |

Тип «PPL» в plist — общее имя для bypass; на A15+ это фактически SPTM bypass (`DOJailbreaker.m`: «SPTM bypass is required but we did not find any»). Механизм Titan в открытом коде — exploit через IOGPU/AGX (`Titan_kernel_patchfinder.c` ищет `com.apple.iokit.IOGPUFamily` и `com.apple.AGXG`), даёт physwrite. Как именно он обходит SPTM, в снимке кода не разобрано — **не исследовано**.

**Ф.** Для A15 значит: SPTM bypass есть только Titan, и он до 17.3.1. Для 26.5.2 bypass нет, даже если появится kernel exploit.

### Что Dopamine делает с ядром после bypass

**Ф.** По `DOJailbreaker.m` и `DOBootstrapper.m`: получение uid/gid 0 записью в `proc`/`ucred`, снятие sandbox через `mac_label_set`, выставление `CS_PLATFORM_BINARY`, загрузка trustcache через `trustcache_file_upload_with_uuid`, включение developer mode, построение physrw (`libjailbreak_physrw_pte_init`), инъекция `launchdhook.dylib` в launchd. Это изменения **данных** ядра и page tables; страницы кода XNU/kext Dopamine не перезаписывает.

**Ф.** Про патчинг кода ядра на SPTM-устройствах в снимках кода Dopamine ничего нет. KIP при этом остаётся: контроллер памяти запрещает запись в область кода ядра (APS, «Kernel Integrity Protection»).

### Публикации: что подтверждено, что нет

| Источник | Статус |
|---|---|
| Trellix, «Technical Deep Dive: arm64e Page Tables and PPL» (2023) | **Г** — URL `trellix.com/blogs/research/technical-deep-dive-arm64e-page-tables-ppl/` у меня не открылся (403/timeout), содержание и охват чипов не проверены |
| Project Zero, «Security of iOS» (2020) | **Г** — индекс октября 2020 открылся, нужной статьи в нём нет, содержание не проверено |
| Linus Henze / Fugu15 | **Ф** — на GitHub у LinusHenze только Fugu (checkm8) и Fugu14; Fugu15 — <https://github.com/opa334/Fugu15> (iOS 15.0–15.4.1). PAC bypass из Fugu15 в Dopamine — `badRecovery`, 15.0–15.4.1 |
| ACL, «SPTM bypass», Mescaline | **не найдено** — по GitHub-поиску репозиториев и доступным страницам подтвердить существование, авторов и охват чипов не удалось |
| `Hetyey/Coruna` — PPL/SPTM bypass на Objective-C | упомянут в `04_public_exploit_landscape.md`; для какой версии — не читал, **Г** |

## 5. Что осталось гипотезой и что не исследовано

**Гипотезы**

- Проверка SPTM/TXM в iBoot при загрузке kernelcache.
- Статья Trellix 2023 и её охват чипов.
- Нижняя граница PPL (A12): в APS явно не указана.
- Модель nonce на A15+ вне работающего jailbreak.

**Не исследовано**

- Инъекция кода в kernel-память вне KIP через kcall/physrw на SPTM-устройствах: какие области (kalloc, data, exec-страницы) доступны для записи после bypass и можно ли там исполнять код. По Dopamine видно только kcall и изменение данных; на Basil это отчасти проверено (`13_kaslr_slide_and_kread.md`: вызов функции ядра по слайду), но Basil — VM с патчами vphone, не SPTM-железо.
- Механизм Titan: как именно physwrite через IOGPU/AGX обходит SPTM. В снимке — только patchfinder.
- `Hetyey/Coruna` и `mkz-lena/melatonin` (iOS 27, WIP): версии и применимость к 24B156.
- Для 27.2.1: публичных kernel exploit под A19 нет вовсе; единственный кандидат по 27.x — CVE-2026-112705 (AppleAVE2 OOB write), статус на 24B156 не проверен (файл 04).

## Источники и снимки

| Что | Коммит | Куда |
|---|---|---|
| [Apple Platform Security, август 2026 (PDF)](https://help.apple.com/pdf/security/en_US/apple-platform-security-guide.pdf): Boot process, personalization, KIP, PPL, SPTM/TXM, Research Device | — | не сохранялся; страницы 30, 55, 58, 76–77, 84 |
| [opa334/Dopamine](https://github.com/opa334/Dopamine) ветка 3.x: `DOJailbreaker.m`, `DOBootstrapper.m`, `DOExploitManager.m`, `Exploits/*/Info.plist`, `Exploits/Titan/exploit/kernel_patchfinder.c` | `5b1d2c1c3bf5` (2026-11-03) | `tools/upstream_snapshots/*.m`, `dp/` |
| [opa334/XPF](https://github.com/opa334/XPF): `src/xpf.c`, `sptm_txm.c`, `ppl.c`, `non_ppl.c`, `bad_recovery.c` | `9e12b8faa744` (2026-08-11) | `tools/upstream_snapshots/XPF_*.c` |
| [checkra1n/PongoOS](https://github.com/checkra1n/PongoOS): `checkra1n/kpf/main.c` | `4c9b75416292` (2021-11-04) | `tools/upstream_snapshots/pongo_kpf_main.c` |
| [palera1n/palera1n](https://github.com/palera1n/palera1n): README, `src/pongo_helper.c`, `src/main.c` | `3ba32c40dbd9` (2026-07-27) | `tools/upstream_snapshots/palera1n_README.md`, `p1/` |
| [tihmstar/futurerestore](https://github.com/tihmstar/futurerestore): README | `ee81b6550331` (2026-11-17) | `tools/upstream_snapshots/futurerestore_README.md` |
| [roothide/Bootstrap](https://github.com/roothide/Bootstrap): README | `053072440b88` (2026-10-12) | `tools/upstream_snapshots/rh/Bootstrap_README.md` |
| [opa334/kfd](https://github.com/opa334/kfd) (libkfd: PUAF → KRKW), [opa334/Fugu15](https://github.com/opa334/Fugu15) | — | не сохранялись |

`tools/upstream_snapshots/` — только цитируемые файлы, чужой код с лицензиями исходных репозиториев (для чтения, не для сборки). Скриптов у этой заметки нет: всё собиралось `curl` к GitHub API и `pdftotext`.

