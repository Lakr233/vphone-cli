# V1 — Обходы защит в vphone-cli: анализ открытого кода

Репозиторий: `/Users/i_strelov/Projects/vphone/vphone-cli` (пути ниже относительные, если не начинаются с `/`).
Метод: только чтение исходников и `Research/*.md`. На устройствах и VM ничего не запускалось. Все «проверено / boots / VERIFIED» ниже — заявления авторов в их заметках, а не результат моего запуска.

## Главный вывод

В репозитории **нет ни одного рантайм-эксплойта ядра и нет кода, использующего уязвимость**. Защита обходится иначе:

1. Хост **оффлайн правит байты** в образах загрузочной цепочки (LLB/iBSS/iBEC, AVPBooter), в SPTM, TXM и в kernelcache, затем прошивает их в VM как «кастомную прошивку» (CFW).
2. Гость загружает уже **заранее пропатченные** ядро и TXM. В рантайме их никто не трогает: SPTM/PPL не «обходятся», а просто не мешают, потому что нужные проверки выключены на диске.
3. Внутри гостя работает **только userspace**: dylib, вставляемые хуком launchd через `DYLD_INSERT_LIBRARIES`, и рантайм-патчинг чужого userland-кода через `vm_protect`/`vm_write` на mach task. Это получается лишь потому, что ядро заранее ослаблено (task_for_pid, port→map, vm_map_protect, AMFI).

Роль эксплойта выполняет хост-патчер: это не «эксплойт → kread/kwrite → патч ядра в памяти», а платформа с заранее ослабленным ядром и мониторами.

---

## 1. Что делают `kernel-exp-*`, `system-*-exp-*`, `txm-*` в PatchPlan

### 1.1. Как устроен PatchPlan

Каждый пункт — `VPhonePatchDeclaration` в манифесте набора (`VPhoneExecutable/VPhoneCommand/FirmwarePatcher/PatchSets/*.swift`). Префикс — это компонент образа. Подсчёт по `identifier:` в манифестах:

| Префикс | Объявлено | Куда пишутся байты |
|---|---|---|
| `kernel-boot-*` / `kernel-cfw-*` / `kernel-exp-*` | 44 / 8 / 6 | kernelcache |
| `txm-boot-*` / `txm-cfw-*` / `txm-exp-*` | 4 / 3 / 1 | бинарник TXM |
| `llb-*` / `ibss-*` / `ibec-*` / `avpbooter-boot-*` | 7 / 3 / 4 / 1 | загрузчики |
| `dyld-*`, `system-*`, `preboot-*`, `devicetree-*` | — | dyld shared cache, отдельные Mach-O в rootfs, Preboot, DeviceTree |

`system-*` и `preboot-*` — это **не ядро**, а патчи файлов гостя (rootfs, Preboot), которые ставятся через SSH в рамдиск или при установке CFW. Реализации: `PatchSets/FirmwareGuestSystemPatchSet.swift`, `FirmwareGuestIdentityPatchSet.swift`, `FirmwarePatchSetCatalog.swift:185` (`dyld-exp-mis_trust_auth` выключен, потому что его работу делает userspace-хук).

**Все они — оффлайн-патчи образа на диске.** Рантайм-кода среди них нет. Гостевые dylib (раздел 2) сами по себе не пункты PatchPlan — их ставит `cfw install`.

Реализации патчеров (все наследуют `BufferedPatcher` и пишут в буфер образа):

| Компонент | Реализация |
|---|---|
| kernelcache | `FirmwarePatcher/Kernel/` — `KernelPatcher`, `KernelCustomFirmwarePatcher`, `KernelExperimentalPatcher`, `CustomFirmwarePatches/{Drivers,Frida,Process,Sandbox,Memory,CodeSigning,Keystore}/*.swift` |
| TXM | `FirmwarePatcher/TXM/TXMPatcher.swift`, `TXMDevPatcher.swift`, `TXMExecutableRemap.swift`, `TXMMissingProfile.swift` |
| SPTM | `FirmwarePatcher/SPTM/SPTMSecondaryCPUPatcher.swift` |
| dyld shared cache | `FirmwarePatcher/DyldSharedCache/Patchers/*.swift` |

### 1.2. Суффиксы `-boot-`, `-cfw-`, `-exp-`

- `-boot-` — нужен, чтобы CFW вообще загрузился (заявлен `bootEssential: true`).
- `-cfw-` — функциональность джейлбрейка (task_for_pid, порты, syscallmask).
- `-exp-` — экспериментальное или необязательное. Часть таких патчей блокируется в пресетах, часть включена.

Два уточнения по пресетам, чтобы не сделать ложного вывода из имени:

- В `standard.plist` (`VPhoneExecutable/VPhoneVirtualization/Resources/patches_presets/standard.plist`) блок `Selection` имеет `Kind = Block` — это **список блокировки**, а не список включённых патчей.
- `kernel-exp-*` в пресете `standard` **выключены**: строки 91–99 `standard.plist` ставят все пять `kernel-exp-frida_*`, `kernel-exp-hv_vmm` и родственные `dyld-exp-hv_vmm` в тот же список блокировки. Это же множество в коде — `manualOnlyPatches` (`FirmwarePatchSetCatalog.swift:67`, вид `selection: .block(manualOnlyPatches)` на строке 241); комментарий на строке 84: «experimental takes every manual patch». Набор `com.vphone.patchset.kernel.frida` заявлен в пресетах, но его патчи включены только в `experimental`.

