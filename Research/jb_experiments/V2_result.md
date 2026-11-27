# V2 — Доступ к гостю Basil с хоста: диск, vphoned, патчи, память

Дата: 2026-11-26. Режим: только чтение. Ничего не устанавливалось, не запускалось и не монтировалось (`hdiutil imageinfo` без attach). К работающей VM (сокет, API) обращений не делалось — всё ниже взято из кода, документации и файлов на диске.

## 0. Кратко

| Вопрос | Ответ |
| --- | --- |
| Можно ли читать/менять данные Basil с хоста | **Да, полностью и с правами root**, но не через диск, а через `vphone.sock` → `vphoned`. |
| Монтируется ли `Disk.img` | Как raw GUID/APFS-образ — да, на **выключенной** VM. System, Preboot, xART, Hardware, Update читаются и пишутся (так работает `cfw install`). **Data и User зашифрованы (FileVault, ключи обёрнуты SEP) — с хоста не открываются.** |
| HTTP API | Есть в бандле, у Basil **не включён** (запуск без `--api-listen`: в логе нет `[api]`, TCP-листенера нет). Всё то же доступно через unix-сокет без токена. |
| Память | Три вида дампа с хоста (core VM, физический ELF, дамп одного процесса) и `pause`/`resume`. |
| Патчи | Из 220 включённых в плане 220 применены. 55 в `NotApplicable` гостя — не «не смогло», а целевые файлы отсутствуют в этой сборке. Скрытие гипервизора включено вручную (5 патчей в `AllowedPatches`). |
| Ядро | Один kernelcache (MH_FILESET: ядро и кексты вместе) в Preboot: `/private/preboot/<manifest>/System/Library/Caches/com.apple.kernelcaches/kernelcache`. |

## 1. vphone-cli: команды VM и доступа к диску

Basil запущена бандлом `"/Library/Application Support/vphone-launchpad/Bundles/2.18.0-local.ba7a6fef/VPhone.bundle/Contents/MacOS/vphone-cli"` (на PATH его нет; в `~/.local/bin` только `vphone-launchpad-cli`). Исходники команд: `vphone-cli/VPhoneExecutable/VPhoneCommand/VPhoneCommand/`, сокет — `VPhoneVirtualization/UI/VPhoneHostAutomationServer.swift`.

### 1.1 Команды `vm`

| Группа | Команды |
| --- | --- |
| Жизненный цикл | `list`, `info`, `new`, `create`, `launch`, `stop [--timeout]`, `pause`, `resume`, `config`, `rename`, `delete` |
| `launch` | флаги `--detach [--timeout s]`, `--headless`, `--dfu`, `--api-listen host:port`, `--kernel-debug-port 6000…65535` |
| Копирование | `clone [--new-identity]`, `export --out x.tzst`, `import` |
| Снимки | `snapshot create|list|revert|delete` |
| Диск | `rebase --onto <vm|template> [--dry-run]`, `leases` |
| Шаблоны | `template setup|trim|show|list|find|adopt|delete` |
| Прочее | `network`, `create-bulk`, `write-manifest` |

Другие группы верхнего уровня: `fw` (`prepare`, `patch`, `catalog`, `list`, `patches`, `set-patches`, `inspect`, `resolve`, `ota`, `ota-preflight`, `ota-stage`, `im4p-*`, `aea-key`), `restore`, `cfw` (`install`, `inject-daemon`, `inject-daemons`, `inject-dylib`, `patch-*`), `patchset`, `host preflight`, `sign`, `archive`, `dump-entitlements`, `patch-firmware`, `patch-component`.

### 1.2 Наличие возможностей

