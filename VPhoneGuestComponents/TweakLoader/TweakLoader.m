#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <fcntl.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <stdarg.h>
#import <string.h>
#import <unistd.h>

static NSString *const kTweakDir = @"/var/jb/Library/MobileSubstrate/DynamicLibraries";
static NSString *const kLogDir = @"/var/jb/var/mobile/Library/TweakLoader";
static NSString *const kLogPath = @"/var/jb/var/mobile/Library/TweakLoader/tweakloader.log";

static void TLLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    if (!message.length) return;

    [[NSFileManager defaultManager] createDirectoryAtPath:kLogDir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];

    NSString *line = [NSString stringWithFormat:@"%@ [TweakLoader] %@\n",
                      [NSDate.date description],
                      message];
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    if (!data.length) return;

    int fd = open(kLogPath.fileSystemRepresentation, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd < 0) return;
    (void)write(fd, data.bytes, data.length);
    close(fd);
}

static NSString *TLExecutableName(void) {
    NSString *argv0 = NSProcessInfo.processInfo.arguments.firstObject;
    if (argv0.length) return argv0.lastPathComponent;
    return NSProcessInfo.processInfo.processName ?: @"unknown";
}

static NSString *TLExecutablePath(void) {
    NSString *argv0 = NSProcessInfo.processInfo.arguments.firstObject;
    return argv0 ?: @"";
}

// Daemons the loader is explicitly allowed to load tweaks into, even though
// they're not under a `.app/` path. Keep this list narrow — every daemon
// added here is a process where a buggy tweak can crash a launchd-managed
// service and destabilize boot.
//
// This list ONLY applies to tweaks WITHOUT Filter.Frameworks. Framework-
// filtered tweaks engage in every process and self-limit based on which
// frameworks are actually loaded — they don't need per-daemon entries here.
static NSString *const kVPhoneAllowedDaemonPaths[] = {
    @"/usr/libexec/cameracaptured",  // libvcamcaptured (Filter.Executables match)
};

static BOOL TLShouldRunInCurrentProcess(void) {
    NSString *execPath = TLExecutablePath();
    if (!execPath.length) return NO;

    // vphone's hook runtime injects broadly, including launch-critical daemons
    // like xpcproxy, logd, notifyd, sshd, shells, and helper tools. Restrict the
    // user tweak loader to app binaries only — plus an allowlist of daemons
    // that explicitly opt in (see `kVPhoneAllowedDaemonPaths`).
    if ([execPath containsString:@".app/"]) return YES;

    for (size_t i = 0;
         i < sizeof(kVPhoneAllowedDaemonPaths) /
                 sizeof(kVPhoneAllowedDaemonPaths[0]);
         i++) {
        if ([execPath isEqualToString:kVPhoneAllowedDaemonPaths[i]]) return YES;
    }

    return NO;
}

static BOOL TLArrayContainsString(NSArray *array, NSString *value) {
    for (id item in array) {
        if ([item isKindOfClass:[NSString class]] &&
            [(NSString *)item isEqualToString:value]) {
            return YES;
        }
    }
    return NO;
}

static BOOL TLFilterMatches(NSDictionary *filter, NSString *bundleID, NSString *executableName) {
    if (![filter isKindOfClass:[NSDictionary class]]) {
        return YES;
    }

    id bundles = filter[@"Bundles"];
    if ([bundles isKindOfClass:[NSArray class]]) {
        if (!bundleID.length || !TLArrayContainsString(bundles, bundleID)) {
            return NO;
        }
    }

    id executables = filter[@"Executables"];
    if ([executables isKindOfClass:[NSArray class]]) {
        if (!executableName.length || !TLArrayContainsString(executables, executableName)) {
            return NO;
        }
    }

    return YES;
}

