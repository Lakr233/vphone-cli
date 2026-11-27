# Выжимка из panic-логов Basil (24B119): слайд KASLR по загрузкам

Источник: копии `~/Library/Logs/vphone-launchpad/Basil.log`, снятые ДО перезапуска VM. Полные логи не переносятся:
в них ECID и UDID гостя. Регексы те же, что в `kslide.py --selftest`.

| лог | `lr` (сайт возврата из cave) | `slide = lr - 0xfffffe0008ca7850` | XNU `Kernel slide` (slide + 0x4000) |
|---|---|---|---|
| panicG.log | `0xfffffe004487f850` | `0x3bbd8000` | `0x3bbdc000` |
| panicH.log | `0xfffffe00309c7850` | `0x27d20000` | `0x27d24000` |
| panicI.log | `0xfffffe004532b850` | `0x3c684000` | `0x3c688000` |
| panicJ.log | — | — | — |
| panicK2.log | `0xfffffe0048477850` | `0x3f7d0000` | `0x3f7d4000` |
| panicL.log | `0xfffffe003f04f850` | `0x363a8000` | `0x363ac000` |
| panicM.log | `0xfffffe00324e7850` | `0x29840000` | `0x29844000` |

`panicM.log`: вызов по адресу `0xfffffe003550ea78`, набранному вручную с опечаткой (верный: `0xfffffe0032518a78`), fetch abort.
В этом же логе `lr` и `x8` едут на слайде `0x29840000`, совпадающем с `kslide.py` по VBAR (см. 13, раздел 1.1).

Без паники: boot N (26.11 22:11) — слайд `0x2ae6c000` по VBAR (`kslide.py`), подтверждён контрольным вызовом `r=1` и чтением `sysent[439].sy_call` = `0x8ca7804 + 0x2ae6c000`.

`panicN.log` (22:27, моя запись в `__DATA_CONST`): `pc = 0x8d1ecd8 + 0x2ae6c000`, `far = sysent + slide`, `esr 0x9600004f`
(write, permission fault level 3) — аргументы доставлены верно, отказала защита страницы. Слайд по `lr` `0x2ae70000` = XNU `Kernel slide`.

Boot O (22:28): слайд `0x3cde0000` по VBAR, контрольный вызов `r=1`, байты гейтов прежние.