| Возможность | Есть? | Как |
| --- | --- | --- |
| mount | Отдельной команды нет | Offline: `hdiutil attach -readonly -nomount Disk.img` на остановленной VM. Так же внутри делает `cfw install` (`Research/Host/disk_space.md`). |
| Копирование файлов | Да, живого гостя | Сокет `push` / `pull`; RPC `files.read`, `files.write`; REST `GET/PUT /v1/files/content` |
| exec в госте | Да | Сокет `shell`, RPC `script.eval`, `proc.run` (в сессии), `processes.spawn` (allowlist `ps`/`launchctl`/`log`) |
| Дампы памяти | Да | Сокет `memory.dump`, `memory.dump`+`physical`, `process.dump` (§5) |
| Снимки VM | Только на выключенной | `vm snapshot …` (APFS-клоны). У Basil каталога `Snapshots/` нет, снимков нет. |
| Отладка ядра | Да | `--kernel-debug-port` → GDB-stub ядра для LLDB |

### 1.3 Обращение к работающей VM

Сокет есть: `~/.vphone/machines/Basil/vphone.sock`. Одна JSON-строка на вход, одна на выход, соединения обслуживаются параллельно. Полный список типов запроса из кода: `ping`, `screenshot [path]`, `display.geometry`, `tap`, `swipe`, `key`, `hostkey`, `type` (ставит **буфер обмена**, не ввод), `rpc`, `push`, `pull`, `network [link]`, `pause`, `resume`, `memory.dump`, `process.dump`, `shell`.

```sh
S=~/.vphone/machines/Basil/vphone.sock
printf '%s\n' '{"t":"ping"}' | nc -U $S
printf '%s\n' '{"t":"rpc","method":"device.info","params":{}}' | nc -U $S
printf '%s\n' '{"t":"pull","path":"/etc/hosts","local":"/tmp/hosts"}' | nc -U $S
printf '%s\n' '{"t":"push","local":"/tmp/f","path":"/var/tmp/f","mode":"755"}' | nc -U $S
{ printf '%s\n' '{"t":"shell"}'; printf '6 * 7\n'; } | nc -U $S            # JS-сессия vphoned, ничего не нужно ставить
printf '%s\n' '{"t":"shell","program":"bash","cols":120,"rows":40}' | nc -U $S  # только если bash в bootstrap есть
```

Ответ `rpc`: `{"ok":true,"result":{…}}` или `{"ok":false,"error":"…","guest_error":{code,message,…}}`. Неизвестный `t` → `{"ok":false,"error":…}`.

**HTTP API** — тот же поток VSOCK 1339, проксированный в TCP с bearer-токеном: `GET /v1/health`, `POST /v1/rpc`, `WS /v1/events`, `WS /v1/shell`, `WS /v1/ports/<port>` (сырой TCP в гостя, например SSH), `WS /v1/host/screen`. Включается только флагом `--api-listen` при запуске; у Basil его нет. По возможностям он ничем не превосходит сокет, разница только в транспорте и токене.

**vphoned HTTP API** (`Research/vphoned_http_api.md`): `POST /v1/rpc {"method","params"}` → `{"type":"response","id","result"|"error"}`; на сокете то же через `{"t":"rpc","method":…}`. Правила: `POST` только с `Content-Type: application/json` (иначе 415), запрос с `Origin` или чужим `Host` → 403, неизвестный параметр метода → `invalid_param`, лимит JSON 1 МиБ, гостя — 8 интерактивных сессий и 16 скриптов одновременно.

## 2. vphoned внутри гостя

**Что это.** Демон управления из состава vphone (`VPhoneDaemon/`), работающий **от root** с 278 entitlements (`VPhoneDaemon/Configuration/VPhoneDaemon.entitlements`, в т.ч. `com.apple.private.vfs.snapshot`, `com.apple.private.xpc.service-configure`, `com.apple.private.xpc.service-attach`, `com.apple.private.kernel.jetsam`, `dynamic-codesigning`). Копия для заливки лежит в `~/.vphone/machines/Basil/.vphoned.signed` (13.2 МБ). В госте: launchd-прокси (`VPhoneDaemon/Configuration/vphoned.plist`) стартует worker (`vphoned --io`), который держит **VSOCK 1339** (HTTP/WS) и **1338** (камера); лог `/var/log/vphoned.log`. Worker перезапускается через 1 с после падения. Хост при каждом подключении сверяет хэши vphoned и четырёх guest-dylib (`launchdhook-vphone`, `SystemHook-vphone`, `libvcamcaptured`, `libcamfix`) с `Contents/Resources/guest-resources` и при расхождении заливает обновление (`environment.install`, `agent.apply_update`). Отсюда в receipt `Writer = cfw update-environment` от 17:08.

