#import <UIKit/UIKit.h>
#import <mach/mach.h>
#import <sys/sysctl.h>
extern int csops(pid_t pid, unsigned int ops, void *useraddr, uint32_t usersize);
#define CS_OPS_STATUS 0
#define CS_GET_TASK_ALLOW 0x4
#define CS_PLATFORM_BINARY 0x4000000
#import "pathleak.h"
#include <sys/stat.h>
#include <sys/mount.h>
#include <sys/fsgetpath.h>
#include <sys/xattr.h>

static NSMutableString *out;
static NSString *logPath() { return [NSTemporaryDirectory() stringByAppendingPathComponent:@"out.txt"]; }
static void Log(NSString *l) {
    [out appendString:l]; [out appendString:@"\n"];
    NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:logPath()]; [h seekToEndOfFile]; [h writeData:[[l stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding]]; [h closeFile];
}

@interface VC : UIViewController @end
@implementation VC
- (void)viewDidLoad {
    [super viewDidLoad];
    if ([NSProcessInfo processInfo].arguments.count > 1 && [[NSProcessInfo processInfo].arguments[1] isEqualToString:@"tfp"]) { [self tfpProbe]; return; }
    UITextView *tv = [[UITextView alloc] initWithFrame:self.view.bounds];
    tv.autoresizingMask = 0x3f; tv.editable = NO; tv.font = [UIFont monospacedSystemFontOfSize:9 weight:UIFontWeightRegular];
    tv.textColor = [UIColor greenColor]; tv.backgroundColor = [UIColor blackColor]; self.view = tv;
    dispatch_async(dispatch_get_global_queue(0,0), ^{
        out = [NSMutableString string];
        [@"" writeToFile:logPath() atomically:YES encoding:NSUTF8StringEncoding error:nil];
        struct stat st; NSString *probe = [NSTemporaryDirectory() stringByAppendingPathComponent:@"b"];
        [@"x" writeToFile:probe atomically:YES encoding:NSUTF8StringEncoding error:nil];
        uint64_t base = stat(probe.fileSystemRepresentation, &st) == 0 ? st.st_ino : 0;
        [[NSFileManager defaultManager] removeItemAtPath:probe error:nil];
        Log([NSString stringWithFormat:@"PATHLEAK baseline inode=%llu", base]);
        // One pass over all inodes, match every prefix at once
        NSArray *dirs = @[@"/private/var/containers/Bundle/Application", @"/private/var/mobile/Containers/Data/Application", @"/private/var/containers/Shared/SystemGroup", @"/private/var/mobile/Containers/Shared/AppGroup", @"/private/var/containers/Data/System"];
        struct statfs sfs; statfs(NSHomeDirectory().fileSystemRepresentation, &sfs); fsid_t fsid = sfs.f_fsid;
        uint64_t end = base + 2000000; char buffer[PATH_MAX]; uint64_t done = 0, total = 0;
        NSMutableArray *prefixes = [NSMutableArray array];
        for (NSString *d in dirs) { char pre[PATH_MAX]; [d getFileSystemRepresentation:pre maxLength:sizeof(pre)]; [prefixes addObject:[NSValue valueWithPointer:strdup(pre)]]; }
        Log([NSString stringWithFormat:@"SCAN start end=%llu fsid=%d", end, sfs.f_fsid.val[0]]);
        NSDate *t0 = [NSDate date];
        for (uint64_t ino = 1; ino <= end; ino++) {
            ssize_t n = fsgetpath(buffer, sizeof(buffer), &fsid, ino);
            if (n <= 0) continue; total++;
            const char *slash = strchr(buffer + 1, '/');
            if (!slash) continue;
            size_t dl = slash - buffer; // length of "/private/var/containers/Bundle" style parent
            for (NSValue *v in prefixes) {
                const char *pre = v.pointerValue; size_t pl = strlen(pre);
                if (!strncmp(buffer, pre, pl) && buffer[pl] == '/' && !strchr(buffer + pl + 1, '/')) {
                    [out appendFormat:@"LEAK %@\n", [NSString stringWithUTF8String:buffer]]; done++;
                    if (done % 50 == 0) [out writeToFile:logPath() atomically:YES encoding:NSUTF8StringEncoding error:nil];
                    break;
                }
            }
            if (ino % 20000000 == 0) { [out writeToFile:logPath() atomically:YES encoding:NSUTF8StringEncoding error:nil]; Log([NSString stringWithFormat:@"SCAN ino=%lluM resolved=%llu found=%llu", ino/1000000, total, done]); }
        }
        [out writeToFile:logPath() atomically:YES encoding:NSUTF8StringEncoding error:nil];
        Log([NSString stringWithFormat:@"SCAN done in %.0fs resolved=%llu found=%llu", -[t0 timeIntervalSinceNow], total, done]);
        Log(@"DONE");
        dispatch_async(dispatch_get_main_queue(), ^{ ((UITextView *)self.view).text = out; });
    });
}
// Live check of the gates that are patched offline in the kernelcache: task_for_pid, kernel task port, csops.
- (void)tfpProbe {
    NSMutableString *s = [NSMutableString string];
    uint32_t flags = 0; csops(getpid(), CS_OPS_STATUS, &flags, sizeof(flags));
    [s appendFormat:@"pid=%d csops flags=%#x platform=%d get-task-allow=%d\n", getpid(), flags, (flags & CS_PLATFORM_BINARY) != 0, (flags & CS_GET_TASK_ALLOW) != 0];
    int pids[] = {0, 1, 2, 100, getpid()};
    for (unsigned i = 0; i < sizeof(pids)/sizeof(pids[0]); i++) { int pid = pids[i];
        mach_port_t t = MACH_PORT_NULL; kern_return_t k = task_for_pid(mach_task_self(), pid, &t);
        [s appendFormat:@"task_for_pid(%d) = %s\n", pid, k == KERN_SUCCESS ? "OK" : mach_error_string(k)];
        if (k) continue;
        if (pid == 0) { vm_offset_t d = 0; mach_msg_type_number_t c = 0;
            kern_return_t r = vm_read_overwrite(t, 0xfffffff00700c000, 16, &d, &c);
            [s appendFormat:@"  vm_read kernel base = %s\n", r == KERN_SUCCESS ? "OK" : mach_error_string(r)]; }
        mach_port_deallocate(mach_task_self(), t);
    }
    mach_port_t kp = MACH_PORT_NULL; kern_return_t k = host_get_special_port(mach_host_self(), HOST_LOCAL_NODE, 4, &kp);
    [s appendFormat:@"host_get_special_port(4 kernel) = %s\n", k == KERN_SUCCESS ? "OK" : mach_error_string(k)];
    Log(s); Log(@"DONE");
    printf("%s\n", s.UTF8String); fflush(stdout);
    dispatch_async(dispatch_get_main_queue(), ^{ ((UITextView *)self.view).text = s; });
}
@end
@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property (strong) UIWindow *window;
@end
@implementation AppDelegate
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)x {
    [UIApplication sharedApplication].idleTimerDisabled = YES;
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.rootViewController = [[VC alloc] init]; [self.window makeKeyAndVisible]; return YES;
}
@end
int main(int argc, char *argv[]) { @autoreleasepool { return UIApplicationMain(argc, argv, nil, @"AppDelegate"); } }
