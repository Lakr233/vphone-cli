# 35. nstat (`com.apple.network.statistics`) из app sandbox: досягаемость на iPhone 13 (23F84)

Дата: 2026-11-27. Объект: iPhone 13 (A15, iOS 26.5.2 / 23F84), физическое устройство. Пробник `tools/nstat_probe/` (bundle `me.strelov.nstatprobe`, team `25U9HN34VM`, wildcard-профиль; только `get-task-allow`, sandbox по умолчанию). Лог: `tools/kdiff2/out/nstat_out_23F84.txt`.

Зачем: в `27_kdiff_26_5_2_to_26_6_1.md` три изменённые в 26.6.1 функции `nstat_*` помечены «досягаемость не проверялась». Это его пункт 4.

## Результат (живой прогон)

| Шаг | Результат |
|---|---|
| `socket(PF_SYSTEM, SOCK_DGRAM, SYSPROTO_CONTROL)` + `ioctl(CTLIOCGINFO, "com.apple.network.statistics")` | 0, `ctl_id = 8` |
| `connect()` | 0 — **сокет открывается из sandbox без entitlement** |
| `ADD_ALL` (1002), провайдер 0 | `NSTAT_MSG_TYPE_ERROR`, errno 2 (ENOENT) |
| `ADD_ALL` (1002), провайдеры 1–5 | `NSTAT_MSG_TYPE_ERROR`, errno 1 (**EPERM**) |
| `ADD_ALL` (1002), провайдер 6 (`UDP_SUBFLOW`) | errno 45 (ENOTSUP) |
| `QUERY_SRC` (1004, `NSTAT_SRC_REF_ALL`) | `NSTAT_MSG_TYPE_SUCCESS`, 16 байт — данных нет: список источников клиента пуст |

Ответы читаются по `nstat_msg_error { nstat_msg_hdr hdr; u_int32_t error; }` (`ntstat.h:986`).

## Почему (по исходнику `xnu-12377.121.6`, `bsd/net/ntstat.c`)

- Контроллер зарегистрирован без `CTL_FLAG_PRIV` (`ntstat.c:5887`), поэтому `connect` проходит всем.
- На iOS `nstat_privcheck = 1` (`ntstat.c:97`; `#if !XNU_TARGET_OS_OSX`), и `nstat_client_handle_add_all` при этом всегда требует `PRIV_NET_PRIVILEGED_NETWORK_STATISTICS` (`ntstat.c:6899–6904`) — то, что вернуло EPERM. Провайдер 0 (`NSTAT_PROVIDER_NONE`) → ENOENT ещё до проверки (`:6890`).
- `ADD_SRC` (1001) — та же проверка для каждого провайдера (`ntstat_ifnet_add` `:4279`, `nstat_tcp_add`/`udp` — аналогично).
- `QUERY_SRC` (`:7078`) проверки не имеет, но обходит **только очередь источников данного клиента**. Без успешного `ADD*` очередь пуста — поэтому SUCCESS без данных. Добавленный в 23G83 блок в этой функции с чужого сокета не достижим.
- `SUBSCRIBE_SYSINFO` (`:7670`), `GET_DETAILS`-пути (`:8013`, `:8041`) — явный `priv_check_cred` → EACCES. `nstat_sysinfo_send_data` шлёт только подписчикам.

## Вывод

`nstat` для приложения из sandbox закрыт **привилегией, а не sandbox-профилем**: сокет и диспетчер сообщений доступны, но ни один путь, создающий источник или подписку, не проходит без `PRIV_NET_PRIVILEGED_NETWORK_STATISTICS`. Из трёх изменённых в 26.6.1 функций это закрывает только те, что работают с источниками/подписками (`nstat_ifnet_report_lim_stats` — отчёт по источнику, `nstat_sysinfo_send_data` — подписка). **`nstat_client_handle_query_request` из sandbox досягаем**: `QUERY_SRC` вернул `NSTAT_MSG_TYPE_SUCCESS`, то есть запрос дошёл до диспетчера и обработчика, а не был отвергнут (обработчик проходит по пустой очереди клиента и отвечает пустым списком). Какие ещё типы запросов он принимает и что делает с их телом — см. `39_nstat_query_request.md`.

Кандидат закрыт для 23F84 без root/entitlement. На 17 Pro Max не запускался: там по исходнику та же проверка (`nstat_privcheck` для всех не-macOS), а ядро 27.2.1 уже содержит эти правки.

## Попутные находки

- `sys/kern_control.h` в iOS SDK нет — `ctl_info`, `sockaddr_ctl`, `CTLIOCGINFO` объявлены в `main.m` локально.
- `[UIDDevice currentDevice]` и `fopen` из фонового `dispatch_async`-потока без окна сцены в этом каркасе дали тихий SIGSEGV и пустой лог; устойчивый вариант — `UIApplicationMain` + `dispatch_async` + `fdopen(open(...))`, без UIKit-вызовов из фонового потока.
- На iPhone 13 всё ещё установлен `necp_probe` соседа (`me.strelov.wqprobe`) — мой пробник под другим bundle id, его не затёр.

## IOHIDFamily: что установлено и где остановился (2026-11-27, статически)

Соседний тред сегодня показал (`07_iokit_reachability.md`): `IOHIDEventDriver` и `IOHIDEventService` открываются из app sandbox с type 2. Я проверял, что за user client стоит за type 2 и есть ли у него селекторы, досягаемые из приложения.

- По `_PrelinkInfoDictionary` кекста `com.apple.iokit.IOHIDFamily` (23F84): личность `IOHIDEventServiceUserClient` имеет `IOProviderClass = IOHIDEventService`; `IOHIDLibUserClient` — `IOHIDDevice` (тот закрыт NotPrivileged). То есть открытый с type 2 `IOHIDEventService` с высокой вероятностью **= `IOHIDEventServiceUserClient`** (по matching'у личности; подтвердить на устройстве не пробовал — селекторы не вызывались).
- `IOHIDEventServiceFastPathUserClient` — отдельная личность; провайдер не установлен.
- Vtable класса по указателям из `__DATA_CONST` раскодировать не удалось: формат chained-fixup для fileset-записей (`DYLD_CHAINED_PTR_64_KERNEL_CACHE`) у меня не декодируется, три эмпирические формулы не дали ни одного указателя в `__text`. Список external methods не получен. `dyld_info` kernelcache не читает.
- **Селекторы на устройстве не вызывались** (риск паники на ядре с кандидатом на OOB-write). Какой тип у `IOHIDEventServiceUserClient` и какие у него методы — открытый вопрос.

Что это значит для кандидата `GetElementValues` (CVE-2026-43739/43816): путь через `IOHIDDevice`→`IOHIDLib`→`IOHIDInterface::GetElementValues` закрыт (`IOHIDDevice` NotPrivileged, `IOHIDInterface` Unsupported). Путь «из приложения → `IOHIDEventServiceUserClient` (type 2)» — возможен, но не показан.

Незафиксированное: конкретные селекторы и структуры ввода `IOHIDEventServiceUserClient` type 2. Дифф `IOHIDEventServiceUserClient` 23F84→23G83 не смотрел.
