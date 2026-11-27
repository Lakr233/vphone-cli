# KASLR-утечка на iPhone 13 (26.5.2, 23F84) и iPhone 17 Pro Max (27.2.1, 24B156): проверка CVE-2026-65405

Дата: 2026-11-26. Оба устройства разблокированы, приложение установлено и запущено на каждом (`devicectl … --console`). Полный вывод — `kprobe_13.txt`, `kprobe_17.txt`. Пробник — `tools/kprobe.m` (это версия без дампов; запущенная версия дополнительно печатает `DUMP <api> flavor=<n> bytes=<n>:<hex>` — 64 байт хвоста после объявленного размера).

| | iPhone 13 | iPhone 17 Pro Max |
|---|---|---|
| Вызовов с данными (`rc=0`, size>0) | 36 | 36 |
| Дампов буферов | 34 | 34 |
| Похожих на адрес ядра, любой сдвиг, 8 и 4 байта | **0** | **0** |
| Не-`0xAA` байт в хвосте за размером | 0 | 0 |
| `proc_info`: `EPERM` (sandbox) / `EINVAL` | 6 / 60 | 54 / 60 |

## Что проверялось

Два прохода в буферы, заполненные `0xAA`, побайтное сравнение. Диапазон адресов ядра: `0xfffffff000000000…0xfffffff0ffffffff` (A15) и `0xfffffe0000000000…0xfffffe00ffffffff` (A19).

| API | Flavors | Вызовов с данными (`rc=0`, size>0) |
|---|---|---|
| `host_info` | 1–20 | 6 |
| `host_statistics` | 1–20 | 4 |
| `host_statistics64` | 1–20 | 6 |
| `task_info` | 1–20 | 14 |
| `host_processor_info` | 1–20 | 2 |
| `proc_info` (callnum 1–20, flavor 1) | — | 3 (`callnum` 2/3/4 при flavor 11 — см. оговорку) |
| `processor_info(PROCESSOR_NULL)` | 1–20 | 0 (`KERN_INVALID_ARGUMENT`) |

## Результат

- `SUMMARY 0 kernel-range hits, 0 varying`.
- Офлайн-анализ 34 дампов: **0** значений, похожих на адрес ядра, при любом сдвиге (0–7 байт) и в 8-байтовом, и в 4-байтовом виде (`0xfffffff0`/`0xfffffe00` как старшие полусловa не встречаются ни разу).
- Хвост за объявленным размером (64 байта) после вызова — сплошной `0xAA`: ядро не дописывает данных за пределами структуры, неинициализированных остатков нет.

## Что этим не проверено

- `proc_info` flavor 2–10, 12–20 по callnum 2 (`PROC_INFO_CALL_PIDINFO`): `errno=1 Operation not permitted` — отказ sandbox, не результат. Проверить можно только с sandbox escape (`worse_query` — см. `04_public_exploit_landscape.md`).
- `processor_info` с валидным `processor_t` — нужен `host_processors()` (приватный MIG).
- Flavors выше 20 и размеры, отличные от 16K: CVE-2026-65405 описан Apple как «определение раскладки памяти ядра», публичного PoC нет, точная точка входа неизвестна.
- На 17 Pro Max `proc_info` блокируется sandbox шире (54 `EPERM` против 6 на iPhone 13): flavors 1–6 по `PROC_INFO_CALL_PIDINFO` на iOS 27 из app sandbox недоступны вовсе.

## Вывод

На 23F84 и на 24B156 проверенные точки входа чистые (для 24B156 это ожидаемо: CVE закрыт в 26.7). Утечка KASLR через `host_info`/`host_statistics{,64}`/`task_info`/`host_processor_info` в flavors 1–20 **не подтверждена**. Это не доказательство отсутствия CVE-2026-65405 на этом билде: точка входа неизвестна, а `proc_info` заблокирован sandbox.

Следующий шаг по этому направлению — после получения sandbox escape повторить `proc_info`-часть, либо найти описание CVE-2026-65405 у STAR Labs (у автора `ios26-kernel-research` «probe pending», точка входа тоже не установлена).
