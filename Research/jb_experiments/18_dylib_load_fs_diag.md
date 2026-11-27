# 18. Диагностика файловой системы и загрузка dylib через `DYLD_INSERT_LIBRARIES`

Дата: 2026-11-26. Тред `thr_itairhc6yq` (сабтред задачи jailbreak `thr_6vcmjuesnu`).

## 0. Что сделано в этом треде

В этом треде **ничего не запускалось**: ни на iPhone, ни на Basil, ни одна команда `devicectl`, ни одна сборка.
Тред получил задание и вернул в чат три фрагмента кода (перебор inode → путь, матрица доступа
`stat`/`open`/`opendir`, dylib с конструктором) и командную строку запуска. Дальше в заметке каждый факт
помечен одним из трёх источников: «написано в чате», «проверено на Mac по SDK / `--help` при подготовке
заметки», «найдено на диске после родительского треда».

## 1. Что было запрошено и что написано

Диагностический стенд: Debug-приложение UIKit с `get-task-allow`, запуск с Mac через
`xcrun devicectl device process launch --console`, построчный вывод в `UITextView` + `NSLog`.

| № | Фрагмент | Суть | Статус |
|---|---|---|---|
| 1 | `ScanInodePaths(dir)` | `statfs` → `fsid`; цикл `ino = 1..3 000 000`, на каждый `fsgetpath`; печатать `ino=<n> → <путь>` для путей с `Containers` или `mobile`; стоп после 40 совпадений | написан в чате, **не собран, не запускался**; содержит ошибки (раздел 2) |
| 2 | `ProbePaths(paths)` | для 7 путей: `stat`, `open(O_RDONLY)`, `opendir` (для каталогов); строка `<путь> → stat=<ok\|errno> open=<ok\|errno> opendir=<ok\|errno>` | написан в чате, **не собран, не запускался**; замечания (раздел 2) |
| 3 | `libprobe.c` | `__attribute__((constructor))` → `printf("LIBLOADED pid=%d exe=%s lib=%s\n")` через `_dyld_get_image_name(0)` и `dladdr`, `fflush(stdout)`; на диск не пишет | исходник совпадает с тем, что собрал и запустил **родительский тред** (раздел 4) |

Исходники: `tools/dylib_load_fs_diag/` — `fs_diag.m` (фрагменты 1 и 2 дословно из чата), `libprobe.c`,
`run1_parent_LIBLOADED.log`, `README.md`.

Пути матрицы (фрагмент 2): `/private/var/mobile/Library/Preferences`, `/private/var/mobile/Library/SMS`,
`/private/var/root`, `/private/var/keybags`, `/System/Library/Caches`,
`/private/var/mobile/Containers/Data/Application`, `/private/var/containers/Bundle/Application`.

## 2. Ошибки в написанных фрагментах

Найдены при подготовке этой заметки сверкой с iPhoneOS26.5.sdk (Xcode 26.6, 17F113); в чате отмечены не были.

**Фрагмент 1, `ScanInodePaths` — в таком виде не годится:**

1. **`fsgetpath` объявлен публично.** В SDK есть `<sys/fsgetpath.h>` (`__IOS_AVAILABLE(11.0)`), обёртка
   `dlsym(RTLD_DEFAULT, "fsgetpath")` не нужна.
2. **Неверная сигнатура.** В SDK: `ssize_t fsgetpath(char *, size_t, fsid_t *, uint64_t)`. Функция
   записывает путь в буфер и возвращает его длину. В чате был typedef `char *(*)(char *, uint32_t,
   const fsid_t *, uint64_t)` с комментарием «возвращает указатель на конец буфера» — это неверно:
   малое положительное значение длины интерпретировалось бы как указатель, разыменование → краш.
   Правильно: `ssize_t n = fsgetpath(buf, sizeof buf, &sb.f_fsid, ino); if (n > 0) { … }`.
3. **`fsid` — том data-контейнера.** `statfs(NSHomeDirectory())` даёт `fsid` тома, где лежат
   `/private/var/mobile/…` и `/private/var/mobile/Containers/…`. `/private/var/containers/Bundle/Application`
   — другой том, его inode в перебор с этим `fsid` не попадут. В чате это было утверждено неверно.

Рабочий аналог уже есть в репозитории: `tools/pathleak.m` (GPLv3, forcequit) и `wqprobe.m` с ним —
перебор inode по нему уже гонялся на обоих устройствах (`09_worse_query_escape.md`, `out_13.txt`, `out_17.txt`).

**Фрагмент 2, `ProbePaths` — замечания:**