**Права root — да.** `Research/vphoned_http_api.md`: «vphoned runs as root, and the API can read and write any guest file, list the keychain and load launch daemons». Сессия (`shell`/`script.eval`) — отдельный процесс, порождённый от бинарня vphoned, с его сигнатурой и entitlements.

### 2.1 Endpoint'ы файловой системы

| Метод | Что делает |
| --- | --- |
| `files.list {path, limit?, cursor?}` | листинг (постранично, до 1000) |
| `files.read {path, binary?, offset?, limit?}` | чтение; текст по умолчанию, base64 с `binary:true`; с `offset`/`limit` отвечает `total`, `next_offset` (лимит 512 КиБ по умолчанию) |
| `files.write {path, data…}` | запись |
| `GET /v1/files/content?path=…` | поток байтов; `PUT` — загрузка (octet-stream, `mode` в query, во временную папку затем rename) |
| `files.mkdir`, `files.remove`, `files.rename`, `files.copy`, `files.symlink`, `files.chmod`, `files.chown` | прочие операции от root |
| `files.find {…}` | поиск (до 500 совпадений) |
| `files.plist {path}`, `files.plist_set {path, key, value | remove}` | чтение/правка plist |
| Сокет `push` / `pull` | стриминг файлов любой длины через `PUT /v1/files/content` |
| В сессии JS | `fs.ls`, `fs.read`, `fs.write`, `fs.stat` («the root-privileged file operations») |

### 2.2 Endpoint'ы процессов и запуска команд

| Метод | Что делает |
| --- | --- |
| `processes.list {filter?, limit?, cursor?}` | список с `proc_pid_rusage` (footprint, RSS, CPU), jetsam-полоса, bundle id |
| `processes.spawn {executable, arguments?, timeout_ms?}` | **ограниченный**: только `ps`, `launchctl`, `log`; без shell, до 16 аргументов, таймаут 100–10000 мс, вывод в spool (`/var/root/Library/Caches/vphoned-spool/<id>/`) |
| `processes.output`, `processes.output_release` | чтение/освобождение spool |
| `processes.kill {pid, signal?}` **force** | сигнал процессу |
| `script.eval {source, timeout_ms?}` | **произвольный код**: JavaScriptCore + ObjC-мост; глобали `ObjC`, `api`, `fs`, `proc`, `console`, `print`, `sleep` |
| `proc.run(path, args, input)` (внутри сессии) | **запуск любой программы** от root, возвращает `{status, signal, stdout, stderr}` |
| `WS /v1/shell` / сокет `{"t":"shell"}` | интерактивный терминал: REPL vphoned (`probe>`), либо имя программы из `bin`/`usr/bin`/`usr/local/bin` bootstrap, либо абсолютный путь |
| `services.list/start/stop/load/unload/enable/disable/kickstart {label, kill?}` | launchd от root: **загрузить свой LaunchDaemon** = персистентность с правами root |
| `system.reboot`, `system.shutdown`, `system.respring` **force** | питание/перезапуск |
| `apps.install {ipa/tipa}` | установка IPA в обход installd (переподпись vphone-сигнером) |
| `bootstrap.install {layout: rootless\|roothide}` | установка Irisin-бутстрапа (packagemanager) — по умолчанию в госте **нет** ни apt, ни ssh, ни bash |
| `keychain.list/add/delete/get/update` | keychain (листинг без значений) |
| `apfs.snapshots`, `apfs.snapshot.delete` **force** | снимки `/` (удалять умеет только `orig-fs.disabled.rn-*`) |
| `logs.syslog`, `logs.crashes`, `logs.crash` | логи и краш-репорты |
| `udid.set`, `device.name.set`, `network.*`, `location.*`, `time.*`, `display.*`, `input.*`, `ui.tree`, `ui.ocr`, `screen.screenshot` | идентичность, сеть, ввод, экран |
| `cryptex.*` | только для trusted darwinOS-гостя (у Basil нет) |

