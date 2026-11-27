# 34 — Два кандидата 23F84 из заметки 27 закрыты по исходнику: IOHIDFamily и NECP

Дата: 2026-11-27. Только чтение: открытые исходники `apple-oss-distributions` и свои же
дизассемблеры. Ничего не собиралось, на устройства не ставилось, на серверах не запускалось.
Прошлое сообщение в чате и файл `33` по ходу работы были записаны испорченными; `33`
перезаписан, эта заметка написана заново.

## 0. Вывод

Оба «живых» кандидата заметки 27 на iPhone 13 / 23F84 не дают триггера из приложения:

| Кандидат | Что считалось (27) | Что показал исходник |
|---|---|---|
| `IOHIDInterface::GetElementValues` (IOHIDFamily) | в 23F84 провал проверки → пропуск элемента и продолжение цикла с «раздутым» итогом → запись за границу; в 23G83 — выход с ошибкой | это `continue` в **не выполняющейся** ветке: буфер `values` при пропуске не продвигается, `bcopy` не вызывается. Тело с `bcopy` — путь «влезло». Переполнения в 23F84 по этому листингу нет |
| `necp_client_qualify_flow` (NECP) | UAF-окно: `necp_find_flow_locked` отпускает лок дерева и держит сырой указатель `flow` | окно в коде есть, но единственный вызывающий — content filter через kernel control socket с `CTL_FLAG_PRIVILEGED`. Из app sandbox путь недосягаем; нужен root, чтобы его разбудить |

Итог по 26.6-CVE на 23F84: изменений в ядре много (249 функций), но два разобранных
кандидата — не memory-bug (IOHID) и не досягаемы (NECP). Прирост отрицательный.

## 1. IOHIDFamily: сверка `getelementvalues_23F84.dis` с `IOHIDInterface.cpp`

Исходник: `IOHIDFamily-2238.100.59` (2026-04-13) — последняя открытая выкладка; 26.5.2
соответствует примерно `IOHIDFamily-276.x` (не проверял по кексту), так что сверка
по структуре, а не построчно.

`IMPL(IOHIDInterface, GetElementValues)` (`IOHIDInterface.cpp:801-897`):

```c
md = OSDynamicCast(IOBufferMemoryDescriptor, elementValues);
values = (UInt8 *)md->getBytesNoCopy();
cookies = IONewData(IOHIDElementCookie, count);
for (i = 0; i < count; i++) {                      // цикл 1: собрать cookies
    header = (IOHIDElementValueHeader *)values;
    element = _deviceElements->getObject(header->cookie);
    valueSize = element->getByteSize();
    totalSize += sizeof(IOHIDElementValueHeader) + valueSize;
    __Require_Action(totalSize <= elementValues->getLength(), exit, ...);   // фатально
    cookies[i] = header->cookie;
    values += sizeof(IOHIDElementValueHeader) + valueSize;
}
ret = _owner->updateElementValues(cookies, count);
values = (UInt8 *)md->getBytesNoCopy();
totalSize = 0;
for (i = 0; i < count; i++) {                      // цикл 2: записать значения
    header = (IOHIDElementValueHeader *)values;
    element = _deviceElements->getObject(header->cookie);
    if (!element) { HIDLog(...); continue; }
    valueSize = element->getByteSize();
    totalSize += sizeof(IOHIDElementValueHeader) + valueSize;
    if (totalSize > elementValues->getLength()) {  // «не влезло»
        HIDLog(...);
        continue;                                  // ← пропустить, values НЕ двигается
    }
    bcopy(element->getDataValue()->getBytesNoCopy(), header->value, valueSize);
    values += sizeof(IOHIDElementValueHeader) + valueSize;
}
```

Соответствие листингу 23F84 (`0x969b508` … `0x969b670`):

| Код | 23F84 |
|---|---|
| `x20` = третий аргумент = `elementValues` (IOBufferMemoryDescriptor) | `mov x20, x2`; `OSDynamicCast` в прологе (`0x969b32c`) |
| `capacity = elementValues->getLength()` | `ldr x8,[vtable(x20)+0xb0]`, вызов в обоих циклах |
| `valueSize = element->getByteSize()` | `ldr x8,[vtable(elem)+0x250]` |
| «не влезло» → лог и `continue` | `cmp x0,x27 ; b.hs 0x969b604`; fallthrough: лог (`0x969b590…5d0`), затем `b 0x969b670` → `subs w26,#1 ; b.ne 0x969b508` |
| «влезло» → `bcopy` и `values +=` | `0x969b604`: `memcpy`, `add w19,w19,w22` (offset += size+8), `add x27,…` |
| `x23` = буфер `cookies` (выделен `count*4`) | `0x969b380` alloc, `0x969b39c` memset |

Открытые вопросы заметки 27 снимаются:

