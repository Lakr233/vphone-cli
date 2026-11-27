# Скрытие признаков VM от приложений: kern.bootargs, hv_vmm_present, syscall 439

Дата: 2026-11-27. Тред BB «vphone антидетект» (`/Users/i_strelov/Projects/vphone/docs/threads/`).
Не публиковать: репозиторий публичный, origin чужой. Все адреса — Basil, iOS 27.2 (`24B119`),
kernelcache `kc.decomp` (boot N, 78 839 808 байт, MH_FILESET, база `0xfffffff007004000`).

## Что видит приложение (RootDetect на Basil, 2 / 44)

| Признак | Значение на Basil | Кто вносит |
|---|---|---|
| `kern.bootargs` | `serial=3 -v debug=0x2014e` | `IBootPatcher.bootArgs`, строка формата iBoot |
| `kern.hv_vmm_present` | `ENOENT` (sysctl нет) | патч переименования OID в пресете `extended` |
| `kern.Xv_vmm_present` | `1` | тот же патч |

Всё остальное (27 путей, 5 симлинков, 3 записи, fork, процессы, dyld) чисто: roothide скрывает.

## kern.bootargs: где живёт в ядре

Таблица sysctl в `__DATA_CONST`, имена — в `__PRELINK_TEXT`:

| Что | foff | Значение |
|---|---|---|
| cstring `bootargs\0` | `0x9aa5b` | одно вхождение во всём файле |
| `sysctl_oid` (имя) | `0xe3cfc0` | `oid_name -> bootargs` |
| `oid_fmt` | `0xe3cfd0` | `-> 'A'` (строка) |
| `oid_descr` | `0xe3cfd8` | `-> bootargs` |
| handler | `0xe3cfc8` | `0x41b9bac` (`__TEXT_EXEC`) |

Соседи по таблице — `kernelcacheuuid` (`0xe3d010`), `systemfilesetuuid` (`0xe3d060`), шаг `0x50`.

Handler `0x41b9bac` (дизассемблировано вручную):

```
ADRP x8 -> 0xfffffff007ea2000
LDR  x8, [x8, #0xd28]        ; слот 0xe9ed28 — &PE_state (runtime)
ADD  x1, x8, #0x6c           ; x1 = &PE_state.bootArgs
...
BL   sysctl_handle_string
```

То есть `kern.bootargs` — это `SYSCTL_STRING` над `PE_state.bootArgs` (смещение `0x6c` в `PE_state`).

## Почему файловo-патч не готов

Указатели в `__DATA_CONST` — `LC_DYLD_CHAINED_FIXUPS` (`dataoff 0x4b2c000`), `__DATA_CONST` —
`pointer_format 8`, `page_size 0x4000`. Декодер `target = raw & 0xfffffffff` (смещение от базы)
работает: 585 954 указателя, 18 346 ведут на читаемые строки, `bootargs` найден.

Но слоты `0xe3cfc8`, `0xe3cfe8` и `0xe9ed28` этим форматом не расшифровываются:
`0x8035db49_00e9d010` при `target:36` даёт `0x400e9d010` — вне файла. Это либо ptrauth-подписи,
которые ядро снимает при загрузке, либо иной формат для этих слотов. Слот `0xe9ed28` в файле
пуст (`target 0`), то есть `&PE_state` заполняется при загрузке — **буфер нельзя обнулить в файле**.

Вывод: для `bootargs` нужен код-патч (NOP на копирование в `PE_state.bootArgs` после
`early_init`, либо handler, возвращающий `""`). Без символов (`LC_SYMTAB` вырезан) — только
через дизассемблер. Живая проверка — `kcall10` (syscall 439), но по заметке `09_worse_query_escape`
один неверный адрес = паника и сломанная VM. На Basil нельзя.

## syscall 439 (kcall10)

`sysent[439].sy_call` по link-адресу `0x8ca7804` (заметка 13). Для файловo-патча нужно
перевести link → fileset координаты: `BASE + (link − 0xfffffe0008000000)`. Разница баз
(`0xfffffe0008000000` у XNU и `0xfffffff007004000` у fileset) — единственное место, где
ошибка даёт панику. Не сделано.

## hv_vmm_present → 0: уже сделано и откачено

Ветка `fix/bluetoothd-hv-vmm-cache`, коммиты `321650a`, `b37d196`: возврат 0 для всех
ломает `bluetoothd` (кэш → crash-loop → чёрный экран). Осталось только переименование OID.
Ничего нового писать не надо.

## Что не трогаем

Basil — только `apps.install` того же bundle id и `ui.tap_element`. Всё остальное — на клоне.
Клона нет: диска 34 ГБ, `cfw install` требует 50.
