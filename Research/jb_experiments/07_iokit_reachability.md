# Достижимость IOKit-сервисов из app sandbox (iPhone 13 и 17 Pro Max)

Дата: 2026-11-26. Пробник `tools/iosvc.m`: `IOServiceGetMatchingService` → `IOServiceOpen` type 0/1/2 → close. Селекторы **не вызывались** (у IOMobileFramebuffer есть defensive panic на нулевом размере вывода). `inst` — число узлов под первым совпавшим сервисом (для ориентировки, не точное число инстансов). Сырой вывод — `iosvc_out.txt`.

| Сервис | iPhone 13, 26.5.2 | iPhone 17 Pro Max, 27.2.1 |
|---|---|---|
| `AppleJPEGDriver` | **открыт**, type 0/1/2 | **открыт**, type 0/1/2 |
| `IOMobileFramebuffer` | **открыт**, type 0/1/2 | **открыт**, type 0/1/2 |
| `IOSurfaceRoot` | type 0; 1/2 — `0xe00002c7` | type 0; 1/2 — `0xe00002c7` |
| `AGXAccelerator` | type 1; 0/2 — `0xe00002c7` | type 1; 0/2 — `0xe00002c7` |
| **`AppleKeyStore`** | **открыт**, type 0/1/2 | **открыт**, type 0/1/2 |
| `AppleAVE2Driver` | `0xe00002e2` NotPrivileged, все type | `0xe00002bd` (type 0), `0xe00002e2` (1/2) |
| `AppleAVD`, `AppleStockholmControl` | `0xe00002c1` sandbox deny | `0xe00002c1` sandbox deny |
| `AppleSPU`, `AppleConvergedPCI` | `0xe00002c7` | `0xe00002c7` (ConvergedPCI на 17PM не найден) |
| `AppleBaseband` | `0xe00002e2` | `0xe00002e2` |
| `AppleAVE2`, `AppleH16ANE`, `IOGPUFamily`, `AppleMesa`, `AppleSEP`, `AppleTorch`, `AppleH2CamIn/Out` и др. | не найдены по имени класса | не найдены по имени класса |

Коды: `0xe00002e2` = kIOReturnNotPrivileged, `0xe00002c1` = kIOReturnNotPermitted, `0xe00002c7` = kIOReturnUnsupported, `0xe00002bd` = kIOReturnBadArgument.

## Что из этого следует

1. **AppleAVE2 из sandbox недостижим на обоих устройствах.** Цепочка `Mac-XK/iOS27-Kernel-Primitives` (AppleAVE2 OOB write как основа, окно 27.0–27.1) неприменима из app sandbox; кроме того, она закрыта в 27.2, а 17 Pro Max на 27.2.1. Для iPhone 13 (A15) эти CVE и так вне диапазона (A19/t8150).
2. Результат совпадает с аудитом `flyingsquirrel0419/ios27-surface-audit` (iOS 27.2, iPhone 15 Pro): открытые из sandbox поверхности — IOSurfaceRoot, AGX, IOMobileFramebuffer, AppleJPEGDriver; ни утечки, ни LPE в них не найдено, CVE-2026-112477 опровергнут.
3. **`AppleKeyStore` открывается свободно.** В нём CVE-2026-65343 (`_LibSer_SEPControl_Deserialize`, OOB read → утечка указателя → KASLR), закрыт в 26.6.1. На iPhone 13 (26.5.2) — кандидат на проверку. `ios26-kernel-research` пишет про него «sandbox-blocked» — по `IOServiceOpen` это не так; возможно, блокируется на конкретном selector'е.
4. **Ядро 24B119 (Basil) и 24B156 (17 Pro Max) идентичны по коду** (по данным аудита: 1 920 изменённых байт, все — метаданные). Значит, Basil — точная модель ядра 17 Pro Max для отладки.

## Что не проверено

- Селекторы открытых сервисов (в `AppleKeyStore` в том числе) — следующий шаг.
- Список классов неполный: искал по именам, которые могли не совпасть с реальными именами классов (`AppleH16ANE`, `IOGPUFamily` — «не найдены» может означать другое имя, а не отсутствие).

## HID: кто открывается из app sandbox (добавлено 2026-11-27, iPhone 13 · 26.5.2 и 17 Pro Max · 27.2.1)

Пробник `tools/hid_probe/` (свой bundle id `me.strelov.hidprobe`; селекторы не вызывались, только `IOServiceOpen` type 0/1/2). Лог: `tools/kdiff2/out/hid_reach_x13.txt`. Оба устройства проверены 2026-11-27.

| Сервис | type 0 | type 1 | type 2 |
|---|---|---|---|
| `IOHIDDevice` (путь к `IOHIDDeviceUserClient`) | `0xe00002e2` NotPrivileged | `0xe00002e2` | `0xe00002e2` |
| `IOHIDInterface` | `0xe00002c7` Unsupported | `0xe00002c7` | `0xe00002c7` |
| `AppleHIDTransportHIDDevice`, `AppleSPUHIDDevice`, `IOHIDUserDevice`, транспортные bootloader/FIFO/management/interface | `0xe00002e2` | `0xe00002e2` | `0xe00002e2` |
| `IOHIDResource` | `0xe00002c2` BadArgument | `0xe00002c2` | `0xe00002c2` |
| `AppleHIDTransportProtocolSCMFIFO` | `0xe00002c7` | `0xe00002c7` | `0xe00002c7` |
| **`IOHIDEventDriver`** | `0xe00002c2` | `0xe00002c2` | **открыт** |
| **`IOHIDEventService`** | `0xe00002c2` | `0xe00002c2` | **открыт** |