**Итог по §2:** root-exec в госте — `script.eval` (JS/ObjC от root), `proc.run` в сессии, `shell` и `services.load`. Значит вопрос «читать/менять данные внутри гостя с хоста» закрывается полностью, включая зашифрованные Data/User, потому что читает сам root-процесс внутри гостя. При этом гостем это никак не логируется на стороне хоста, кроме самого факта соединения с сокетом.

## 3. PatchReceipt.plist vs PatchPlan.plist

Оба прочитаны `plutil -p` в `~/.vphone/machines/Basil/`. Дополнительно: `PatchSelection.plist` → `Preset = standard`, `AllowedPatches` = `dyld-exp-hv_vmm`, `kernel-exp-hv_vmm`, `preboot-exp-devicetree_identity`, `system-bluetoothd-exp-hv_vmm_cache`, `system-watchdogd-exp-hv_vmm_cache`; `BlockedPatches` пуст. `restore-info.json`: `variant = jb`, iOS 27.2 (24B119), cloudOS 26.4 (23E5207q). `TemplateSource.plist`: клон шаблона `a74f0d786cbc` от 12:58 UTC.

### 3.1 План

`PatchPlan.plist` (09:12 UTC): `Preset = standard`, 10 patch-сетов (bootchain, kernel.base, kernel.cfw, kernel.hypervisor, kernel.frida, research.board, devicetree, guest.system, guest.display, guest.identity), `Parameters` пуст.

- `EnabledPatches` — **220** идентификаторов.
- `NotApplicablePatches` — 4: `devicetree-boot-vresearch101_conversion`, `kernel-boot-vresearch101_kext_mix`, `restoreramdisk-boot-apfs_sha3_hash`, `sep-boot-vresearch101_sepd_dispatch`.

### 3.2 Receipt (что реально применено)

| Часть | Применено | Не применимо | Кем/когда (UTC) |
| --- | --- | --- | --- |
| LLB | 6 | 0 | `restore`, 12:23:46 |
| iBSS | 3 | 0 | `restore` |
| iBEC | 4 | 0 | `restore` |
| DeviceTree | 29 | 0 | `restore` |
| RestoreRamDisk | 0 | 0 | `restore` |
| SEP | 0 | 0 | `restore` |
| SPTM | 0 | 0 | `restore` |
| TXM | 7 | 0 | `restore` |
| kernelcache | 56 | 0 | `restore` |
| Guest | 61 | **55** | `cfw update-environment`, 17:08:17 |

Сверка с планом: сумма применённых 6+3+4+29+7+56+61 = **166**; плюс 55 `NotApplicable` = **221**. Это ровно 220 патчей плана плюс один: `system-bluetoothd-exp-hv_vmm_cache` есть в receipt, но в `PatchPlan.plist` отсутствует (план от 09:12 записан раньше, чем этот патч появился в бандле 2.18.0-local и был разрешён в `PatchSelection`). То есть **ни один патч плана не потерян: 165 из 220 применены, остальные 55 — «неприменимы» в госте, а 1 применён сверх плана по `AllowedPatches`.**

### 3.3 Какие не применены и почему

**План → receipt: всё применено.** Отсутствующих нет. `kernel-exp-hv_vmm` — в `kernelcache`, `dyld-exp-hv_vmm` — в `Guest`.