// Match a loaded dylib path against a "framework name" filter entry.
// "AVFoundation" matches any path containing "/AVFoundation.framework/" —
// catches both /System/Library/Frameworks/... and PrivateFrameworks/....
static BOOL TLPathMatchesFramework(const char *path, NSString *frameworkName) {
    if (!path || !frameworkName.length) return NO;
    NSString *needle = [NSString stringWithFormat:@"/%@.framework/", frameworkName];
    return strstr(path, needle.UTF8String) != NULL;
}

// Pending framework-filtered tweaks: each entry is @{"dylib": path, "frameworks": @[name,...]}.
static NSMutableArray<NSDictionary *> *gTLPendingFrameworkTweaks = nil;
static NSLock *gTLPendingLock = nil;
static dispatch_once_t gTLAddImageOnce;

// dyld invokes add-image callbacks SYNCHRONOUSLY inside its loader lock.
// Calling dlopen from here would recurse and can deadlock or crash early
// daemons. Hand the actual dlopen off to a background queue so it runs
// outside the loader lock — by the time it executes, the framework that
// triggered it is fully loaded.
static void TLOnImageAdded(const struct mach_header *mh, intptr_t slide) {
    (void)slide;
    Dl_info info; if (!dladdr((const void *)mh, &info)) return;
    const char *cpath = info.dli_fname; if (!cpath) return;
    NSString *imagePath = [NSString stringWithUTF8String:cpath];
    if (!imagePath.length) return;

    NSArray<NSDictionary *> *snapshot;
    [gTLPendingLock lock];
    snapshot = [gTLPendingFrameworkTweaks copy];
    [gTLPendingLock unlock];
    if (!snapshot.count) return;

    NSMutableArray<NSString *> *toLoad = [NSMutableArray array];
    for (NSDictionary *pending in snapshot) {
        NSArray *frameworks = pending[@"frameworks"];
        for (NSString *fw in frameworks) {
            if (TLPathMatchesFramework(cpath, fw)) {
                [toLoad addObject:pending[@"dylib"]];
                break;
            }
        }
    }
    if (!toLoad.count) return;

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        for (NSString *dylibPath in toLoad) {
            void *h = dlopen(dylibPath.fileSystemRepresentation, RTLD_NOW | RTLD_GLOBAL);
            if (h) TLLog(@"framework-deferred-load %@ -> %p (triggered by %@)", dylibPath, h, imagePath);
            else   TLLog(@"framework-deferred-load failed for %@: %s", dylibPath, dlerror() ?: "unknown");
        }
    });
}

// Schedule a tweak whose Filter.Frameworks needs at least one framework loaded.
// If a matching framework is already in the process, dlopen via dispatch_async
// (the constructor is still inside dyld's image loading sequence). Otherwise
// queue it; the dyld add-image callback (also async-deferred) handles future.
static void TLScheduleFrameworkTweak(NSString *dylibPath, NSArray *frameworks) {
    // Already-loaded fast path: schedule dlopen on a background queue so it
    // runs after the TweakLoader constructor returns and dyld is idle.
    uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; i++) {
        const char *p = _dyld_get_image_name(i);
        for (NSString *fw in frameworks) {
            if (TLPathMatchesFramework(p, fw)) {
                TLLog(@"queueing %@ for async load (framework %@ already loaded as %s)", dylibPath, fw, p);
                dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                    void *h = dlopen(dylibPath.fileSystemRepresentation, RTLD_NOW | RTLD_GLOBAL);
                    if (h) TLLog(@"framework-load %@ -> %p", dylibPath, h);
                    else   TLLog(@"framework-load failed for %@: %s", dylibPath, dlerror() ?: "unknown");
                });
                return;
            }
        }
    }

    // Queue for later; register the add-image callback once.
    [gTLPendingLock lock];
    if (!gTLPendingFrameworkTweaks) gTLPendingFrameworkTweaks = [NSMutableArray array];
    [gTLPendingFrameworkTweaks addObject:@{@"dylib": dylibPath, @"frameworks": frameworks}];
    [gTLPendingLock unlock];

    dispatch_once(&gTLAddImageOnce, ^{
        _dyld_register_func_for_add_image(TLOnImageAdded);
    });
}