- `ErrnoStr` читает `errno` уже после успеха соседнего вызова, поэтому errno достоверен только если между
  вернувшим ошибку вызовом и чтением ничего не вставили. Сейчас порядок вызовов это сохраняет, но хрупко:
  надо сохранять errno сразу (`int e = errno;`).
- `opendir` вызывается только когда `stat` вернул 0 и `S_ISDIR`. Для каталога, где `stat` упал,
  `opendir`-результат останется `-`, хотя сам `opendir` мог бы пройти. Для диагностической матрицы
  правильнее вызывать `opendir` для всех 7 путей безусловно.

**Фрагмент 3, `libprobe.c`:** ошибок не найдено.

## 3. Команды `devicectl`: что проверено, а что нет

| Команда / опция | Статус |
|---|---|
| `xcrun devicectl …` — любые | **ни одна не запускалась из этого треда** |
| `--console`, `-e` / `--environment-variables`, `--terminate-existing` | существуют в Xcode 26.6 — **проверено только по `--help` на Mac**, не прогоном |
| `-e '{"DYLD_INSERT_LIBRARIES":"…"}'` на железе | из этого треда **не проверено**; единственный прогон — родительский тред (раздел 4) |
| переменные с префиксом `DEVICECTL_CHILD_` в среде вызывающего процесса | альтернатива `-e` из `--help`; **не проверено** |
| путь `@executable_path/Frameworks/libprobe.dylib` | в чате; **не проверено** (в том единственном прогоне dylib лежала в корне бандла — `@executable_path/libprobe.dylib`) |

## 4. Что сделано с dylib (не в этом треде)

Найдено на диске, выполнял родительский тред; какое именно устройство — здесь неизвестно.

- **Исходник.** `/tmp/jbresearch/wq/libprobe.c`, 404 байта, 26.11 14:26 — совпадает с фрагментом 3 из чата.
  Копия: `tools/dylib_load_fs_diag/libprobe.c`.
- **Собрана: да.** Доказательство — вывод её конструктора в `/tmp/jbresearch/run1.log` (копия:
  `tools/dylib_load_fs_diag/run1_parent_LIBLOADED.log`), единственная строка:

  ```
  LIBLOADED pid=5259 exe=/private/var/containers/Bundle/Application/7F7BC40F-5FFE-4B64-8E03-B7B82B4FFC79/wqprobe.app/libprobe.dylib lib=/private/var/containers/Bundle/Application/7F7BC40F-5FFE-4B64-8E03-B7B82B4FFC79/wqprobe.app/libprobe.dylib
  ```

  Из строки следует: dylib лежала в корне бандла `wqprobe.app`, загрузилась в приложение и конструктор
  отработал до `main`. `_dyld_get_image_name(0)` для образа №0 вернул путь **dylib**, а не исполняемого
  файла: в этом процессе `dyld` сделал вставленную библиотеку образом 0, так что поле `exe=` в выводе
  фактического исполняемого файла не показывает.
- **Собранного `libprobe.dylib` на диске нет.** На момент заметки `find /tmp/jbresearch -name 'libprobe*'`
  находит только `.c`; в трёх `wqprobe.app` (`/tmp/jbresearch/dd/…`, `wq_x13/dd/…`, `wq_x17/dd/…`) его
  тоже нет — они пересобраны позже (16:16 и 21:09 / 21:36) без него. В `wq/project.yml` `libprobe` не
  включён. Как собирали и чем подписывали — неизвестно, повторить по оставшимся файлам нельзя,
  нужен новый прогон.

## 5. Что осталось недоделанным

1. Фрагменты 1 и 2 не собраны и не запущены: матрица доступа по 7 путям **не получена** ни на одном устройстве.
2. Фрагмент 1 нужно исправить (раздел 2, пункты 1–3) до любой сборки; либо взять `tools/pathleak.m`.
3. Перебор inode → путь по исправленному фрагменту не запускался; на железе известны только результаты
   `pathleak` из `09_…md` (17 Pro Max: 674 контейнера; iPhone 13: 0).
4. Загрузку `libprobe` нельзя воспроизвести: нет собранного dylib, неизвестны команда сборки, подпись,
   устройство и точная командная строка запуска. Для повтора: собрать заново (команда в
   `tools/dylib_load_fs_diag/README.md`), подписать тем же `Apple Development`, положить в бандл,
   запускать с `@executable_path/libprobe.dylib` — этот путь подтверждён выводом, а не `Frameworks/`.
5. `exe=` в выводе конструктора не показывает исполняемый файл; если нужно именно его имя — брать
   `_NSGetExecutablePath` или `_dyld_get_image_name(_dyld_image_count()-1)` с проверкой, а не образ 0.
6. Проверить на железе, что `-e` и `DEVICECTL_CHILD_` реально доносят переменную до процесса, этим тредом не проверено.