**4 `NotApplicablePatches` плана** (решение пайплайна, `FirmwarePipeline.resolveFirmwareApplicability`):
- `devicetree-boot-vresearch101_conversion`, `kernel-boot-vresearch101_kext_mix`, `sep-boot-vresearch101_sepd_dispatch` — это патчи research-board, конвертирующие дерево cloudOS **без** vphone600-компонентов. Дерево Basil уже содержит vphone600-компоненты, конвертировать нечего.
- `restoreramdisk-boot-apfs_sha3_hash` — нужен только когда root-hash SystemVolume имеет тип `sha3_256_4k`; в этом IPSW тип SHA-256, инструменты restore остаются нетронутыми.

**55 `NotApplicable` части Guest** — это не отказы и не ошибки, а бинарки, которых нет в этой сборке / на этом устройстве:
- 46 × `system-<Name>popaccessibility-cfw-arm64e_x1` — X1-даунгрейд библиотек специальных возможностей (Accessibility), которых нет в 27.2 для iPhone17,3 (либо категория недоступна);
- `system-backboardd-cfw-hinge`, `system-springboard-cfw-fold_guard`, 3 × `preboot-cfw-devicetree_foldable_*` — складные устройства (Basil — не складной);
- `preboot-homepod-exp-audio_product`, `system-dyld-exp-tv_tpro`, 8 × `system-nano*`/`ntk*`/`com_apple_nanotimekit_createwatchface`, `system-fitnessapp`/`fitnessui`, `system-gputools*`, `system-schooltimesettingsui` — HomePod / Apple TV / Watch / Fit-приложения, отсутствующие в iOS-сборке iPhone;
- отладочные библиотеки `libbacktracerecording`, `libdispatch_introspection`, `libglinterpose`, `liblogredirect`, `libmainthreadchecker`, `libmetalmetricsinterpose`, `libmtlhud`, `librpac`, `libviewdebuggersupport` — не входят в 24B119 userland (это macOS/Xcode-библиотеки);
- `system-systemversion-cfw-build_version` — патч `SystemVersion.plist` под другую базу, здесь не требуется.

Точную причину по каждому из 55 код не логирует в receipt (только список); классификация выше — по имени и по набору патчей. Проверяется только чтением кода соответствующего патчера.

### 3.4 Важное: скрытие гипервизора включено вручную

`standard` по умолчанию **не** включает `hypervisorConcealmentPatches` (`FirmwarePatchSetCatalog.swift`): на свежевосстановленном 26.4 госте переименование `kern.hv_vmm_present` кладёт `bluetoothd` в crash-loop, тянет за собой `locationd` и миграцию данных — чёрный экран. У Basil эти 4 патча разрешены в `PatchSelection.plist` и применены. В `Research/0_binary_patch_comparison.md` (раздел от 2026-11-26) это описано ровно на Basil: понадобился новый патч `system-bluetoothd-exp-hv_vmm_cache` и сброс кэша libMobileGestalt. Итог: `kern.hv_vmm_present` из userland не виден, MobileGestalt `IsVirtualDevice` = true. Последствие: **детект VM по sysctl из гостя не сработает**; детект по другим признакам (CoreBrightness `VMBLControl`, `hw.model` и т.п.) — может.

Для джейлбрейк-исследований важно и другое из применённого (kernelcache, 56 патчей): `kernel-boot-amfi_execve`, `kernel-boot-amfi_trustcache`, `kernel-cfw-task_for_pid`, `kernel-cfw-debugger`, `kernel-boot-kcall10` (syscall 439 → вызов произвольной функции ядра), `kernel-boot-sandbox_ext`, `kernel-boot-mac_mount`, `kernel-boot-apfs_root_snapshot`, `kernel-boot-apfs_seal_broken`, `kernel-boot-bsd_init_auth`, `kernel-boot-launch_constraints`, `kernel-boot-dyld_policy`, `kernel-cfw-proc_pidinfo`, `kernel-boot-vm_map_protect`, `kernel-cfw-nvram_verify_permission`, `kernel-cfw-aks_unlock_bag`; в TXM: `developer_mode_bypass`, `trustcache_bypass`, `get_task_allow`, `debugger_entitlement`, `executable_remap`. То есть ядро уже «джейлбрейкнутое» на уровне патчей; бутстрап (Sileo/apt/SSH) в госте отсутствует по умолчанию (`Firmware Mode` в AGENTS.md), ставится отдельно `bootstrap.install`.

