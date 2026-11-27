#import <UIKit/UIKit.h>
#include <stdio.h>
#include <unistd.h>
#include <string.h>
#include <errno.h>
#include <stdarg.h>
#include <sys/syscall.h>
#include <netinet/in.h>
#include <sys/socket.h>
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

static void run(void) {
    int e;
    uint8_t buf[512];
    uint8_t cid[16];
    memset(cid, 0, sizeof cid);

    errno = 0;
    int fd = open_necp(0);
    e = errno;
    L("necp_open(0) -> fd=%d errno=%d (%s)", fd, e, fd >= 0 ? "OK" : strerror(e));
    errno = 0;
    int fdo = open_necp(FLAG_OBSERVER);
    e = errno;
    L("necp_open(OBSERVER) -> fd=%d errno=%d (%s)", fdo, e, fdo >= 0 ? "OK" : strerror(e));
    if (fdo >= 0) {
        close(fdo);
    }
    if (fd < 0) {
        L("RESULT: necp-open DENIED from app sandbox");
        return;
    }

    // minimal client: remote address 1.2.3.4:443 (necp_policy_condition_addr)
    uint8_t addr[6];
    addr[0] = AF_INET;
    addr[1] = 0;
    addr[2] = 1;
    addr[3] = 2;
    addr[4] = 3;
    addr[5] = 4;
    uint8_t *p = buf;
    p = tlv(p, 13, sizeof addr, addr);   // REMOTE_ADDR
    p = tlv(p, 10, 4, (uint32_t[]){0});  // TRAFFIC_CLASS
    size_t len = (size_t)(p - buf);

    errno = 0;
    int r = do_act(fd, ACT_ADD, cid, sizeof cid, buf, len);
    e = errno;
    L("ACTION_ADD (len=%zu) -> ret=%d errno=%d (%s)", len, r, e, r == 0 ? "OK" : strerror(e));
    if (r != 0) {
        close(fd);
        return;
    }
    L("client_id = %02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
      cid[0], cid[1], cid[2], cid[3], cid[4], cid[5], cid[6], cid[7], cid[8], cid[9],
      cid[10], cid[11], cid[12], cid[13], cid[14], cid[15]);
    // ADD_FLOW with flags=0 (no nexus, so no content-filter path): create a flow registration, then REMOVE_FLOW it.
    // struct necp_client_add_flow: agent_uuid[16] registration_id[16] flags:u16 stats_request_count:u16 (36 bytes), then TLVs.
    // The kernel writes the new registration_id back into the same buffer; REMOVE_FLOW takes it as the "client_id" argument.
    uint8_t fb[512];
    memset(fb, 0, 36);
    uint8_t *q = fb + 36;
    q = tlv(q, 13, 6, addr);                        // REMOTE_ADDR 1.2.3.4
    q = tlv(q, 11, 2, (uint16_t[]){IPPROTO_TCP});  // IP_PROTOCOL
    q = tlv(q, 221, 1, (uint8_t[]){IPPROTO_TCP});   // TRANSPORT_PROTOCOL
    size_t flen = (size_t)(q - fb);
    errno = 0;
    r = do_act(fd, ACT_ADD_FLOW, cid, sizeof cid, fb, flen);
    e = errno;
    L("ACTION_ADD_FLOW flags=0 (len=%zu) -> ret=%d errno=%d (%s)", flen, r, e, r == 0 ? "OK" : strerror(e));
    if (r == 0) {
        uint8_t *fid = fb + 16;   // registration_id written back by the kernel
        L("flow_id = %02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
          fid[0], fid[1], fid[2], fid[3], fid[4], fid[5], fid[6], fid[7], fid[8], fid[9],
          fid[10], fid[11], fid[12], fid[13], fid[14], fid[15]);
        errno = 0;
        r = do_act(fd, ACT_REMOVE_FLOW, fid, 16, NULL, 0);
        e = errno;
        L("ACTION_REMOVE_FLOW -> ret=%d errno=%d (%s)", r, e, r == 0 ? "OK" : strerror(e));
    }

    errno = 0;
    r = do_act(fd, ACT_CLAIM, cid, sizeof cid, buf, sizeof buf);
    e = errno;
    L("ACTION_CLAIM -> ret=%d errno=%d (%s)", r, e, r == 0 ? "OK" : strerror(e));

    errno = 0;
    r = do_act(fd, ACT_REMOVE, cid, sizeof cid, NULL, 0);
    e = errno;
    L("ACTION_REMOVE -> ret=%d errno=%d (%s)", r, e, r == 0 ? "OK" : strerror(e));

    L("RESULT: necp-open ALLOWED from app sandbox; ADD ret=%d", r);
    close(fd);
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
