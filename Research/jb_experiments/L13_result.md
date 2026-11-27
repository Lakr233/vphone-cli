# L13-aio — освобождается ли `aio_workq_entry` до выдачи `EVFILT_AIO` (iPhone 13, iOS 26.5.2 / 23F84)

Дата: 2026-11-26. Устройство: iPhone 13 (A15), devicectl `4A8A1186-3B54-5E76-95C0-3E47590416B9`, iOS 26.5.2 (23F84) — единственное устройство в тесте.
Режим: только легальные вызовы (`aio_read`, `aio_error`, `aio_return`, `kevent64`), без spray, без controlled-deref, запуск без `--console`.

Файлы:

| что | путь |
| --- | --- |
| исходник пробника | `/tmp/jbresearch/wq_x13/aio_freed_probe.m` (174 строки; добавлен в `project.pbxproj`, id `BB13A10F0000000000000031` / `…32`) |
| лог устройства | `/tmp/jbresearch/wq_x13/out_L13-aio.txt` (190 строк, 25170 байт) |
| лог после отката на `aio_probe_run()` | `/tmp/jbresearch/wq_x13/out_restore_check.txt` |
| kernelcache | `/tmp/jbresearch/ipsw/x13/kc.decomp/kernelcache.release.iphone14.decompressed` |
| вспомогательные скрипты | `/tmp/jbresearch/igmp/{adc.py,blcallers.py,atomics.py,peek.py}` |

`/tmp` очищается при перезагрузке: исходник, лог и скрипты сохранены только там.

## 0. Итог

**Ответ (a): событие одинаково с освобождениями и без них.**

| | значение |
| --- | --- |
| повторностей | 20 с освобождениями (`FREE`) + 20 контрольных (`CTRL`) |
| событий `EVFILT_AIO` получено | 40 из 40 (`n=1`), ни одного таймаута |
| различных шаблонов события | **1**, одинаковый в `FREE` и `CTRL` |
| `ext[1] == 0x200` (значение B) | 0 из 40 |
| шаг 5 (50 повторов) | не запускался: условие `(3)≠(4) или ext[1]==0x200` не выполнено, строк `[FREE50` в логе 0 |
| освобождено записей | 7 за повтор × 20 = 140 (`aio_return` по каждой B) |
| краш / паника | нет, процесс дошёл до `DONE` |

Единственный шаблон события, 40 раз подряд:

```
n=0x1 ident=0x100b5b268 filter=0xfffd flags=0x1035 fflags=0x00000001 data=0x0 udata=0x4141
ext0=0x0 ext1=0x100 | xferred=0x100 bufA[0..7]=4142434445464748
```

Сопоставление полей с исходниками xnu (`bsd/kern/kern_aio.c`, `bsd/kern/kern_event.c`) — интерпретация, не наблюдение: `filter=0xfffd` = `EVFILT_AIO` (−3); `flags=0x1035` = `EV_ADD|EV_ENABLE|EV_CLEAR|EV_ONESHOT|EV_KERNEL`; `fflags=1` = `AIO_COMPLETED`; `ext[1]=0x100` — `returnval` A (прочитано байт), `ext[0]=0` — `errorval`; `udata=0x4141` — `sigev_value`; `ident` — адрес `aiocb` A.

## 1. Что делал пробник (по шагам плана)

1. A = `aio_read` 0x100 байт из файла 0x1000 байт (паттерн `0x41+i%26`), `SIGEV_KEVENT` на свежий kqueue, `sigev_value=0x4141`. Ожидание `aio_error(A)==0`. `kevent64` не вызывался.
2. Только в `FREE`: 8 запросов B, `SIGEV_NONE`, `aio_nbytes=0x200`; все выпущены, затем ожидание завершения и `aio_return` каждой (освобождает запись). `B[7]` каждый раз отклонялась с `EAGAIN` (§3).
3. Один `kevent64(kq, NULL, 0, &ev, 1, 0, 100 ms)`, печать всего события в hex.
4. Контроль: (1)+(3) без (2), 20 повторов.
5. Не понадобился.

Лог писался в контейнер приложения; перед каждым `kevent64` — `fsync(1)`.

## 2. Наблюдения на устройстве