## 4. Disk.img Basil с хоста

```
hdiutil imageinfo ~/.vphone/machines/Basil/Disk.img
Class Name: CRawDiskImage
Format: UDRW   Total Bytes: 64000000000   Sector Count: 125000000
Checksum Type: none   partition-scheme: GUID   block-size: 512
partition 1: "Container", Apple_APFS, start 40, length 124999920
```

- **Формат:** raw (UDRW, без сжатия и чексумм), GPT с единой APFS-партицией «Container» на весь диск. Sparse: логический размер 64 ГБ, занято на хосте **21 ГБ** (`du -h`; `Total Non-Empty Bytes` у hdiutil — логическая величина).
- **Не монтировался** (VM работает с 14:10, pid `vphone-vm` 59146, диск открыт им и сервисом Virtualization 59204). Монтировать нужно только на остановленной VM и read-only: `hdiutil attach -readonly -nomount`, затем `diskutil mount readOnly diskNsM`. На работающей — риск повреждения контейнера, которого хост не увидит.

**Тома внутри контейнера** (по `Research/Host/disk_space.md`, `machine_identity_and_clone.md`; у Basil напрямую не проверялись):

| Том | С хоста | Содержимое |
| --- | --- | --- |
| System | читается, пишется | ~16 ГБ, «Sealed: Broken»: root fs из restore + переименованный снимок `orig-fs.disabled.rn-<hash>` (8.6 ГБ) + криптексы OS/App (7.2 ГБ) |
| Preboot | читается, пишется | 61 МБ: kernelcache 43 МБ, SEP/прочая прошивка 17 МБ |
| Data | **не открывается** | FileVault, ключ обёрнут SEP; `/var`, контейнеры приложений |
| User | **не открывается** | FileVault, ключ обёрнут SEP; `/var/mobile` |
| xART, Hardware | читаются | gigalocker `AA.gl`, `mobileactivationd.uuid`, тикет |
| Update | читается | пусто |

**APFS-снимки:** минимум один — `orig-fs.disabled.rn-*` (sealed snapshot, переименован CFW). Точное имя и список даёт RPC `apfs.snapshots` на живом госте или `diskutil apfs listSnapshots` на смонтированном System offline. `Snapshots/` (снимки самой VM через `vm snapshot`) у Basil нет.

**Где ядро и кексты:**
- `/private/preboot/<boot-manifest-hash>/System/Library/Caches/com.apple.kernelcaches/kernelcache` — единственный загружаемый kernelcache (~43 МБ, IM4P). Именно его ищут `cfw install` (`VPhoneCustomFirmwareInstaller.swift:874`) и vphoned (`GuestMobileGestaltCache.swift`). С хоста: вытащить из Preboot offline, либо `pull` через сокет с живого гостя.
- `/System/Library/Caches/com.apple.kernelcaches/kernelcache` на System-томе — копия, лежит рядом с `/System/Library/Extensions`; загружается версия из Preboot.
- `/System/Library/Extensions/*.kext` — на iOS 27 это данные (plist, ресурсы, в основном GPU-драйвер cloudOS); **исполняемые кексты в рантайме не подгружаются**, все они — entry-файлы `MH_FILESET` внутри kernelcache (`__PRELINK_INFO`, `com.apple.kernel`, `__KLD`).
- `/System/Cryptexes/OS/…` — OS/App-криптексы, скопированные `cfw install` на System-том; `System/Library/Caches/com.apple.dyld` — симлинк в них (dyld shared cache 5.9 ГБ + 1.2 ГБ `.symbols`).
- Рецепт ядра Basil в бандле: `Resources/kernelcache_recipes/bases/27.2_24B119/` (`kernelUUID 1B105A34-88BB-3EC3-BD36-16E6A2851616`, донор `vphone600_26.4_23E5207q`, layout kernel-last, `symbols.json.gz` с картой символов — нужна для дампов памяти и symbolication).

