#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <fcntl.h>
#import <stdarg.h>
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

static BOOL TLShouldRunInCurrentProcess(void) {
    NSString *execPath = TLExecutablePath();
    if (!execPath.length) return NO;

    // vphone's hook runtime injects broadly, including launch-critical daemons
    // like xpcproxy, logd, notifyd, sshd, shells, and helper tools. Restrict the
    // user tweak loader to app binaries only so it does not destabilize boot or
    // process launch paths.
    if ([execPath containsString:@".app/"]) return YES;

    return NO;
}

static BOOL TLArrayContainsString(id obj, NSString *value) {
    if (![obj isKindOfClass:[NSArray class]] || !value.length) return NO;
    for (id item in (NSArray *)obj) {
        if ([item isKindOfClass:[NSString class]] &&
            [(NSString *)item isEqualToString:value]) {
            return YES;
        }
    }
    return NO;
}

static BOOL TLFilterMatches(NSDictionary *plist, NSString *bundleID, NSString *executableName) {
    NSDictionary *filter = [plist isKindOfClass:[NSDictionary class]] ? plist[@"Filter"] : nil;
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

static void TLLoadTweaks(void) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *execPath = TLExecutablePath();
    NSString *bundleID = NSBundle.mainBundle.bundleIdentifier ?: @"";
    NSString *executableName = TLExecutableName();

    if (!TLShouldRunInCurrentProcess()) {
        return;
    }

    NSArray<NSString *> *files = [fm contentsOfDirectoryAtPath:kTweakDir error:nil];
    if (!files.count) {
        TLLog(@"No tweak files found for bundle=%@ exec=%@ path=%@",
              bundleID, executableName, execPath);
        return;
    }

    TLLog(@"Scanning %lu tweak entries for bundle=%@ exec=%@ path=%@",
          (unsigned long)files.count, bundleID, executableName, execPath);

    for (NSString *filename in files) {
        if (![filename.pathExtension isEqualToString:@"plist"]) continue;

        NSString *plistPath = [kTweakDir stringByAppendingPathComponent:filename];
        NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:plistPath];
        if (![plist isKindOfClass:[NSDictionary class]]) {
            TLLog(@"Skipping unreadable plist %@", plistPath);
            continue;
        }

        if (!TLFilterMatches(plist, bundleID, executableName)) {
            continue;
        }

        NSString *baseName = filename.stringByDeletingPathExtension;
        NSString *dylibPath = [[kTweakDir stringByAppendingPathComponent:baseName]
            stringByAppendingPathExtension:@"dylib"];

        if (![fm isExecutableFileAtPath:dylibPath]) {
            TLLog(@"Skipping %@ because dylib is missing or not executable", dylibPath);
            continue;
        }

        void *handle = dlopen(dylibPath.fileSystemRepresentation, RTLD_NOW | RTLD_GLOBAL);
        if (handle) {
            TLLog(@"Loaded %@", dylibPath);
        } else {
            const char *err = dlerror();
            TLLog(@"Failed to load %@: %s", dylibPath, err ?: "unknown error");
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