static void TLLoadTweaks(void) {
    // Two engagement tiers:
    //
    //   1. Framework-filtered tweaks (Filter.Frameworks in plist): scanned
    //      and scheduled in EVERY process. The schedule is a no-op unless
    //      the named framework actually loads in this process — the dyld
    //      add-image callback (dispatch_async'd dlopen) is what eventually
    //      pulls the tweak in. Cost in non-AVF processes: one dir scan,
    //      a few plist parses, one callback registration. Safe because
    //      no dlopen happens until the framework appears.
    //
    //   2. Non-framework tweaks (Bundles/Executables filter or none):
    //      only run in .app/ processes and the explicit daemon allowlist
    //      (TLShouldRunInCurrentProcess). Keeping this gate avoids dropping
    //      arbitrary tweaks into launch-critical daemons by accident.
    //
    // Everything below is wrapped in @try/@catch so a bad plist or
    // Foundation quirk in an early-boot daemon can't crash the whole
    // process and trigger a launchd respawn loop.
    NSFileManager *fm = nil;
    NSArray<NSString *> *files = nil;
    @try {
        fm = NSFileManager.defaultManager;
        files = [fm contentsOfDirectoryAtPath:kTweakDir error:nil];
    } @catch (NSException *e) {
        return;
    }
    if (!files.count) return;

    NSString *bundleID = NSBundle.mainBundle.bundleIdentifier ?: @"";
    NSString *executableName = TLExecutableName();
    BOOL processAllowed = TLShouldRunInCurrentProcess();

    gTLPendingLock = [[NSLock alloc] init];

    for (NSString *filename in files) {
        if (![filename.pathExtension isEqualToString:@"plist"]) continue;

        NSDictionary *plist = nil;
        NSString *dylibPath = nil;
        @try {
            NSString *plistPath = [kTweakDir stringByAppendingPathComponent:filename];
            plist = [NSDictionary dictionaryWithContentsOfFile:plistPath];
            if (![plist isKindOfClass:[NSDictionary class]]) continue;

            NSString *baseName = filename.stringByDeletingPathExtension;
            dylibPath = [[kTweakDir stringByAppendingPathComponent:baseName]
                stringByAppendingPathExtension:@"dylib"];
            if (![fm isExecutableFileAtPath:dylibPath]) continue;
        } @catch (NSException *e) {
            continue;
        }

        @try {
            NSDictionary *filter = plist[@"Filter"];
            id frameworksRaw = [filter isKindOfClass:[NSDictionary class]] ? filter[@"Frameworks"] : nil;

            if ([frameworksRaw isKindOfClass:[NSArray class]] &&
                [(NSArray *)frameworksRaw count] > 0) {
                // Universal: schedule in every process. No-op in processes
                // where the named framework never loads.
                TLScheduleFrameworkTweak(dylibPath, (NSArray *)frameworksRaw);
                continue;
            }

            // Non-framework-filtered: keep the .app/+allowlist gate.
            if (!processAllowed) continue;
            if (!TLFilterMatches(filter, bundleID, executableName)) continue;

            void *handle = dlopen(dylibPath.fileSystemRepresentation, RTLD_NOW | RTLD_GLOBAL);
            if (handle) {
                TLLog(@"Loaded %@ (exec=%@ bundle=%@)", dylibPath, executableName, bundleID);
            } else {
                const char *err = dlerror();
                TLLog(@"Failed to load %@: %s", dylibPath, err ?: "unknown error");
            }
        } @catch (NSException *e) {
            TLLog(@"Exception loading %@: %@", dylibPath, e);
        }
    }
}

__attribute__((constructor))
static void TweakLoaderInit(void) {
    @autoreleasepool {
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            TLLoadTweaks();
        });
    }
}