## 5. Memory dump, pause/resume, disk space

Источники: `Research/Host/memory_dump.md`, `process_memory_dump.md`, `pause_resume.md`, `disk_space.md`, `guest_discard.md`; `Documents/en/machines/memory-dumps.md`, `storage/*.md`.

### 5.1 Три вида дампа памяти (сокет, живая VM)

| Запрос | Файлы | Содержимое | Пауза |
| --- | --- | --- | --- |
| `{"t":"memory.dump","path":"/abs/new"}` | `AP.core`, `SEP-coproc.core`, `info.json` | RAM по **виртуальным** адресам ядра (8443 МиБ kernel VA + ~1.1 ГБ user VA в измеренном дампе), `ARM_THREAD_STATE64` каждого vCPU, память SEP (~20 МБ) | 8–16 с |
| `…,"physical":true` | `physical.elf`, `info.json` | вся RAM по **физическим** адресам: PT_LOAD на DRAM и carve-out, note `VPHONE` (0x5650) с базой DRAM и корнем таблиц страниц; неиспользованные страницы пропущены | 10–20 с |
| `{"t":"process.dump","pid":36,"name":"SpringBoard","path":…}` | `<Proc>.core`, `info.json` | резидентная память одного процесса по его адресам, `LC_THREAD` на каждый поток с регистрами. Читается **с хоста через таблицы страниц госта**, без участия госта | 0.5–6 с |

Механика: `memory.dump` — приватный core-writer Virtualization (`_createCoresWithCompletionHandler:`), сам ставит и снимает паузу. `process.dump`/`physical` — `task_for_pid` на сервис Virtualization, `mach_vm_remap` его памяти (только чтение), поиск ядра по `TTBR1_EL1`/`VBAR_EL1` через kernel debug stub, обход списка процессов от `_kernproc`, обход page tables.

Условия и лимиты:
- свободное место ≥ RAM гостя (8.6 ГБ на 8 ГБ гостя; проверяется **до** паузы); папка не должна существовать, родитель — должен; один дамп на машину одновременно;
- SIP `csrutil enable --without debug` (уже выполнено — VM работает); `process.dump` нужен debug stub: пока на нём сидит LLDB — «no reply in time»;
- `process.dump` работает для ядер из рецептов бандла (18.1–27.2); 27.2_24B119 есть;
- паузу можно снять только после завершения дампа (`pause`/`resume` во время дампа отклоняются); на уже приостановленном госте дамп работает и оставляет его на паузе;
- **нет** системных регистров (TTBR, PAC-ключи), нет страниц, которых гость не трогал/сжал/выгрузил; `AP.core` не содержит физической раскладки.

Анализ: `lldb -c AP.core`, `target modules load --file <kernelcache> --slide <slide>`; `physical.elf` — для инструментов физической памяти; `<Proc>.core` LLDB открывает напрямую (`image list`, `bt all`, `memory read`).

### 5.2 pause / resume

`{"t":"pause"}` / `{"t":"resume"}` на сокете, `vphone-cli vm pause|resume Basil`, меню Device ▸ Pause Guest. Ответ за 0.07 с. Замирает всё: vCPU, SEP, таймеры, устройства; CPU хоста не расходуется. Память остаётся только в сервисе Virtualization — **сохранённого состояния нет** (`saveMachineStateToURL:` не работает с SEP-копроцессором). Во время паузы запросы к гостю (`rpc`, `push`, `screenshot`) отклоняются, ввод отбрасывается, `memory.dump` работает. `vm stop` снимает паузу и гасит гостя штатно.

