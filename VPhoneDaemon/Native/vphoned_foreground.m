#import "Include/VphonedNative.h"
#import <dlfcn.h>
#import <objc/message.h>
#import <sys/sysctl.h>

char *vp_runningboard_focal_bundle_id(void) {
    @autoreleasepool {
        dlopen("/System/Library/PrivateFrameworks/RunningBoardServices.framework/RunningBoardServices", RTLD_NOW);
        Class identifierClass = NSClassFromString(@"RBSProcessIdentifier");
        Class handleClass = NSClassFromString(@"RBSProcessHandle");
        SEL identifierSelector = NSSelectorFromString(@"identifierWithPid:");
        SEL handleSelector = NSSelectorFromString(@"handleForIdentifier:error:");
        if (![identifierClass respondsToSelector:identifierSelector] || ![handleClass respondsToSelector:handleSelector])
            return NULL;
        void *libproc = dlopen("/usr/lib/libproc.dylib", RTLD_NOW);
        int (*pidPath)(int, void *, uint32_t) = libproc ? dlsym(libproc, "proc_pidpath") : NULL;
        if (!pidPath) {
            if (libproc) dlclose(libproc);
            return NULL;
        }

        int mib[] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL};
        size_t length = 0;
        if (sysctl(mib, 3, NULL, &length, NULL, 0) != 0) {
            dlclose(libproc);
            return NULL;
        }
        length += 64 * sizeof(struct kinfo_proc);
        struct kinfo_proc *processes = calloc(1, length);
        if (!processes || sysctl(mib, 3, processes, &length, NULL, 0) != 0) {
            free(processes);
            dlclose(libproc);
            return NULL;
        }

        NSMutableSet<NSString *> *focalIDs = [NSMutableSet set];
        for (size_t i = 0; i < length / sizeof(struct kinfo_proc) && focalIDs.count < 2; i++) {
            pid_t pid = processes[i].kp_proc.p_pid;
            char path[4096] = {0};
            if (pid <= 0 || pidPath(pid, path, sizeof(path)) <= 0 || !strstr(path, ".app/"))
                continue;
            @try {
                id identifier = ((id (*)(id, SEL, int))objc_msgSend)(identifierClass, identifierSelector, pid);
                id handle = ((id (*)(id, SEL, id, NSError **))objc_msgSend)(handleClass, handleSelector,
                                                                             identifier, NULL);
                NSString *bundleID = [[handle valueForKey:@"identity"] valueForKey:@"embeddedApplicationIdentifier"];
                if (![bundleID isKindOfClass:NSString.class] || !bundleID.length) continue;
                // The Home screen's widget renderer can own UIFocal without being the frontmost app.
                if ([bundleID hasPrefix:@"com.apple.chrono.WidgetRenderer"]) continue;
                for (id assertion in [[handle valueForKey:@"currentState"] valueForKey:@"assertions"]) {
                    NSString *domain = [assertion valueForKey:@"domain"];
                    if ([domain isKindOfClass:NSString.class] &&
                        ([domain containsString:@"Workspace-ForegroundFocal"] ||
                         [domain containsString:@"com.apple.frontboard:SuspendableRole-UIFocal"])) {
                        [focalIDs addObject:bundleID];
                        break;
                    }
                }
            } @catch (NSException *exception) {
                (void)exception;
            }
        }
        free(processes);
        dlclose(libproc);
        return focalIDs.count == 1 ? strdup(focalIDs.anyObject.UTF8String) : NULL;
    }
}
