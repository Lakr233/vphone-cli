# Sileo на Basil: работает

Дата: 2026-11-26. VM Basil (27.2 / 24B119), root в госте через `vphone.sock`.

## Итог

Sileo 2.5.1 (Liter8, rootless) запущен на Basil через `apps.launch org.coolstar.SileoStore`: процесс жив на переднем плане, база создана, репозитории добавлены и распарсены.

- База: `/var/jb/var/mobile/Library/Caches/Sileo/Database/sileo.sqlite3` (200 704 Б, mobile:mobile, schema `user_version = 4`), таблица `Packages` — **1273 строки**.
- Кэш репозиториев: `/var/jb/var/mobile/Library/Caches/Sileo/{Downloads,Networking}` — баннеры и иконки репозиториев скачаны (сеть в госте работает).
- `dpkg-query -W` в `/var/jb` — 67 пакетов (вкладка Installed не пустая).
- Скриншот снять удалось (`basil_sileo.png`), но просмотреть его в этой сессии нельзя: модель без поддержки изображений. Визуально UI не подтверждён, подтверждено состоянием процесса и базы.

## Причина краша `Database Connection failed` и исправление

Путь к базе собирается в открытых исходниках (`Sileo/AppDelegate.swift`, `Evander/Networking/NetworkResolver.swift`, `Backend/Root Wrapper/CommandPaths.swift`, `Bootstrap.swift`):

```
CACHE_FORCE = .libraryDirectory
_cacheDirectory = CommandPath.prefix + FileManager.urls(for: .libraryDirectory, in: .userDomainMask)[0] + "/" + CFBundleName(без пробелов)
prefix = "/var/jb" если существует /var/jb/.procursus_strapped, иначе ""
база    = _cacheDirectory/Database/sileo.sqlite3
```

`createDirectory` идёт под `try?`, поэтому ошибка прав глотается, а следом `Connection(path)` падает с `fatalError("Database Connection failed")` — ровно тот стек, что был в краш-логах.

Ошибка была моя, в установщике `install_bs.py`: `putdir` делал только `files.mkdir` и не применял mode/owner из tar. В бутстрапе `/var/jb/Library` — `775 root:wheel`, у меня получился `755 root:root`, и mobile не мог создать в нём подкаталоги. Исправление: `putdir` теперь делает `files.chmod` + `files.chown` по tar; режим `DIRS_ONLY=1` применяет это без перекачки файлов:

```
DIRS_ONLY=1 python3 install_bs.py /tmp/jbresearch/bootstrap_1900.tar.gz var/jb /var/jb
```

Важно: strip-префикс обязательный (`var/jb`). Первый запуск с пустым strip создал вложенное дерево `/var/jb/var/jb/...` (446 каталогов) — удалено через `files.remove recursive`.

Замечание по факту: база оказалась в `/var/jb/var/mobile/Library/Caches/Sileo`, а не в `/var/jb/Library/Sileo`, как я сначала предположил: `urls(for:.libraryDirectory)` для процесса от mobile возвращает `/var/mobile/Library`, к нему спереди приклеивается `/var/jb`. Каталоги `/var/jb/var/mobile/...` Sileo создал сам.

## Что не работает / не проверено

- `setuid 4755` на `giveMeRoot` гостевой file API не ставит (остаётся 755) — действия от root из Sileo (установка/удаление пакетов) не проверялись.
- Procursus `uicache -p` на 27.2 не регистрирует (`Unable to register`); регистрация — через vphoned `system.uicache {directory:"/var/jb/Applications"}`.
- `uicache -u` LS-запись не снимает; `apps.uninstall` (IcliKit) unbundled-приложения не берёт.
- `processes.list` без фильтра обрезается до 200 процессов — Sileo в списке не было видно; искать с `{"filter":"Sileo"}`.
- Запуски Sileo через `proc.run` (bash/env) не умирают: процессы живут без UI в фоне (нашли 3 лишних по 18 МБ, убиты `kill -9` из bash). `processes.kill {signal:9}` требует `force:true`.

## Удобные факты про guest API

- `proc.run` env не передаёт; `PATH` в госте только `/usr/bin:/bin` — для Procursus явный путь `/var/jb/usr/bin/...` или `bash -c "export PATH=/var/jb/usr/bin:/var/jb/bin:$PATH; ..."`.
- `files.read {binary:true,offset,limit}` возвращает `content` (base64), `next_offset`, `total`, `truncated`.
- `processes.spawn` имеет allowlist (`launchctl`, `log`, `ps`), `timeout_ms` ≤ 10000; `log` у меня упал с `posix_spawn: No such file or directory`.

## Осталось в госте

- Procursus 1900 rootless в `/var/jb` (bash, dpkg 1.22.6, apt 2.9.4, uicache, launchctl) — рабочий инструмент.
- `/var/jb/Applications/Sileo.app` — зарегистрирован в LaunchServices, запускается.
- `/private/var/tmp/appender` — хелпер досылки файлов (используется `push_big.py`).
- Краш-логи Sileo в `/var/mobile/Library/Logs/CrashReporter/Sileo-*.ips` (5 шт., все до исправления).
