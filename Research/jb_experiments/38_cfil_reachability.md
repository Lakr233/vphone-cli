# 38. Content filter (`com.apple.content-filter`) из app sandbox: досягаемость на iPhone 13 (23F84)

Дата: 2026-11-27. Объект: iPhone 13 (A15, iOS 26.5.2 / 23F84), физическое устройство. Пробник `tools/cfil_probe/` (bundle `me.strelov.cfilprobe`, team `25U9HN34VM`, wildcard-профиль; только `get-task-allow`, sandbox по умолчанию). Лог: `tools/cfil_probe/out_13_23F84.txt`.

Зачем: `27` оставил кандидатом UAF в `necp_client_qualify_flow` (23F84: указатель на flow-регистрацию берётся из глобального дерева без удержания ссылки; в 23G83 добавлен счётчик `+0x58` с panic на underflow). Единственный вызов функции — `cfil_action_qualify_flow` (`content_filter.c:5132`), то есть нужен работающий content filter. «Состояние cfil на iPhone 13 я не проверял» — это его пункт.

## Результат (живой прогон)

| Шаг | Результат |
|---|---|
| `socket(PF_SYSTEM, SOCK_DGRAM, SYSPROTO_CONTROL)` | 4, errno 0 |
| `CTLIOCGINFO("com.apple.content-filter")` | 0, `ctl_id = 4` — сокет зарегистрирован |
| `connect(sc_unit = 1)` | **−1, EPERM** |
| `sysctl(net.cfil.active_count)` | −1, EPERM |

`uid=501 euid=501`.

## Что это значит

- **Поставить свой content filter из sandbox нельзя.** Сокет зарегистрирован с `CTL_FLAG_PRIVILEGED` (`content_filter.c:2633`), а `ctl_setup_kctl` (`kern_control.c:463`) при этом флаге требует `kauth_cred_issuser()`, иначе `EPERM`. Сам `cfil_ctl_connect` проверок не имеет: он бы принял любой `sc_unit` 1..8. То есть слот `content_filters[kcunit-1]` и отправка `CFM_OP_QUALIFY_FLOW` доступны только root. Флаг в бинарнике 23F84 я не сверял (xref на строку `com.apple.content-filter` по `adrp+add` не нашёлся), но живой `EPERM` совпадает с исходником.
- **Есть ли на устройстве чужой фильтр — не установлено.** `net.cfil.active_count` — это `cfil_active_count`, `CTLFLAG_RD` без флага привилегии (`content_filter.c:783`), поэтому `EPERM` даёт sandbox-профиль приложения, а не ядро.
- **Даже при чужом фильтре поток приложения попадает в него только по policy.** `cfil_sock_attach` (`content_filter.c:3017`) выходит сразу, если `necp_socket_get_content_filter_control_unit(so) == 0`; TCP отфильтровывается только при ненулевом unit. Какое приложение приложение-жертва получит такой unit — из sandbox не видно и не контролируется.
- Loopback TCP (`connect`+`accept`+`send`): 138–159 мкс, без ожидания вердикта. Это **не** доказательство отсутствия фильтра: loopback фильтр и так пропускает.

## Статус

Кандидат UAF `necp_client_qualify_flow`: **UAF-окно по исходнику есть (27), досягаемость с устройства не показана и из sandbox не открывается**. Триггер требует: (1) root для своего фильтра — закрыто; либо (2) чужой активный фильтр + policy, направляющая сокеты жертвы в него, + гонка `ADD_FLOW`×`REMOVE_FLOW` из приложения. Условие (2) на iPhone 13 не проверено; для проверки нужен сетевой поток вне loopback и способ увидеть `cfil_active_count` (root).

Инструмент: `tools/kdiff2/cfilreg.py <kc> <string> [kext]` — xref `adrp+add` на cstring (на этой строке не сработал).