`kernel-exp-hv_vmm` — единственный пункт набора «Hypervisor Concealment» (`PatchSets/FirmwareKernelHypervisorPatchSet.swift:35`). Он выключен по умолчанию: после restore 26.4 он ломает загрузку (bluetoothd кэширует «не в VM», его transport-синглтон остаётся NULL, crash-loop → locationd → миграция → чёрный экран; `FirmwareKernelHypervisorPatchSet.swift:8-16`).

### 1.3. Что делает каждый `kernel-exp-*`

| Патч | Что делает |
|---|---|
| `kernel-exp-hv_vmm` | Две части. **Часть A**: в sysctl OID ядра байт `h`→`X`, т.е. `kern.hv_vmm_present` → `kern.Xv_vmm_present` (`FirmwarePatcher/Kernel/ExperimentalPatches/KernelExperimentalPatchHvVmmRename.swift (строки 10-26)`). При обычном запросе `sysctlbyname("kern.hv_vmm_present")` возвращается ENOENT, и проверяющий кэширует «не в VM». **Часть B**: мангл тех же cstring у внутренних вызовов ядра (AMFI и др.), чтобы они получали правдивое значение 1. |
| `kernel-exp-frida_tpro_off`, `_syscall_filter_off`, `_thread_set_state_entitlement_flag`, `_vm_map_delete_immutable_code`, `_fork_inherit_invalid_code` | Ослабления ядра под Frida (реализации в `FirmwarePatcher/Kernel/CustomFirmwarePatches/Frida/*.swift`; описания в `Research/KernelCustomFirmwarePatches/patch_{tpro_off,syscall_filter_off,thread_set_state,vm_map_delete_immutable_code,fork_inherit_invalid_code}.md`). По заметкам: `tpro_off` — снимает проблему libdyld с TPRO-регионами при spawn-хендшейке Frida; `syscall_filter_off` — отключает per-process syscall-фильтры Sandbox.kext (bitmask в dispatch-путях BSD/Mach/MIG); `thread_set_state` — снимает требование entitlement `com.apple.private.thread-set-state` в `thread_set_state_from_user`; `vm_map_delete_immutable_code` — разрешает откатывать permanent-entries с X-защитой при повторной инструментации (Frida Stalker); `fork_inherit_invalid_code` — при fork ребёнок наследует право исполнять переписанные страницы, но только если родитель имеет `com.apple.private.cs.debugger`. |

Патчи ядра под гипервизор (`kernel-exp-hv_vmm` и DSC-патчи) отвечают за **идентификацию гипервизора** из задания: репозиторий не обнаруживает гипервизор, а **скрывает** его от гостя. В `SPTMSecondaryCPUPatcher.swift` гипервизор наоборот распознаётся по поведению: vCPU отдаёт `MIDR_EL1 = 0x610f0000`, и SPTM падает на нём (`SPTMSecondaryCPUPatcher.swift:22-28`).

### 1.4. `system-*-exp-*` и `txm-*`

- `system-*`/`preboot-*`/`devicetree-*` — оффлайн-патчи файлов гостя (пути и значения в `FirmwareGuestSystemPatchSet.swift` и в Research-заметках под каждый патч), ставятся при restore/`cfw install`, рантайм-кода не содержат.
- `txm-*` — оффлайн-патчи бинарника TXM, подробно в разделе 4.

---

## 2. VPhoneGuestComponents: состав, доставка, привилегии

### 2.1. Состав

Каталог `VPhoneGuestComponents/` — около 30 подкаталогов. `make package` кросс-компилирует их iPhoneOS SDK (HomePod-адаптер — tvOS SDK), на выходе подписанные arm64e dylib (`VPhoneGuestComponents/README.md`, `Makefile`).

| Группа | Компоненты |
|---|---|
| Спавн-хуки и инъекция | `LaunchHook/` (`launchdhook-vphone.dylib`), `SystemHook/` (`SystemHook-vphone.dylib`, GPU/IOSurface-транспорт: `VPhoneIOS18GPU.c`, `VPhoneIOS16Surface.c`) |
| Обход проверки подписи при установке | `MISFix/` (`libmisfix.dylib` + plist-фильтр), `HomePodInstallPersona/` |
| Рантайм-патчинг чужого кода | `VCamCaptured/` (`VCamCodePatch.m`), `FlutterRemapFix/` |
| Подмена данных/железа | `CamFix`, `HapticsFix`, `BatteryHealthFix`, `DeviceHubFix`, `DeviceName`, `PrefsFix`, `SignInFix`, `Gyroscope`, `Accelerometer`, `Attitude`, `Hinge`, `FoldGuard`, `FoldDisplay`, `IOS16Desktop`, `IOS16Migration`, `IOS17Desktop`, `VirtIOSound`, `VisionOSIPC`, `HomePod*`, `TVSetupFocus`, `GraphicLoader`, `CryptexStagingFix` |

