# worse_query как sandbox escape: проверено на живых устройствах

Дата: 2026-11-26. Пробник — `tools/wqprobe_escape.m` (на основе `worse_query.m` из `forcequitOS/worse_query`, GPLv3; сам `worse_query.m/.h` и `pathleak.m/.h` лежат рядом в `tools/`), bundle `me.strelov.wqprobe`, собственная App Group `group.com.strelov.wqprobe`. Запуск: `xcrun devicectl device process launch --console <device> me.strelov.wqprobe [many]`. Сырой вывод — `wq_escape/`.

Ключ к запуску: чтобы entitlement `com.apple.security.application-groups` попал в подпись, нужно (1) `SystemCapabilities: com.apple.ApplicationGroups: enabled` в pbxproj, (2) удалить старый Xcode-managed профиль для bundle ID и (3) пересобрать с `-allowProvisioningUpdates`. Иначе Xcode переиспользует профиль без группы, и entitlement молча выпадает из подписи — при этом `containerURLForSecurityApplicationGroupIdentifier` возвращает nil, и проверка ничего не докажет.

## Что проверено

По каждой цели — 40 попыток с флагом iOS 27 (`0x80_0000_0000`, `alt=0`) и 40 с флагом iOS 26 (`0x8_0000_0000`, `alt=1`). Аргумент `many` включает 40 попыток вместо 5.

| Цель | 17 Pro Max, 27.2.1 — alt=0 / alt=1 | iPhone 13, 26.5.2 — alt=0 / alt=1 |
|---|---|---|
| `/private/var/containers/Data/System` | **40/40** / 0/40 | 0/40 / 0/40 |
| `/private/var/containers/Shared/SystemGroup` | 0/40 / 0/40 | 0/40 / 0/40 |
| `/private/var/mobile/Containers/Data/Application` | 0/40 / 0/40 | 0/40 / 0/40 |
| `/private/var/containers/Bundle/Application` | 0/40 / 0/40 | 0/40 / 0/40 |
| `/private/var/mobile/Library` | 0/40 / 0/40 | 0/40 / 0/40 |
| baseline — собственный `Library/Caches`, без symlink | −6 / −6 | −6 / −6 |

Коды `worse_query()`: `-6` — `containermanagerd` вернул результат, но токен sandbox extension не выдан; `>=0` — handle после `sandbox_extension_consume`.

## Что покрывает токен

Токен выдаётся только на `/private/var/containers/Data/System` и покрывает всё под ним: рекурсивный обход дал 32 системных контейнера и 0 отказов внутри, видны `Documents`/`Library`/`tmp` и файлы (`AppProtectionBackup.plist`, `database.sqlite`, `SpecialAppEligibilityState.plist`, `DefaultAppQueryState.plist`, контейнер `com.apple.geod`).

На соседние пути не распространяется: `/private/var/containers/Data`, `/private/var/containers`, `/private/var/containers/Shared/SystemGroup`, `/private/var/mobile/Containers/Data/Application`, `/private/var/db`, `/private/var/mobile/Library/Preferences` — все `Operation not permitted`, пока handle удерживается. После `worse_query_release` доступ к `Data/System` снова `Operation not permitted`.

## Выводы

- `worse_query` на 27.2.1 / 17 Pro Max **работает** (токен выдан, потреблён, отозван), но в этой реализации — только для `Data/System` с флагом iOS 27. Для контейнеров приложений, App Group и SystemGroup токен не выдаётся.
- Это не TOCTOU-гонка: 40/40 против 0/40 — детерминированное поведение. Значит, успех зависит от того, какой контейнер `containermanagerd` считает законным для `class=7, part=3, flags=0x80…`, а не от времени между symlink и запросом.
- На iPhone 13 (26.5.2) — 0/80 по всем целям. Совпадает с тем, что автор `WQFiles` пишет про iOS 26: там нет System Data и системных групп; а для контейнеров приложений авторы используют inode-скан (`fsgetpath`), который на iPhone 13 в проверенном окне ничего не нашёл.
- `-6` и на baseline (собственный `Library/Caches` без symlink) — то есть даже законный запрос на собственный контейнер токена не получает. Это противоречит описанию автора и пока не объяснено (см. «Не проверено»).

## Не проверено

- Почему baseline-запрос на собственный `Library/Caches` тоже даёт `-6`. Возможные причины: в personal team App Group не «полноценная» (нет записи в портале), поэтому `containermanagerd` не считает группу законной; либо в iOS 27.2.1 что-то изменилось по сравнению с теми билдами, где автор тестировал (27.2, 27.0.1, 27.3b1).
- Другие значения `class`, `part`, `flags` — не перебирались.
- `Data/System` на iPhone 13 (там по описанию iOS 26 его нет) — цель возвращала `-6`, других проверок не делал.
- Чтение содержимого файлов внутри `Data/System` (только листинг каталогов и имена файлов).

## Отдельно: `kcall10` на Basil подтверждён, и это сломало VM

Пока разбирался с вопросом №1 из `05_…md` (почему на Basil закрыт `task_for_pid`), попробовал прочитать ядро Basil через `kcall10` (`sysent[439]`, `patch_kcall10` в `KernelCustomFirmwarePatches/`). Залил в гостя arm64-бинарник `kf` (`syscall(439, target, …)`), запустил через `proc.run` из root-сессии `vphoned`.

Результат: с `target = 0xdeadbeefdeadbeef` ядро запаниковало — `panic(cpu 1 …): PC alignment exception from kernel. at pc 0xdeadbeefdeadbeef`, `Panicked task … pid 474: kf`, в backtrace `lr: 0xffffbeefdeadbeef`. То есть **syscall 439 в Basil — действительно `kcall10`, и он переходит на переданный адрес без проверки**.

Это же и причина, по которой чтение ядра через `kcall10` не сделано: для полезного вызова нужен KASLR-слайд ядра, а:
- `process.dump` через хост не работает: `mach_vm_remap: 57` (vphone-vm в этой сборке не держит порт на service-процесс; нужен запуск с `--kernel-debug-port`);
- `memory.dump` целиком — 8 ГБ, хост уже в swap;
- `VPhoneGuestKernel` (чтение через таблицы страниц) доступен только из UI `process.dump`, не из сокета.

VM дважды упала (второй раз — повторный запуск того же `kf`), перезапускалась через `vphone-cli vm launch Basil --headless --detach`, после чего остановлена (`vm stop Basil`). Файл `kf` в `/private/var/tmp/kf` гостя остался — перед следующими работами с `kcall10` удалить.

## Что это меняет

- `worse_query` на 17 Pro Max даёт чтение `/private/var/containers/Data/System` — это уже полезно как userland-примитив (32 системных контейнера), но не даёт ни `proc_info`, ни IOKit, ни пути к KASLR. Для джейлбрейка по-прежнему нужен kernel-эксплойт.
- Проверка на Basil как «детектор» офлайн-патчей работает: `kcall10` подтверждён по панике, но читать ядро через него без слайда нельзя, а дамп через хост в текущей конфигурации недоступен.