17 Pro Max (27.2.1), тот же пробник, `tools/kdiff2/out/hid_reach_x17.txt`: всё то же, кроме двух последних строк — `IOHIDEventDriver` и `IOHIDEventService` type 2 → `0xe00002e2` NotPrivileged. То есть эта поверхность открыта на 26.5.2 и закрыта на 27.2.1; выпуск, в котором её закрыли, по двум точкам не определён.

Два факта: `IOHIDUserDeviceCreate` на iOS не линкуется (символа в `IOKit` нет) — виртуальное HID-устройство из приложения через публичный API не создать. `IOHIDDevice` для приложения возвращает NotPrivileged на всех типах, то есть `IOHIDDeviceUserClient` (и идущий через него `IOHIDInterface::GetElementValues`, правка 26.6) из sandbox недостижим.

**Не разобрано:** какие селекторы и структуры ввода у `IOHIDEventDriver` / `IOHIDEventService` с type 2 (актуально только для 26.5.2); это событийный путь, к `GetElementValues` отношения не имеет. В диффе 23F84 → 23G83 (заметка 27) функции этих классов менялись — сопоставить с их изменёнными функциями.

**Поправка к названиям кодов во всей заметке (thr_sxdgwvv7fc, 2026-11-27; сверено по `iokit/IOKit/IOReturn.h`, `xnu-12377.121.6`, копия `/tmp/jbresearch/xnu_iokit/iokit_IOKit_IOReturn.h`).** В строке «Коды» выше и в моём HID-разделе имена расставлены неверно; сами шестнадцатеричные значения во всех таблицах верны, менять надо только имена:

| Код | Правильно (`IOReturn.h`) | В заметке названо |
|---|---|---|
| `0xe00002e2` | `kIOReturnNotPermitted` | NotPrivileged |
| `0xe00002c1` | `kIOReturnNotPrivileged` | NotPermitted |
| `0xe00002bd` | `kIOReturnNoMemory` | BadArgument |
| `0xe00002c2` | `kIOReturnBadArgument` | верно |
| `0xe00002c7` | `kIOReturnUnsupported` | верно |

Выводы заметки от этого не меняются: везде, где стоит `0xe00002e2`, соединение не открыто.

Что закрылось с момента предыдущей записи: селекторы `IOHIDEventServiceFastPathUserClient` на 26.5.2 сняты живьём (thr_3wd87nkk3d, `05_open_questions_and_next.md` §02:20, §02:35; копия лога `tools/kdiff2/out/hidfp_classB_signatures_x13.txt`): ровно 3 скалярных метода, все на одном флаге `+0x108`, `sel1` возвращает 0 без активации, буферной поверхности нет — примитива нет, кандидат закрыт. На 27.2.1 отказ `0xe00002e2` даёт sandbox/MACF в `is_io_service_open_extended` (строки 4404–4405 либо 4563–4566 исходника), а не свойство `IOUserClientEntitlements` (та ветка дала бы `0xe00002c1`); какая из двух sandbox-веток — не установлено, нужен syslog.

**Уточнение к предыдущему абзацу (thr_sxdgwvv7fc, 2026-11-27).** Формулировка «`sel1` возвращает 0 без активации» объясняет больше, чем доказано. Доказано живьём: `sel0` → ExclusiveAccess, `sel1` → `0x0`, сразу после него `sel2` → NotOpen, селекторы 3–11 → BadArgument, в таблице ровно 3 скалярных метода. Доказано по коду (thr_3wd87nkk3d, `05` §04:00, §04:20): `sel0` и `sel2` читают флаг `+0x108`, ставит его только внутренний callback сервиса, сбрасывает `clientClose` при закрытии или смерти клиента. Обработчик `sel1` по файлу не найден; отождествление его с `0x96c79b0` и объяснение результата отсутствием свойств события сняты. Вывод тот же: после `sel1` флаг не установлен, fast-path не активирован, примитива нет.
**Вторая оговорка к двум предыдущим абзацам (thr_sxdgwvv7fc, 2026-11-27; поправка thr_3wd87nkk3d, `05` §06:10).** Класс клиента в том прогоне **не подтверждён**: пробник `hidfp` открыл первый экземпляр `IOHIDEventService`, принявший `IOServiceOpen(type=2)` (по логу `AppleARMPMUPowerSensor`), и имени класса соединения не читал. Коды (`sel0` ExclusiveAccess, `sel1` → `0x0`, сразу за ним `sel2` NotOpen, 3–11 BadArgument) — факты; то, что их дал именно `IOHIDEventServiceFastPathUserClient`, следует из статики, а не из измерения. «Закрыт» здесь означает «примитив не получено в этом прогоне», а не «поверхность класса B прощупана». Проверка — новый прогон с чтением класса через `IOServiceCopyService(c)`; без разрешения владельца не делался.