### 5.3 Что это даёт для доступа к памяти работающего гостя

- **Чтение всей памяти с хоста без участия и без ведома гостя**: `physical.elf` для оффлайн-анализа (поиск ключей, токенов, строк, структур ядра), `AP.core` для LLDB-отладки ядра, `<Proc>.core` для анализа одного приложения (например, вытащить данные приложения, которые на диске лежат в зашифрованном Data).
- **Запись в память** — только через LLDB на GDB-stub (`--kernel-debug-port`) или через `kernel-boot-kcall10` из самого гостя. Сокет-команд записи в память нет.
- **Заморозка** перед дампом (`pause`), чтобы состояние не менялось.

### 5.4 Disk space

`Research/Host/disk_space.md`: машина после первого бута ≈ 20.5 ГБ (Basil — 21 ГБ): 8.6 ГБ sealed root fs, 7.2 ГБ криптексы, 2–5 ГБ Data/User. Guest TRIM возвращает место хосту за ~15 с. Снимки `vm snapshot`, клоны и шаблоны — APFS clonefile, бесплатны до первой записи гостя. Честный размер — по `df`, а не `du`.

## 6. Итоговая матрица доступа

| Слой | Чтение с хоста | Запись с хоста |
| --- | --- | --- |
| System / Preboot / xART / Hardware (offline mount остановленной VM) | да | да (так работает `cfw install`) |
| Data / User — данные приложений, `/var/mobile`, контейнеры, файлы keychain | **нет напрямую** (FileVault + SEP) | **нет напрямую** |
| Любой файл гостя через vphoned, включая Data/User | да, от root | да, от root |
| Запуск команд в госте | — | да, от root (`script.eval`, `proc.run`, `shell`, `services.load`) |
| Память гостя | да: 3 вида дампа | только LLDB на debug stub |
| Память одного процесса | да: `process.dump` | нет |

**Вывод.** Диск Basil с хоста полудоступен: системная часть читается и пишется offline, пользовательская — нет. На практике это не ограничение: `~/.vphone/machines/Basil/vphone.sock` → `vphoned` даёт root-доступ ко всей файловой системе живого гостя, shell, процессы, launchd, keychain. Плюс с хоста снимается память целиком, физическая и по процессам, и есть pause/resume. HTTP API у Basil выключен — сокет работает без него и без токена.

## 7. Замечания по ходу

- **Avocado** — каталога `~/.vphone/machines/Avocado/` нет. Есть остаток `~/.vphone/avocado-partial/` (Disk.img, config.plist, nvram.bin, SEPStorage, OpenAVB/OpenSEP). `~/Library/Logs/vphone-launchpad/Avocado.log`: запуск упал — `AMFI blocked vphone-vm` для бандла `2.18.0` (cdhash `94c084eb…`), нужен `sudo …/2.18.0/VPhone.bundle/Contents/MacOS/vphone-escalator allow …/vphone-vm`. `Avocado-create.log` кончается на «CFW VM created; its first boot was skipped» и успешном `vm launch Avocado` ранее. То есть VM, судя по логам, создавалась, но сейчас её каталог отсутствует (переименована в Basil через `TemplateSource`? — нет: Basil — клон шаблона; вероятнее каталог удалён/перемещён вручную). Уточнить у владельца.
- Basil — клон шаблона `a74f0d786cbc` (`TemplateSource.plist`, 12:58 UTC), UDID `0000FE01-040ADA118D900AB2` (`udid-prediction.txt`).
- В Basil.log два цикла загрузки (14:10 и вторая, ~16:xx по launchd-строкам в логе 17:10/17:42 UTC): гость перезагружался после `cfw update-environment` 17:08 UTC.
- Файл `/tmp/jbresearch/research/V2_result.md` — первая версия была записана с повреждениями и перезаписана; текущая — чистая.
