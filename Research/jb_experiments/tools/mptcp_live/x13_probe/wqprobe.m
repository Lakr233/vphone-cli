#import <UIKit/UIKit.h>
#include <stdio.h>
#include <unistd.h>
#include <dlfcn.h>

int poc_iogpu_uaf_run(void);
void probe_conn_run(void);
void scaler_probe_run(void);
void aio_probe_run(void);
void mptcp_probe_run(char *host, int port);

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
    UITextView *tv = [[UITextView alloc] initWithFrame:self.view.bounds];
    tv.autoresizingMask = 0x3f; tv.editable = NO; tv.font = [UIFont monospacedSystemFontOfSize:9 weight:UIFontWeightRegular];
    tv.textColor = [UIColor greenColor]; tv.backgroundColor = [UIColor blackColor]; self.view = tv;
    dispatch_async(dispatch_get_global_queue(0,0), ^{
        out = [NSMutableString string];
        [@"" writeToFile:logPath() atomically:YES encoding:NSUTF8StringEncoding error:nil];
        // stdout/stderr of the PoC's printf → log file (and pipe, for devicectl console)
        int fd = open(logPath().fileSystemRepresentation, O_WRONLY | O_APPEND);
        dup2(fd, 1); dup2(fd, 2);
        setvbuf(stdout, NULL, _IONBF, 0);
        Log([NSString stringWithFormat:@"iOS %@ | %@ | start", UIDevice.currentDevice.systemVersion, UIDevice.currentDevice.systemVersion]);
        // Task A: target comes from tmp/mptcp_target.txt ("IP PORT"), one attempt per launch.
        char host[64] = "0.0.0.0"; int port = 0;
        NSString *tf = [NSTemporaryDirectory() stringByAppendingPathComponent:@"mptcp_target.txt"];
        NSArray *parts = [[NSString stringWithContentsOfFile:tf encoding:NSUTF8StringEncoding error:nil] componentsSeparatedByString:@" "];
        if (parts.count >= 2) { snprintf(host, sizeof host, "%s", [parts[0] UTF8String]); port = [parts[1] intValue]; }
        Log([NSString stringWithFormat:@"mptcp target %s:%d", host, port]);
        if (port > 0) mptcp_probe_run(host, port); else Log(@"no target; nothing sent");
        close(fd); dup2(2, 1);
        Log(@"DONE");
        dispatch_async(dispatch_get_main_queue(), ^{ ((UITextView *)self.view).text = out; });
    });
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
