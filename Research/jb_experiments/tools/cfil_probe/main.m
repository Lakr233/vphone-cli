#import <UIKit/UIKit.h>
#include <stdio.h>
#include <unistd.h>
#include <string.h>
#include <errno.h>
#include <stdarg.h>
#include <sys/syscall.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <sys/ioctl.h>
#include <sys/sysctl.h>
#include <time.h>
#include <arpa/inet.h>
#include <stdint.h>
#include <stdlib.h>

#define FLAG_OBSERVER 0x01
// NECP_CLIENT_ACTION_* from xnu-12377.121.6 bsd/net/necp.h:620-638
#define ACT_ADD 1
#define ACT_REMOVE 2
#define ACT_ADD_FLOW 17
#define ACT_REMOVE_FLOW 18
#define ACT_CLAIM 19

static FILE *g_log;

static void L(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    vfprintf(g_log, fmt, ap);
    va_end(ap);
    fputc('\n', g_log);
    fflush(g_log);
}

static int open_necp(int flags) {
    return (int)syscall(501, flags);
}

static int do_act(int fd, uint32_t act, uint8_t *cid, size_t cidlen, uint8_t *buf, size_t len) {
    return (int)syscall(502, fd, act, cid, cidlen, buf, len);
}

// TLV: type u8, length u32 (packed); length counts the VALUE bytes only.
static uint8_t *tlv(uint8_t *p, uint8_t type, uint32_t len, const void *val) {
    *p++ = type;
    memcpy(p, &len, 4);
    p += 4;
    memcpy(p, val, len);
    return p + len;
}

// sys/kern_control.h is not in the iOS SDK: declare the three things needed (same layout as macOS).
struct sockaddr_ctl_kc {
    uint8_t sc_len; uint8_t sc_family; uint16_t ss_sysaddr; uint32_t sc_id; uint32_t sc_unit;
};
#define CTLIOCGINFO_kc _IOWR('N', 3, struct ctl_info_kc)
struct ctl_info_kc { uint32_t ctl_id; char ctl_name[96]; };
#define SYSPROTO_CONTROL_kc 2

static void connect_cfil(int unit) {
    errno = 0;
    int s = socket(PF_SYSTEM, SOCK_DGRAM, SYSPROTO_CONTROL_kc);
    int e = errno;
    L("socket(PF_SYSTEM, SOCK_DGRAM, SYSPROTO_CONTROL) -> %d errno=%d", s, e);
    if (s < 0) return;
    struct ctl_info_kc ci; memset(&ci, 0, sizeof ci); strlcpy(ci.ctl_name, "com.apple.content-filter", sizeof ci.ctl_name);
    errno = 0;
    int r = ioctl(s, CTLIOCGINFO_kc, &ci); e = errno;
    L("CTLIOCGINFO(com.apple.content-filter) -> %d ctl_id=%u errno=%d (%s)", r, ci.ctl_id, e, r ? strerror(e) : "OK");
    if (r) { close(s); return; }
    struct sockaddr_ctl_kc sa; memset(&sa, 0, sizeof sa);
    sa.sc_len = sizeof sa; sa.sc_family = AF_SYSTEM; sa.ss_sysaddr = 2 /* AF_SYS_CONTROL */; sa.sc_id = ci.ctl_id; sa.sc_unit = unit;
    errno = 0;
    r = connect(s, (struct sockaddr *)&sa, sizeof sa); e = errno;
    L("connect(com.apple.content-filter, unit=%d) -> %d errno=%d (%s)", unit, r, e, r ? strerror(e) : "CONNECTED");
    close(s);
}

static void run(void) {
    L("is root: uid=%d euid=%d", getuid(), geteuid());
    connect_cfil(1);
    // net.cfil.active_count = cfil_active_count (content_filter.c:783, CTLFLAG_RD, no privilege flag): number of registered filters.
    int mib[4]; size_t ac = sizeof(int); int val = -1;
    mib[0] = CTL_NET; mib[1] = PF_SYSTEM; mib[2] = 0; mib[3] = 0;
    size_t nm = 4; int ac2 = sysctlnametomib("net.cfil.active_count", mib, &nm);
    L("sysctlnametomib(net.cfil.active_count) -> %d mib=%d.%d.%d.%d n=%zu", ac2, mib[0], mib[1], mib[2], mib[3], nm);
    errno = 0;
    int q = sysctl(mib, ac2 ? 0 : nm, &val, &ac, NULL, 0); int qe = errno;
    L("sysctl(net.cfil.active_count) -> %d value=%d errno=%d (%s)", q, val, qe, q ? strerror(qe) : "OK");
    // Does a content filter see our TCP sockets? cfil_sock_attach() adds a pending entry and the data/out
    // queue waits for the filter's verdict (cfil_action_data_pass). If no filter is attached the send
    // returns immediately. This measures connect() and send() latency to a loopback listener we own.
    int lr = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in la; memset(&la, 0, sizeof la); la.sin_len = sizeof la; la.sin_family = AF_INET; la.sin_port = htons(0); la.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    bind(lr, (struct sockaddr *)&la, sizeof la); listen(lr, 4);
    socklen_t sl = sizeof la; getsockname(lr, (struct sockaddr *)&la, &sl);
    for (int k = 0; k < 3; k++) {
        int c = socket(AF_INET, SOCK_STREAM, 0);
        struct sockaddr_in ra = la;
        struct timespec t0, t1; clock_gettime(CLOCK_MONOTONIC, &t0);
        int cr = connect(c, (struct sockaddr *)&ra, sizeof ra);
        int a = accept(lr, NULL, NULL);
        int sr = send(c, "x", 1, 0);
        clock_gettime(CLOCK_MONOTONIC, &t1);
        long us = (t1.tv_sec - t0.tv_sec) * 1000000L + (t1.tv_nsec - t0.tv_nsec) / 1000;
        L("loopback tcp #%d: connect=%d accept=%d send=%d errno=%d elapsed=%ld us", k, cr, a, sr, errno, us);
        close(c); if (a >= 0) close(a);
    }
    close(lr);
    L("DONE");
}

@interface VC : UIViewController
@end
@implementation VC
- (void)viewDidLoad {
    [super viewDidLoad];
    UITextView *tv = [[UITextView alloc] initWithFrame:self.view.bounds];
    tv.autoresizingMask = 0x3f;
    tv.editable = NO;
    tv.font = [UIFont monospacedSystemFontOfSize:10 weight:UIFontWeightRegular];
    tv.textColor = [UIColor greenColor];
    tv.backgroundColor = [UIColor blackColor];
    self.view = tv;
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"out.txt"];
        g_log = fopen(path.fileSystemRepresentation, "w");
        L("iOS %s | %s | NECP probe start", UIDevice.currentDevice.systemVersion.UTF8String, UIDevice.currentDevice.model.UTF8String);
        run();
        L("DONE");
        fclose(g_log);
        NSString *txt = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
        dispatch_async(dispatch_get_main_queue(), ^{ ((UITextView *)self.view).text = txt; });
    });
}
@end

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property (strong) UIWindow *window;
@end
@implementation AppDelegate
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)x {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [[VC alloc] init];
    [self.window makeKeyAndVisible];
    return YES;
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, @"AppDelegate");
    }
}