| № | Наблюдение | Где проверить |
| --- | --- | --- |
| 1 | `aio_read(A)=0`, после ожидания `aio_error(A)=0` во всех 40 повторах | строки `step1 … aio_read=0x0 wait=0x0 aio_error(A)=0x0` |
| 2 | Выпущено и освобождено по 7 B, `aio_return` каждой = 0x200 | `[FREE  rep 0x00] step2 issued=0x7 freed=0x7 per-B aio_read/wait/aio_return: 0x0/0x0/0x200 … ×7 0xffffffff/0xffffffff/0x0` и ещё 19 таких строк |
| 3 | `B[7]`: `aio_read errno=0x23` (EAGAIN) в 20 из 20 | `[FREE  rep 0x00] step2 B[7] aio_read errno=0x23` и далее |
| 4 | `kevent64` вернул одно событие в 40 из 40 | `grep -c "step3 n=0x1" out_L13-aio.txt` → 40 |
| 5 | Поля события `filter=0xfffd flags=0x1035 fflags=0x00000001 data=0x0 udata=0x4141 ext0=0x0 ext1=0x100` одинаковы в `FREE` и `CTRL` | 40 строк `step3 n=0x1 …`; в таблицах `[FREE ]   0x14 x …` и `[CTRL ]   0x14 x …` ровно по одному шаблону |
| 6 | `ident=0x100b5b268` во всех 40 = адрес статического `aiocb` A | `step1 … &A=0x100b5b268` |
| 7 | Данные прочитаны: `xferred=0x100`, `bufA[0..7]=4142434445464748` | те же строки `step3` |
| 8 | После события `aio_error(A)=-1 errno=0x16` (EINVAL), `aio_return(A)=-1 errno=0x16` | хвост строки `step3` |
| 9 | Процесс завершился штатно: `RESULT: a`, `poc_iogpu_uaf_run -> 0`, `DONE` | строки 188–190 |
| 10 | Отчёта о краше/панике за время запуска нет: последний `wqprobe-*.ips` — `wqprobe-2026-11-26-180710.ips`, запуск теста — 20:23 | `xcrun devicectl device info files --device 4A8A1186-… --domain-type systemCrashLogs` |
| 11 | `L13-aio compare: patterns_differ=0x0 saw_ext1_eq_0x200=0x0` (строка 187), `L13-aio RESULT: a (differ=0x0 saw_b_value=0x0)` (строка 188) | `sed -n '187,190p' out_L13-aio.txt` |

## 3. Побочное наблюдение: 8 живых записей AIO на процесс

7 из 8 запросов B прошли, 8-й получил `EAGAIN` в 20 повторах из 20. Запись A в этот момент завершена, но ещё не возвращена через `aio_return`. То есть лимит — 8 «живых» (не возвращённых) записей на процесс. Имя переменной (`aio_max_requests_per_process`, проверка `procp->p_aio_total_count >= aio_max_requests_per_process` в `aio_try_proc_insert_active_locked`) — из исходников xnu, на устройстве не проверялось.

## 4. Статический анализ 23F84 (Darwin 25.5.0, `xnu-12377.122.8~1`)

Адреса — в образе `kernelcache.release.iphone14.decompressed`. Символов в файле нет; все метки ниже подтверждены содержимым кода, сверкой с `bsd/kern/kern_aio.c` из xnu-12377.121.6 (структура `aio_workq_entry`: `+0x20 returnval`, `+0x28 errorval`, `+0x2c aio_refcount`, `+0x30 flags`, `+0x40 uaiocbp`; константы: `AIO_COMPLETED=0x100`, `EV_KERNEL=0x1000`, `EV_ERROR=0x4000`, `ENOTSUP=0x2d`, `EPERM=0x1`).

### 4.1. Пять операций фильтра `aio_filtops`