**Явного kernel-кода (kext, KPI, kmod) в каталоге нет.** Поиск `OSObject|IOService|kmod_start|KMOD` по `*.c/*.cpp/*.m/*.h` даёт три файла — и все три userspace-клиенты IOKit (например `BatteryHealthFix/libbatteryhealthfix.c:338` — `IOServiceGetMatchingService(... IOServiceMatching("AppleBatteryAuth"))`). Поиск `kext|kextload|kmutil` не даёт ни одного файла. Гостевые kext в госте появляются иначе: их **встраивают в kernelcache на хосте** (`kernel-boot-vresearch101_kext_mix`, `PatchSets/FirmwareResearchBoardPatchSet.swift:27,41-47`).

### 2.2. Как попадают в гостя

1. `cfw install` кладёт `launchdhook-vphone.dylib`, `SystemHook-vphone.dylib` и камерные хуки в `/usr/lib`; обновление окружения от vphoned заменяет их в работающем госте (`VPhoneGuestComponents/README.md`).
2. Хук launchd модифицирует каждый спавн (`posix_spawn`/`posix_spawnp`: `LaunchHook/launchdhook-vphone.c:80,132,141`) и вставляет `SystemHook-vphone.dylib` через `DYLD_INSERT_LIBRARIES`. Внутри `xpcproxy` SystemHook переносит себя в конечный исполняемый файл, в процессах приложений и bootstrap — в детей через `posix_spawn`/`execve` (README).
3. SystemHook подгружает остальные dylib по процессам: `libcamfix.dylib` в приложения с AVFoundation, `libvcamcaptured.dylib` в `/usr/libexec/cameracaptured`, `libhapticsfix.dylib` в SpringBoard, `libbatteryhealthfix.dylib` и `libdevicename.dylib` в Settings/configd/lockdownd. `libmisfix.dylib` вставляется только в installd, misagent, SpringBoard, lockdownd, remoted (манифест `PatchSets/FirmwareGuestSystemPatchSet.swift`, около строк 990–1030). Логи инъекций пишутся в `/var/mobile/Library/Caches/` (`launchdhook-vphone.c:22-29`).
4. Если установлен бутстрап (ElleKit/roothide), SystemHook грузит `usr/lib/TweakLoader.dylib` — обычный механизм твитков. Корень roothide: `/private/var/containers/Bundle/Application/.jbroot-000114514191980C` (`launchdhook-vphone.c:18`).

### 2.3. С какими привилегиями работают

**С привилегиями того процесса, в который их вставили**: launchd (root), SpringBoard, installd, lockdownd, configd, приложения. Отдельного демона с root или kernel-кода нет. Исключение по ролям: `homepodsetup/vphone-homepod-setup` — helper-программа с launchd-плистом.

### 2.4. Что из этого похоже на обход защиты

| Механизм | Файл | Что делает | Почему срабатывает |
|---|---|---|---|
| dylib-инъекция | `LaunchHook/launchdhook-vphone.c`, `SystemHook/` | `DYLD_INSERT_LIBRARIES` в каждый спавн, перенос в детей | Ядро пропатчено: AMFI/load_dylinker, `dyld-exp-mis_trust_auth` и др. |
| Обход проверки подписи в MIS | `MISFix/MISFixSignature.c:12-30`, `MISFix/MISFixInstallPolicy.c:182-206` | Swizzle `-[MICodeSigningVerifier _validateSignatureAndCopyInfoForURL:withOptions:error:]`, в опции добавляется `AllowAdHocSigning`; свойство `allowAdhocSigning` → YES | installd/misagent принимают ad-hoc и чужие подписи |
| Рантайм-патчинг кода в shared cache | `VCamCaptured/Image/VCamCodePatch.m:29-36, 83-156` | stop-the-world (`task_threads` + `thread_suspend`), `vm_protect(VM_PROT_COPY)`, запись, `vm_protect` → RX, flush icache | Ядро разрешает (vm_map_protect, AMFI) |
| Обход EXC_ARM64PAC/«X1»-падений | `LaunchHook/VPhoneX1Exception.c`, `VPhoneX1Spawn.c` | Обработчик исключений, стоп/резюм потоков, `vm_protect` RW → `vm_write` → `vm_protect` RX (`:67-77, 144-150`) | Патится код чужого процесса через mach task API; нужен `task_for_pid`/port→map |
| Mach-порты / IOUserClient-транспорт | `Shared/VPhoneMachPortsCompat.c:7-13`, `SystemHook/VPhoneIOS16Surface.c:13-50` | ABI-компат iOS 16 (`mach_ports_register/lookup` под 3 inline-дескриптора) и обёртки `IOConnectCallStructMethod`/`IOConnectCallMethod` | Это compat, а не обход защиты |
| IOUserClient | `SystemHook/VPhoneIOS18GPU.c`, `VirtIOSound/VPVirtIOSoundPlugin.m:809-1818` | Клиенты user client: `IOServiceOpen`, scalar/struct/async-методы; IOS18GPU транслирует селекторы GPU-клиента | Патчи `kernel-boot-iouc_macf_gate`, `kernel-boot-iouc_sandbox_gate`, paravirt-user-clients |