- **«`capacity` читается из `x20`, а пишется в буфер `x23`»** — разные объекты, и это правильно:
  `x20` — дескриптор пользовательского буфера (ёмкость), `x23` — временный массив cookies
  размера `count*4`, в него пишет только цикл 1, ровно по 4 байта на итерацию (`str w8,[x10]`,
  `x24 += 4`, `x24 < count*4`). Запись за границу `x23` не следует ни из кода, ни из листинга.
- **«при пропуске следующий элемент копируется со сдвинутым смещением»** — нет: `values`
  продвигается только вместе с `bcopy`, поэтому `header` всегда указывает на записанный
  ранее элемент, а `totalSize` — накопленная сумма по одним и тем же элементам. Смещение
  записи и проверка согласованы. Цикл 1 к тому же уже отбил любую нехватку ёмкости
  фатальным выходом, так что во второй цикл попадает только набор, который влезает.
- **Размер данных элемента из report descriptor** (`IOHIDUserDevice`) не придаёт: `getByteSize`
  элемента одинаков в обоих циклах, второй цикл его лишь повторно суммирует.

Что действительно изменилось в 23G83: ветка «не влезло» стала фатальным выходом
(`kIOReturnBadArgument`), как в цикле 1. Это ужесточение (defence in depth) либо фикс
иного класса (например, state/race в `updateElementValues`), но по листингу 23F84
out-of-bounds write в `GetElementValues` не видно.

Поправка к заметке 27: формулировка «запись выходит за пределы буфера» там неверна;
верно «в 23F84 пропуск с продолжением, в 23G83 — выход с ошибкой».

## 2. NECP: кто может дёрнуть `necp_client_qualify_flow`

`xnu-12377.121.6` (≈26.5, открыт), `bsd/net/necp_client.c`, `bsd/net/content_filter.c`.

Само окно (заметка 27) подтверждается по исходнику: `necp_find_flow_locked` (1082)
делает `RB_FIND` в глобальном дереве под shared-локом дерева, сохраняет `flow->client`
и `*found_flow = flow`, отпускает лок дерева и только затем берёт `NECP_CLIENT_LOCK(client)`.
Счётчика ссылок у `struct necp_client_flow_registration` (500–523) нет. Между
`NECP_FLOW_TREE_UNLOCK()` и `NECP_CLIENT_LOCK` регистрацию может удалить и освободить
`necp_client_remove_flow` (8743–8749) или ошибочная ветка `necp_client_add_flow`
(10289–10295) — оба идут от syscalls 501/502, доступных из sandbox.

Досягаемость второго участника:

| Звено | Где | Что требуется |
|---|---|---|
| `necp_client_qualify_flow` | `necp_client.c:13183` | — |
| единственный вызывающий | `content_filter.c:5132` `cfil_action_qualify_flow` | — |
| его вызывающий | `content_filter.c:2016`, обработчик `CFM_OP_QUALIFY_FLOW` | сообщение от процесса фильтра |
| сокет фильтра | `content_filter.c:55` — `kern_ctl.ctl_flags = CTL_FLAG_PRIVILEGED \| CTL_FLAG_REG_EXTENDED` | **привилегированный kernel control socket**: connect требует root (или entitlement `com.apple.private.network.content-filter`); из app sandbox закрыт |
| сами фильтры | iOS: Screen Time / родительский контроль, MDM web-content-filter, сторонние NE `NEFilterDataProvider` (они используют свой механизм, не обязательно cfil) | состояние на iPhone 13 не проверял |

Проверка: `grep -n necp_client_qualify_flow` по `xnu-12377.121.6` даёт ровно один
внешний вызов — `content_filter.c:5132`. Других путей разбудить гонку из приложения нет.

Вывод по NECP: UAF-кандидат остаётся **статическим**, без триггера из приложения. Он
становится интересным только после root (когда `CTL_FLAG_PRIVILEGED` уже не барьер) —
то есть как элемент пост-эксплуатации, а не входа.

## 3. Куда это ставит задачу

- На 23F84 из двух разобранных до конца кандидатов ни один не является входом.
- Оставшиеся направления без изменений: `nstat_*` (досягаемость не проверялась,
  обычно нужен `PRIV_NET_PRIVILEGED_NETWORK_STATISTICS`), AVE2 (по чужим работам на
  A18/A19 — паника без контролируемой записи), MPTCP CVE-2026-86962 (живой тест
  выполнен 26.11, `05` §22:45 — итог в заметке 22), CVE-2026-86916 (сайт не найден).
- Дешёвых непроверенных статических целей в ядре больше не осталось; следующий шаг —
  либо живой тест, либо новая идея снаружи.

## 4. Не проверено

- Соответствие версии открытого `IOHIDFamily` билду кекста в 23F84 — по структуре кода.
- Наличие активного content filter на iPhone 13 (Screen Time / MDM) — не смотрел.
- `necp_client_add_flow` (+27 инструкций в 23G83) — не разбирался.
- Сайт CVE-2026-86916 и `nstat_*` — не трогал.