| поле | адрес | чем подтверждено (инструкция в бинарнике) |
| --- | --- | --- |
| `f_process` | `0xfffffff00a2baa6c` | PAC-чтение `kn_hook` (knote+0x28, дискриминатор `0x4f71`), при `kn_fflags!=0`: `kn_ext[0] ← entry+0x28`, `kn_ext[1] ← entry+0x20`, `knote_fill_kevent`, `bl aio_proc_remove_done_locked` @ `0xfffffff00a2bab3c`, `ldaddl -1` на `entry+0x2c` @ `0xfffffff00a2bab5c` |
| `aio_proc_remove_done_locked` | `0xfffffff00a2babcc` | TAILQ-удаление, `ldadd -1` по глобальному счётчику `0xfffffff00a8d1098`, `p_aio_total_count--` (`proc+0x47c`), panic-строки `…/kern_aio.c` с номерами строк 0x1de/0x1e1 |
| `aio_free_request` | `0xfffffff00a2bacbc` | проверки связей `+0x18`/`+0x8`, снятие ссылки на карту (`+0xa0`), освобождение `context`, panic-строка `aio_workq_entry %p being freed while still enqueued` (`0xfffffff00708828b`, строка 0x7f7) @ `0xfffffff00a2bad74` |
| `f_touch` | `0xfffffff00a2bad80` | `kev->flags \|= 0x4000` (EV_ERROR), `kev->data = 0x2d` (ENOTSUP), `return 0` |
| `f_event` | `0xfffffff00a2bada0` | PAC-чтение `kn_hook`, NULL → 0; тест `entry+0x31` bit 0 (флаг 0x100 = `AIO_COMPLETED`); `kn+0x50 \|= hint`; `return 1` (FILTER_ACTIVE) |
| `f_detach` | `0xfffffff00a2badf8` | PAC-чтение `kn_hook`, удаление knote из `aio_klist` (голова `0xfffffff00a97b930`) под `aio_klist_lock` (`0xfffffff00a97b928`), затем **`ldaddl -1` на `entry+0x2c` @ `0xfffffff00a2baeac`** → `aio_free_request` при нуле |
| `f_attach` | `0xfffffff00a2baf38` | gate `EV_KERNEL` (bit 12), `kev->flags &= ~EV_KERNEL`, `kn_flags \|= 0x20` (EV_CLEAR), PAC-запись entry в knote+0x28 (`pacda` @ `0xfffffff00a2bafb0`), **`ldadd +1` на `entry+0x2c` @ `0xfffffff00a2bafc8`**, привязка knote к `aio_klist` под `aio_klist_lock` |
| `aio_return` (сисколл) | `0xfffffff00a2bd6d8` | проход по спискам `proc+0x5d0`/`+0x5e0`, сравнение `entry+0x40` (`uaiocbp`) с пользовательским указателем, `*retval ← entry+0x20`, иначе `EINVAL` (0x16) / `EAGAIN` (0x24); `ldaddl -1` на `entry+0x2c` @ `0fffffff00a2bd808` |
| `_aio_exit` | `0xfffffff00a2bd8ac` | отменяет всё, ждёт активные, снимает done-очередь, `ldaddl -1` @ `0xfffffff00a2bd9f4` |
| завершение (`do_aio_completion_and_unlock`) | `0xfffffff00a2bb580` | перенос записи из active (`proc+0x5d0`) в done (`proc+0x5e0`), `entry->flags \|= hint` (`+0x30`), `KNOTE(aio_klist, 1)` @ `0xfffffff00a2bb7cc`, `ldaddl -1` на `entry+0x2c` @ `0xfffffff00a2bb854` и на лидере lio @ `…bb870` |

Таблица `aio_filtops` в `__DATA_CONST` не расшифрована: `dyld_info -fixups` падает на этом файле, указатели аутентифицированы. Метки получены по содержимому функций, не по таблице.

### 4.2. Что это даёт

В 23F84 knote держит **ссылку** на запись с момента `filt_aioattach` (`ldadd +1` @ `0xfffffff00a2bafc8`) и снимает её только в `filt_aiodetach` (`ldaddl -1` @ `0xfffffff00a2baeac`) либо в `filt_aioprocess` после заполнения события (`ldaddl -1` @ `0xfffffff00a2bab5c`). Поэтому `aio_return` (сисколл) по SIGEV_KEVENT-записи снимает лишь одну из ссылок и не освобождает запись, пока knote жив.

Счётчик ссылок в бинарнике настоящий: после `ldaddl -1` старое значение 0 уходит в panic (`bl 0xfffffff00a6290e8` → строка `os_refcnt: expected release of final reference but rc %p!=0` @ `0xfffffff0070a986d`, файл `refcnt.c`), значение 1 — в `aio_free_request` (`bl 0xfffffff00a2bacbc` @ `0xfffffff00a2bd878`).

## 5. Выводы (инференции, не наблюдения)

