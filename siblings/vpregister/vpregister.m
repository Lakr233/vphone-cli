// vpregister — register JB app bundles on iOS 27 via the containerized
// LaunchServices API (the modern replacement for the deprecated, gutted
// -[LSApplicationWorkspace registerApplicationDictionary:] that uicache -a
// uses). Requires the lsd clientIsEntitledForEmbeddedRegistrationOperations
// gate patch (cfw_patch_lsd_embedded_reg). Usage: vpregister [app.app ...]
// (no args = scan /var/jb/Applications/*.app).
#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <objc/message.h>
@interface LSApplicationWorkspace : NSObject
+ (instancetype)defaultWorkspace;
- (BOOL)registerContainerizedApplicationWithInfoDictionaries:(NSArray *)infos
                                              operationUUID:(NSUUID *)uuid
                                             requestContext:(id)context
                                               saveObserver:(id)observer
                                          registrationError:(NSError **)error;
@end
static BOOL register_app(LSApplicationWorkspace *ws, NSString *path) {
    NSDictionary *info =
        [NSDictionary dictionaryWithContentsOfFile:[path stringByAppendingPathComponent:@"Info.plist"]];
    NSString *bundleID = info[@"CFBundleIdentifier"];
    if (bundleID.length == 0) return NO;
    NSDictionary *dictToRegister = @{
        @"Path" : path,
        @"CFBundleIdentifier" : bundleID,
        @"CodeInfoIdentifier" : bundleID,
        @"ApplicationType" : @"System",
        @"CompatibilityState" : @0,
        @"SignerIdentity" : @"Apple iPhone OS Application Signing",
        @"SignerOrganization" : @"Apple Inc.",
        @"IsAdHocSigned" : @YES,
        @"SignatureVersion" : @132352,
        @"IsDeletable" : @YES,
    };
    NSError *err = nil;
    // The containerized API returns NO even when registration succeeds, so a nil
    // registrationError is the success signal (same rule as vphoned_install.m's
    // containerized path).
    [ws registerContainerizedApplicationWithInfoDictionaries:@[dictToRegister]
                                               operationUUID:[NSUUID UUID]
                                              requestContext:nil
                                                saveObserver:nil
                                           registrationError:&err];
    if (err) fprintf(stderr, "  Unable to register: %s\n", err.description.UTF8String);
    return err == nil;
}
int main(int argc, char **argv) {
    @autoreleasepool {
        dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices", RTLD_NOW);
        Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
        if (!workspaceClass) {
            fprintf(stderr, "LaunchServices workspace is unavailable\n");
            return 1;
        }
        LSApplicationWorkspace *ws = ((id (*)(id, SEL))objc_msgSend)(
            workspaceClass, @selector(defaultWorkspace));
        if (!ws) {
            fprintf(stderr, "LaunchServices workspace could not be opened\n");
            return 1;
        }
        NSMutableArray *paths = [NSMutableArray array];
        for (int i = 1; i < argc; i++) [paths addObject:@(argv[i])];
        if (paths.count == 0) {
            NSString *dir = @"/var/jb/Applications";
            for (NSString *bundleName in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil])
                if ([bundleName hasSuffix:@".app"]) [paths addObject:[dir stringByAppendingPathComponent:bundleName]];
        }
        int fail = 0;
        for (NSString *appPath in paths) {
            BOOL registered = register_app(ws, appPath);
            printf("%-10s %s\n", registered ? "Registered" : "Failed", appPath.UTF8String);
            if (!registered) fail++;
        }
        printf("Registered %d, failed %d\n", (int)paths.count - fail, fail);
        return fail ? 1 : 0;
    }
}