Всё это — **userspace-механизмы**, а не эксплойты: ни один из них не получает привилегий сам, они опираются на заранее пропатченное ядро.

### 2.5. Kcall10 — единственный kernel-примитив, и он не используется

`kernel-boot-kcall10` (`Kernel/CustomFirmwarePatches/Process/KernelCustomFirmwarePatchKcall10.swift`) заменяет `sysent[439]` (`SYS_kas_info`) на cave: userland передаёт указатель на функцию ядра и 7 аргументов (`uap[0]` — функция, `uap[1..7]` — аргументы). Это **произвольный вызов функций ядра из userland**, из него собирается kread/kwrite (`copyin`/`copyout`).

- Патч **boot-essential** и включён (`FirmwareKernelCustomFirmwarePatchSet.swift:228-232`).
- **Потребителя в гостевом коде нет**: поиск `kas_info|kcall10|kcall` по `VPhoneGuestComponents`, `VPhoneDaemon`, `VPhoneKit`, `VPhoneExecutable/VPhoneVirtualization` даёт ноль совпадений вне тестов. Потребитель не найден и во всём репозитории вне `Research/` и самого патчера.
- В `Research/Host/kextrw_host_integration.md:29-39` прямо сказано: kext KextRW **отклонён**, потому что kcall10 «уже даёт ту же мощность» (kernel R/W собирается из kcall + task_for_pid / port→map / TPRO / vm-патчей). То есть это задел, а не используемый путь.

---

## 3. Все патчи ядра: что делают и что требует нарушения boot-chain

### 3.1. Ответ на главный вопрос раздела

**Все без исключения патчи ядра требуют предварительного нарушения подписи boot-chain.** Они применяются оффлайн к файлу `kernelcache.research.vphone600` на хосте. Чтобы гость загрузил изменённый kernelcache, должны быть выполнены два условия, и оба лежат в загрузочной цепочке:

1. Прошивка проходит персонализацию/подпись так, что изменённый ядро-образ допускается (сборка гибридного BuildManifest и TSS для личности `vresearch101ap`, `Research/Firmware/firmware_manifest_and_origins.md:9-14`).
2. Проверки в загрузчиках и мониторах выключены патчами LLB/iBSS/iBEC и TXM (раздел 4; таблица `firmware_manifest_and_origins.md:72-90`).

Иными словами, «просто применить к серийному ядру» нельзя: неподписанный kernelcache не пройдёт boot-chain. Часть патчей (`*-boot-*`, `bootEssential`) нужна для самой загрузки, остальные (`*-cfw-*`, `*-exp-*`) — функциональные, но тоже едут в том же заранее подписанном образе.

**Как рантайм-патчи при наличии kernel R/W** (гипотетически) могли бы применяться почти все: каждый патч — это 1–2 инструкции в `.text` (NOP, замена BL на `MOV X0,#1`, `CBZ`→`B`, `cmp x0,x0`→`cmp xzr,xzr`), реже — запись в data-байты (`thid_should_crash`) или подмена указателя в `sysent` (`kcall10`). Механически это то, что делает любой jailbreak-патчер в памяти. Но:

- в самом репозитории **нет** рантайм-применителя этих патчей; все они рассчитаны на образ на диске;
- на устройстве с работающими SPTM/PPL страницы ядра защищены от записи, и чтобы их править, нужен отдельный эксплойт PPL/SPTM — его в репозитории нет. Упоминание PPL в коде/заметках одно — `KernelCache/KernelCacheRecipes.swift`, и это рецепт сборки, а не обход.

### 3.2. Патчи `kernel-boot-*` / `kernel-cfw-*` (набор `com.vphone.patchset.kernel.cfw`)

Источник формулировок: манифест `PatchSets/FirmwareKernelCustomFirmwarePatchSet.swift` (номера строк в квадратных скобках), детали — `Research/KernelCustomFirmwarePatches/*.md`.

