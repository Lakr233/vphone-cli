#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
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
static BOOL (*originalBlock)(id, SEL);
static void (*originalAlternate)(id, SEL, NSString *);
static Ivar alternateSystemApp;
static char suppressedPreBoard;
static void alternateExceptLabPreBoard(id self, SEL selector, NSString *identifier) {
    BOOL preBoard = [identifier isKindOfClass:NSString.class] && [identifier isEqualToString:@"com.apple.PreBoard"];
    objc_setAssociatedObject(self, &suppressedPreBoard, preBoard ? @YES : nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    originalAlternate(self, selector, preBoard ? nil : identifier);
}
static BOOL blockExceptLabPreBoard(id self, SEL selector) {
    // The native caller already holds the sentinel lock. Read its ivar through
    // runtime metadata instead of its locking getter. Keep every other block.
    if ([objc_getAssociatedObject(self, &suppressedPreBoard) boolValue]) return NO;
    id alternate = object_getIvar(self, alternateSystemApp);
    if ([alternate isKindOfClass:NSString.class] && [alternate isEqualToString:@"com.apple.PreBoard"]) return NO;
    return originalBlock(self, selector);
}
static void checkInWithoutMigrationWait(id self, SEL selector, NSNumber *wait, id reply) {
    static dispatch_once_t localShell;
    dispatch_once(&localShell, ^{
        SEL complete = sel_registerName("dataMigratorDidComplete");
        SEL unblock = sel_registerName("unblockSystemApp");
        Method completion = class_getInstanceMethod(object_getClass(self), complete);
        Method unblocking = class_getInstanceMethod(object_getClass(self), unblock);
        if (completion && unblocking && !strcmp(method_getTypeEncoding(completion), "v16@0:8") &&
            !strcmp(method_getTypeEncoding(unblocking), "B16@0:8")) {
            // Dismiss the lab's PreBoard curtain through the native local
            // sentinel transitions. No DataMigrator preference is written and
            // no encrypted user storage or keybag is unlocked.
            ((void (*)(id, SEL))objc_msgSend)(self, complete);
            (void)((BOOL (*)(id, SEL))objc_msgSend)(self, unblock);
        }
    });
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
    SEL block = sel_registerName("_lock_blockSystemApp");
    Method blocker = class_getInstanceMethod(sentinel, block);
    Ivar alternate = class_getInstanceVariable(sentinel, "_lock_activeAlternateSystemAppBundleIdentifier");
    SEL setAlternate = sel_registerName("setActiveAlternateSystemAppBundleIdentifier:");
    Method setter = class_getInstanceMethod(sentinel, setAlternate);
    if (blocker && alternate && !strcmp(method_getTypeEncoding(blocker), "B16@0:8") &&
        !strcmp(ivar_getTypeEncoding(alternate), "@\"NSString\"") && setter &&
        !strcmp(method_getTypeEncoding(setter), "v24@0:8@16")) {
        alternateSystemApp = alternate;
        originalAlternate = (void *)method_getImplementation(setter);
        class_replaceMethod(sentinel, setAlternate, (IMP)alternateExceptLabPreBoard, method_getTypeEncoding(setter));
        originalBlock = (void *)method_getImplementation(blocker);
        class_replaceMethod(sentinel, block, (IMP)blockExceptLabPreBoard, method_getTypeEncoding(blocker));
    }
    SEL checkIn = sel_registerName("checkInAndWaitForDataMigration:completionBlock:");
    Method check = class_getInstanceMethod(sentinel, checkIn);
    if (check && !strcmp(method_getTypeEncoding(check), "v32@0:8@16@?24")) {
        originalCheckIn = (void *)method_getImplementation(check);
        class_replaceMethod(sentinel, checkIn, (IMP)checkInWithoutMigrationWait, method_getTypeEncoding(check));
    }
    NSLog(@"[ios16-migration] backboard startup migration wait disabled for this lab");
}