1. В последовательном сценарии (шаги 1–3 плана) событие `EVFILT_AIO` на 23F84 читается из **живой** записи A. Основание: 40/40 событий несут поля A (`ext[1]=0x100`, `ident=&A`), ни разу — значение B (`0x200`).
2. Причина — ссылка из knote: `filt_aioattach` удерживает запись, `filt_aioprocess` читает её поля до `aio_entry_unref`. Это подтверждено дизассемблером (§4), а не только исходниками.
3. Гипотеза донора — **гонка**, а не последовательный сценарий: в `Sources/Legacy/aio_kevent_rw.c` и `VULNS.txt` §8.24 FREE = `aio_return()` по **самой kevent-записи** из потока-рейсера, DEREF = `kevent64()` из главного потока, root cause — `lio_listio()` регистрирует kevent **после** постановки работы. Мой тест эту гонку не воспроизводит: в нём `aio_return` делается по другим (SIGEV_NONE) записям, а kevent-запись A не возвращается до `kevent64`. Поэтому мой результат **опровергает только последовательную форму** гипотезы «событие читается из освобождённой записи», но не доказывает отсутствие UAF при `lio_listio` + `aio_return`-гонке.
4. При этом статика показывает, что и при гонке запись удерживается knote: `aio_return` по SIGEV_KEVENT-записи не освобождает её (§4.2). Это согласуется с пометкой донора «Fixed: iOS 26.3 (xnu-12377.81.4)» (`VULNS.txt` строка 1193) — 23F84 (`xnu-12377.122.8`) новее. Но это вывод из дизассемблера и чужой пометки; на устройстве гонка не проверялась.
5. Освобождение B подтверждено только косвенно (поведение `aio_return` по исходникам и `ldaddl -1` в сисколле); прямого подтверждения через аллокатор нет, так как spray и controlled-deref запрещены.
6. Ранние метки из моих рабочих записей (`0xfffffff00a2bd8ac` как `filt_aioprocess`, `0xfffffff00a2baa6c` как `aio_return`) **ошибочны**; верные — в §4.1.

## 6. Ограничения

- Проверен только последовательный сценарий, предписанный планом L13-aio.
- Шаг 2 освобождал 7 записей, а не 8 (лимит на процесс).
- Таблица `aio_filtops` не расшифрована (см. §4.1); метки — по содержимому функций.

## 7. Состояние после теста

- `wqprobe.m` возвращён к `aio_probe_run()` (строка 34); отличается от образца `/tmp/jbresearch/wq2/wqprobe.m` только строкой 10 `void aio_freed_probe_run(void);`. Пересобрано (`** BUILD SUCCEEDED **`), переустановлено, контрольный запуск дал исходный лог (`out_restore_check.txt`: `kevent64(wait 100ms) -> n=1 … ext1=0x100`, `DONE`).
- Добавленный файл исходников: `aio_freed_probe.m` (и его регистрация в `project.pbxproj`).
- За пределами `/tmp/jbresearch/wq_x13` (и этой заметки) ничего не менялось; веток и коммитов нет.

## 8. Следующий шаг

Чтобы закрыть вопрос по существу, нужен тест **самой гонки донора**, а не последовательная форма:

1. `lio_listio` (или `aio_read` с `SIGEV_KEVENT`) — kevent-запись E1; поток-рейсер делает `aio_return(E1)` сразу после `aio_error(E1)==0`, затем 8 `aio_read` SIGEV_NONE с `aio_nbytes=маркер` (LIFO-reclaim); главный поток ждёт завершения и делает `kevent64`. Критерий: `ext[1] == маркер` (HIT) / событие не пришло (SILENT) / паника. Это ровно сценарий `aio_kevent_rw.c`, он включает spray/reclaim и потому выходит за рамки ограничений L13 — запускать только по отдельному решению.
2. Без устройства: найти `lio_listio` в 23F84 (в `__DATA_CONST` таблицы `aio_filtops` нет, функция не локализована; ближайшее — `aio_try_enqueue_work_locked` @ `0xfffffff00a2bc250`: лимит → `EAGAIN`, `is_already_queued`, `ldadd +1` по `entry+0x2c` @ `0xfffffff00a2bc350` и по лидеру lio @ `…bc324`, постановка в очередь либо `ldaddl -1` @ `…bc3b0`) и проверить по дизассемблеру порядок «`aio_register_kevent` после постановки» и что ссылка из knote держится на этом интервале. Это статическая проверка.