| Патч | Что делает | Boot-essential |
|---|---|---|
| `amfi_trustcache` [39-43] | Пропускает собственный трасткэш гостя, чтобы шли неподписанные бинарники | да |
| `post_validation_unsigned` [46-50] | Дополняет базовый патч пост-валидации для неподписанных страниц | да |
| `cred_label_update_execve` [53-57], `hook_cred_label` [60-64] | Выдаёт platform-лейбл каждому бинарнику при execve; перенацеливает MACF-хук на пропатченный обработчик | да |
| `amfi_execve` [67-71] | Не даёт AMFI убивать процесс с «неправильной» подписью | да |
| `load_dylinker` [74-78] | Разрешает бинарнику указывать dyld вне запечатанного образа | да |
| `task_conversion_eval` [84-88] | Разрешает конвертировать task-порт, который вызывающему не положен | да |
| `task_for_pid` [91] (`kernel-cfw-`) | `task_for_pid` возвращает порт любого процесса | нет |
| `port_to_map` [97-101] | Убирает panic при конвертации порта в `vm_map` | да |
| `proc_pidinfo` [104] (`kernel-cfw-`) | `proc_pidinfo` отдаёт сведения о чужих процессах | нет |
| `proc_security_policy` [110-114] | Стаб per-process security policy → allow | да |
| `spawn_validate_persona` [117-121] | Разрешает спавн под ненаследованной персоной | да |
| `thid_should_crash` [124-128] | Несоответствие идентичности потока не убивает процесс | да |
| `vm_map_protect` [134-138] | Разрешает делать исполняемую секцию writable | да |
| `vm_fault_enter_prepare` [141-145] | Позволяет fault-у поставить исполняемую неподписанную страницу | да |
| `shared_region_map` [148-152] | Разрешает мапить пропатченный dyld shared cache | да |
| `shared_region_size` [155-160] (iOS 27) | Расширяет arm64 shared region с 6 до 7 GiB | да |
| `bsd_init_auth` [166-170] | Пропускает ветку аутентификации imageboot при старте | да |
| `io_secure_bsd_root` [173-177] | Сообщает, что root-устройство не security-locked | да |
| `mac_mount` [180-184], `dounmount` [187-191] | Разрешает монтировать поверх sealed-пути; пропускает очистку при unmount, которая откатывала бы bind-монты | да |
| `nvram_verify_permission` [194] (`kernel-cfw-`) | Разрешает писать NVRAM-переменные, которые читает bootstrap | нет |
| `sandbox_ext` [203-207] | Остальные vnode/mount sandbox-хуки → allow-stub | да |
| `iouc_macf_gate` [210-214], `iouc_sandbox_gate` [217-222] (iOS 27) | Открывать IOUserClient мимо MACF и sandbox | да |
| `kcall10` [228-232] | `sysent[439]` → произвольный вызов функций ядра | да |
| `syscallmask` [235-239] | Расширяет наследуемую маску syscall | да |

Замечание по терминологии: `bootEssential` — признак манифеста, а не доказательство необходимости. Например, `kcall10` и `syscallmask` помечены как essential, хотя по смыслу это функциональные патчи.

### 3.3. Патчи под iOS 27 / paravirtual (там же, строки 245–360)

`kernel-boot-arm64e_x1` (ARM64E_X1 admission: приём subtype-12, exec PAC, authenticated shared region), CSSC-совместимость (эмуляция скалярных CSSC), `kernel-boot-di2`, `kernel-boot-exec_security_policy_kill`, `kernel-boot-container_manager_upcall_force_success`, `kernel-boot-iomfb_swapend`, `kernel-boot-fpfs_scoped_open`, `kernel-cfw-aks_unlock_bag`, paravirt user clients (открывать паравиртуальные GPU/декодер/Neural Engine/IOSurface scaler вне sandbox), ProMotion, Task3 shader cache, OpenGL ES. Это **совместимость с железом VM и новым userland**, а не обход защит; `exec_security_policy_kill` и paravirt user clients — ослабления. Все — оффлайн-патчи того же kernelcache.

### 3.4. `Research/Kernel/*.md`

В каталоге нет отдельных «своих» патчей — это служебные заметки к перечисленным выше: `kernel_jb_patch_notes.md` (история фиксации: nvram_verify_permission, thid_should_crash, hook_cred_label_update_execve — IMPLEMENTED; task_for_pid, load_dylinker, syscallmask — FIXED; iouc_failed_macf, bsd_init_auth, io_secure_bsd_root, vm_fault_enter_prepare — RETARGETED, сводка на строках 350–420), `kernel_patcher_verification.md`, `kernel_patch_*_validation.md`, `kernel_patch_sandbox_hooks_17_26_validation.md`, `kernel_fairplay_kexts.md`, `native_kdk_export.md`. Отдельных патчей они не добавляют.

### 3.5. `Research/KernelCustomFirmwarePatches/*.md` — что ещё не вошло в таблицу

`patch_amfi_cdhash_in_trustcache.md` (A1), `patch_amfi_execve_kill_path.md` (A2), `patch_task_conversion_eval_internal.md` (A3: `cmp Xn,x0` → `cmp xzr,xzr`), `patch_sandbox_hooks_extended.md` (A4: массовые стабы `mov x0,#0; ret`), `patch_iouc_failed_macf.md` (A5-v2: `CBZ W0, allow` → `B allow` в одном узком месте, `0xFFFFFE000825BA98`), `patch_post_validation_additional.md` (B5), `patch_proc_security_policy.md` (B6), `patch_proc_pidinfo.md` (B7), `patch_convert_port_to_map.md` (B8), `patch_vm_map_protect.md` (B10), `patch_dounmount.md` (B12), `patch_bsd_init_auth.md` (B13), `patch_task_for_pid.md` (B15), `patch_load_dylinker.md` (B16), `patch_shared_region_map.md` (B17), `patch_nvram_verify_permission.md` (B18), `patch_thid_should_crash.md` (B20), `patch_cred_label_update_execve.md` (C21), `patch_syscallmask_apply_to_proc.md` (C22), `patch_hook_cred_label_update_execve.md` (C23), `patch_kcall10.md` (C24), `patch_mac_mount.md` (B11), `patch_io_secure_bsd_root.md` (B19), `patch_spawn_validate_persona.md` (B14), `patch_vm_fault_enter_prepare.md` (B9), `patch_shared_region_size.md`, `patch_vm_map_delete_immutable_code.md`, `patch_thread_set_state.md`, `patch_tpro_off.md`, `patch_syscall_filter_off.md`, `patch_fork_inherit_invalid_code.md`, `26.5_jb_hook_fixes.md`.

