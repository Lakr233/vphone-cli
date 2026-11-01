#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <string.h>

// The lab's fresh Data volume cannot complete the old PreBoard unlock path
// against the newer SEP. Keep this bypass local to backboardd's startup wait;
// it does not mark global migration complete or change the keybag.
static BOOL skipStartupMigration(id self, SEL selector, id connection,
                                 BOOL checkNecessity, id lastPlugin, BOOL testOnly) {
    return YES;
}
static void (*originalCheckIn)(id, SEL, NSNumber *, id);
static void checkInWithoutMigrationWait(id self, SEL selector, NSNumber *wait, id reply) {
    originalCheckIn(self, selector, @NO, reply);
}
__attribute__((constructor)) static void start(void) {
    if (NSProcessInfo.processInfo.operatingSystemVersion.majorVersion != 16 ||
        ![NSProcessInfo.processInfo.processName isEqualToString:@"backboardd"]) return;
    dlopen("/System/Library/PrivateFrameworks/DataMigration.framework/DataMigration", RTLD_NOW);
    Class cls = objc_getClass("DMClientAPIController");
    SEL sel = sel_registerName("_migrateWithConnection:checkNecessity:lastRelevantPlugin:testMigrationInfrastructureOnly:");
    Method method = class_getInstanceMethod(cls, sel);
    if (!method || strcmp(method_getTypeEncoding(method), "B40@0:8@16B24@28B36")) return;
    class_replaceMethod(cls, sel, (IMP)skipStartupMigration, method_getTypeEncoding(method));
    // PreBoard separately blocks the system shell even after the local
    // migration call returns. Preserve the native check-in and reply handling,
    // requesting its existing non-waiting mode instead.
    Class sentinel = objc_getClass("BKSystemShellSentinel");
    SEL checkIn = sel_registerName("checkInAndWaitForDataMigration:completionBlock:");
    Method check = class_getInstanceMethod(sentinel, checkIn);
    if (check && !strcmp(method_getTypeEncoding(check), "v32@0:8@16@?24")) {
        originalCheckIn = (void *)method_getImplementation(check);
        class_replaceMethod(sentinel, checkIn, (IMP)checkInWithoutMigrationWait, method_getTypeEncoding(check));
    }
    NSLog(@"[ios16-migration] backboard startup migration wait disabled for this lab");
}
