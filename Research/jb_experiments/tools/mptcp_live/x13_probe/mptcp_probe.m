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