Полный указатель — `Research/KernelCustomFirmwarePatches/README.md`; архив проверок — `RuntimeVerification/`. Все — оффлайн-патчи; рантайм-применителя в репозитории нет.
---

## 4. TXM: что это, что патчится, что переносится на A15+

### 4.1. Что такое TXM

TXM (Trusted Execution Monitor) — монитор, который на устройствах с SPTM выполняет проверки кодовой подписи вместо ядра (на A15+ ядро больше не само решает, доверять ли странице). Модель исполнения по `Research/Firmware/txm_jb_patches.md:6-21`:

```
SPTM (GL2) — Secure Page Table Monitor
  ↕ svc #0
TXM (GL1) — Trusted Execution Monitor
  ↕ trap
Kernel (EL1/GL0)
```

SPTM диспатчит селекторные вызовы в TXM. TXM **не может** исполнять код SPTM (instruction fetch permission fault) и вернуться в SPTM может только через `svc #0` (`txm_jb_patches.md:104-149`). Отсюда важное свойство: **в рантайме TXM пропатчить нельзя** — его страницы защищены SPTM, и для их правки нужен эксплойт SPTM. В vphone его правят оффлайн.

### 4.2. Что патчится (по документам и по коду)

Селекторы TXM (`txm_jb_patches.md:162-178`): 24 — валидация CodeSignature, 41 — entitlements процесса (`get-task-allow`), 42 — отладочное мапирование памяти, а также конфигурация Developer Mode при инициализации.

Шесть логических патчей, 11 изменений инструкций (`txm_jb_patches.md:180-700`, реализация — `FirmwarePatcher/TXM/TXMDevPatcher.swift`):

| # | Что | Где (RESEARCH-вариант iPhone17,3 / PCC-CloudOS 26.x) | Патч | Строка кода |
|---|---|---|---|---|
| 1–2 | Обход сравнения хэша подписи (selector 24) | `0x313ec` `LDR X1,[X20,#0x38]`; `0x313f4` `BL hash_flags_extract` | NOP, NOP | (исторический, заменён на #7) |
| 3 | `get-task-allow` → true (selector 41) | `0x1f5d4` `BL entitlement_lookup` | `MOV X0,#1` | `:530` |
| 4 | Shellcode в code cave для selector 42 при ошибке 29 | `0x2717c` `MOV X0,X20` → `B` в cave `0x5d3b8` | `MOV X0,#1; STRB W0,[X20,#0x30]; …; B back` | `:578` |
| 5 | Debugger entitlement → true (selector 42) | `0x1f3b8` `BL entitlement_lookup("com.apple.private.cs.debugger")` | `MOV W0,#1` | `:695` |
| 6 | Developer Mode bypass | `0x1fa58` `TBNZ W9,#0` | NOP → `MOV W20,#1` | `:745` |
| 7 | Selector 24 → всегда PASS | `0x313b0` после prologue | `mov w0,#0xa1; b <epilogue>` | `:420` |

Цепочка зависимостей (`txm_jb_patches.md:656-688`): 6 (Developer Mode) → 3/4 (`get-task-allow`) → 5 (debugger entitlement) → отладка любого процесса; 1–2/7 независимы.

Важная история, показывающая, что это не «выключить одну проверку»:

- Первые два NOP-патча **ломали** загрузку, а не чинили: в `txm_selector24_analysis.md` и `txm_fullchain_analysis.md:397-431` показано, что возвращаемый код `0xA1` — это **PASS** (byte 1 = 0), а `0x130A1`/`0x22DA1` — FAIL; ранние версии анализа трактовали наоборот. NOP-ы портили состояние и вызывали панику `unexpected SIGKILL of init`.
- Итоговое решение — ранний возврат PASS после prologue с сохранением epilogue (`txm_selector24_analysis.md:258-291`).

### 4.3. Что реально применяется сейчас (код, а не только документы)

`TXMDevPatcher.swift:22-54`:

1. **Либо** `txm-cfw-executable_remap` (нативная классификация подписи, включает trustcache bypass с настоящими запросами к кэшу), **либо** `txm-boot-trustcache_bypass` — они взаимоисключающие.
2. `txm-exp-precheck_admission` — только если разрешён вручную (iOS 27).
3. Всегда: `patchSelector24ForcePass()`, `patchGetTaskAllowForceTrue()`, `patchSelector42_29Shellcode()`, `patchDebuggerEntitlementForceTrue()`, `patchDeveloperModeBypass()`.

То есть **шесть dev-патчей из `txm_jb_patches.md` применяются всегда**, альтернатива только в том, как обходится проверка трасткэша/подписи. `txm-cfw-executable_remap` (`Research/Firmware/txm_executable_remap.md:106-116`) меняет 9 инструкций: сохраняет настоящий поиск cdhash, использует обход hash-flags, ослабляет CMS/ad-hoc tolerance, разрешает библиотеки без/с чужим Team ID (типы 3–5), при включённом AMFI-bypass — прощает отсутствующий профиль. Это уже не «всегда PASS», а **ослабленная, но настоящая проверка**.

### 4.4. Что переносится на физическое устройство (A15+ с SPTM release-TXM)

Прямо — **ничего**. Чтобы патч лёг, нужно одно из двух, и ни того, ни другого в репозитории нет:

1. **Нарушить подпись boot-chain** — подменить TXM (и kernelcache) так, чтобы iBoot его загрузил. В vphone это решается не эксплойтом, а тем, что образы для research-платы подписываются Apple в research-варианте и затем модифицируются патчами загрузчиков (LLB/iBSS/iBEC/AVPBooter: `FirmwareBootChainPatchSet.swift:15-118`, например `avpbooter-boot-dgst_bypass`, `llb-boot-image4_callback`, `llb-boot-rootfs`, `llb-boot-panic_bypass`). На серийном устройстве iBoot проверяет подпись TXM ключом Apple, и неподписанный/изменённый TXM не загрузится. Для этого нужен эксплойт в boot chain (checkm8-класса в bootrom либо в iBoot) + подписанный образ. Такого эксплойта в репозитории нет.

2. **Рантайм-обход SPTM** — получить запись в страницы TXM/protected memory. Требует эксплойта SPTM. В репозитории нет ни того, ни другого. В рантайме ни PPL, ни SPTM, ни TXM никто не обходит.

Что **переносится** — знание о том, где и что проверяет TXM. Реверс выполнен на research-сборке TXM, но по `Research/Firmware/txm_variant_diff.md:10-12, 46-49` iPhone- и cloudOS-IPSW содержат один и тот же TXM (одинаковый SHA-256), а research-вариант отличается от release всего на 0.73% байт (в основном идентификатор сборки). То есть структура проверок selector 24/41/42 в release-TXM серийного A15+ **та же**, и этот реверс — готовая карта целей. Но карта целей не равна возможности их достать: на серийном устройстве до этих инструкций не добраться.

---

## 5. «vresearch101» как исследовательская платформа Apple (SDOM/fusing)

### 5.1. Что подтверждается кодом и заметками

| Факт | Ссылка |
|---|---|
| VM представляется в DFU как `vresearch101ap`: `CPID:FE01`, `BDID:90`, `cprv/cpfm = 0x0 / 0x3`, серийник `SDOM:01 CPID:FE01 CPRV:00 CPFM:03 SCEP:01 BDID:90` | `Research/Restore/virtual_dfu_probe.md:31-37` |
| Аппаратная модель VM создаётся через приватный `_VZMacHardwareModelDescriptor` с `platformVersion=3`, `boardID=0x90`, `ISA=2` («matches vresearch101»); для PV=3 хосту нужен entitlement `com.apple.private.virtualization.security-research` | `VPhoneExecutable/VPhoneVirtualization/UI/VirtualMachine/VPhoneVirtualMachineHardwareModel.swift:5-24` |
| Прошивка — гибрид: boot chain и SPTM/TXM из PCC `vresearch101ap`, runtime-компоненты из PCC `vphone600ap`, ОС — iPhone 17,3 | `Research/Firmware/firmware_manifest_and_origins.md:1-14` |
| PCC = Private Cloud Compute; `vresearch101` — «research board», входящая в cloudOS-IPSW; `vphone600ap` есть только в бета-cloudOS 26.1–26.4 | `PatchSets/FirmwareResearchBoardPatchSet.swift:3-9`; `Research/0_binary_patch_comparison.md:5140-5146` |
| cryptex гостя собирается `cryptexctl.research` из «Security Research tools (the PCC Virtual Research Environment)» с `--BORD=0x90 --CHIP=0xfe01 --SDOM=0x1` | `VPhoneExecutable/VPhoneVirtualization/UI/GuestCommunication/VPhoneGuestControlCryptex.swift:9-15, 81-83` |
| Сервер подписи Apple персонализирует cryptex, собранный `cryptexctl.research`, для платы vresearch101 | `Research/Firmware/trusted_darwinos_cryptexes.md:31-35` |
| `os_variant_allows_internal_security_policies` спрашивает, development-fused ли железо и development ли ядро | `VPhoneCommand/FirmwarePatcher/CustomFirmware/CustomFirmwareInternalReleaseType.swift:23-25` |

### 5.2. Оценка гипотезы

Гипотеза в целом **подтверждается, но с уточнением терминов**.

- **Подтверждается:** vresearch101 — это внутренняя исследовательская платформа Apple для Private Cloud Compute (PCC Virtual Research Environment / VRE), а vphone-cli выдаёт VM за её плату. Тот факт, что Apple signing-сервер подписывает для неё research-cryptex и research-прошивку, а хост-фреймворк для PV=3 требует entitlement `…security-research`, однозначно указывает на исследовательскую платформу, а не на серийный продукт.
- **Уточнение по «fusing»:** в коде видно только значение `CPFM:03` в виртуальном серийнике и `SDOM:01`/`--SDOM=0x1`. Что **именно** означают биты CPFM на этой плате (development fuse или иное), код не расшифровывает; я не проверял по документации Apple. Строка про «development-fused» относится к вопросу `os_variant`, а не к утверждению, что VM — dev-fused.
- **Уточнение по SDOM:** `SDOM:01` здесь — значение security domain в серийнике и параметр `cryptexctl.research`, и из кода не следует, что это «особый» домен; для серийных устройств значение может быть тем же. Вывод «SDOM = признак research-платы» я делать не могу.

### 5.3. Что даёт vphone по сравнению с серийным iPhone

1. **Research-ядро**: загружается `kernelcache.research.vphone600`, а не release-ядро серийного устройства.
2. **Research-TXM**: `txm.iphoneos.research.im4p`, который затем патчится (`firmware_manifest_and_origins.md:90`).
3. **Свой трасткэш**: AMFI пропатчен, чтобы принимать собственные записи трасткэша гостя.
4. **Ослабленное ядро**: task_for_pid для любого процесса, конвертация task-порта/`vm_map`, writable-executable, исполнение неподписанных страниц, `kcall10` (произвольный вызов функций ядра).
5. **Developer Mode и get-task-allow без enrolment**: выдаются патчем TXM.
6. **dylib-инъекция в любой процесс** и рантайм-патчинг userland-кода гостя.
7. **Обновляемые компоненты без Apple**: DeviceTree, SEP, NVRAM, системные файлы гостя правятся патчами; `ReleaseType = Internal` в SystemVersion.plist, чтобы libmis принимал приложения с personal team (`CustomFirmwareInternalReleaseType.swift:26-34`).
8. **Несколько ОС на одном образе ядра**: iPhone/iPad/TV/Watch/visionOS/HomePod-пресеты из одной cloudOS-исследовательской базы (`patches_presets/*.plist`).

Чего серийный iPhone (в том числе в режиме Developer Mode / с personal team) из этого не даёт: пункты 1–6, 7 (кроме ReleaseType — его на серийном устройстве менять нельзя) в силу подписи boot-chain и работающих SPTM/PPL/TXM.

### 5.4. Есть ли в коде пути для серийных устройств

**Нет.** Поиск по репозиторию показывает, что все пути завязаны на research-плату и Virtualization.framework:

- Хост создаёт VM только через приватный `_VZMacHardwareModelDescriptor` (PV=3, `boardID 0x90`), что требует research-entitlement на хосте (`VPhoneVirtualMachineHardwareModel.swift:5-24`).
- Восстановление/прошивка идёт через TSS для личности `vresearch101ap` (`firmware_manifest_and_origins.md:9-14`), а не через серийное устройство.
- Cryptex собирается `cryptexctl.research` для `BORD=0x90 CHIP=0xfe01 SDOM=0x1` (`VPhoneGuestControlCryptex.swift:81-83`).
- Патчи TXM/ядра применяются к образам на диске, а в рантайме ни PPL, ни SPTM, ни TXM никто не обходит (разделы 3–4); эксплойтов в репозитории нет.
- Вся работа с «устройством» — это работа с VM: `vphone-cli vm create` / `fw patch` / `cfw install`; поиск `kextrw` находит только отклонённое исследование (`Research/Host/kextrw_host_integration.md`), и оно посвящено **хосту** (macOS), а не iOS-устройству.

Что теоретически можно было бы перенести на серийное устройство при наличии внешнего джейлбрейка: (а) **гостевые dylib** (раздел 2) — это userspace-код, который на устройстве с работающим task_for_pid/port→map работал бы так же; (б) **карта целей TXM** из реверса (раздел 4.4). Но ни то, ни другое в репозитории не реализовано для серийных устройств, и ни одно из них не даёт привилегий само по себе.

---

## Ограничения анализа

- Только статическое чтение; ни один патч не применялся, ни одна VM не запускалась.
- Не прочитано целиком: `FirmwarePatcher/CustomFirmware/` (патчи `/sbin/launchd`, jetsam, `patchMachO`), `DyldSharedCache/Patchers/*` (кроме заголовка hypervisor-патчера), большая часть `Research/Guest/*`, `Research/Kernel/kernel_fairplay_kexts.md`, `native_kdk_export.md`, `Research/Kernel/kernel_patch_*_validation.md`, `Research/Firmware/iboot_patches.md` (только фрагмент с SDOM-тегом), `opensep_sep_rom.md`, `openavb_boot_rom.md`.
- Значения `CPFM`/`SDOM` не сверялись с документацией Apple; раздел 5.2 — интерпретация по коду.
- Ссылки на `Research/0_binary_patch_comparison.md` даны по его текущей нумерации строк; файл активно дополняется.
- В первых попытках записи этого файла в него попал мусор; итоговая версия перечитана по разделам, но ее стоит пролистать целиком перед использованием.
