// Run as mobile by launchd: the donor SoundBoard writes current-user values,
// and SetupAssistant's launch sentinel is a per-user POSIX named semaphore.
#import "HomePodSetupState.h"
#import "HomePodSetupProcesses.h"
#import <CoreFoundation/CoreFoundation.h>
#import <dlfcn.h>
#import <notify.h>
#import <signal.h>
#import <unistd.h>
#import <sys/sysctl.h>
#import <string.h>

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        BOOL homeView = argc == 2 && strcmp(argv[1], "--homeview") == 0;
        if (argc != 1 && !homeView) return 1;
        if (getuid() != 501 || geteuid() != 501) {
            NSLog(@"HomePod setup maintenance must run as mobile (501).");
            return 1;
        }
        if (homeView) {
            char machine[128] = {0}, model[128] = {0};
            size_t machineSize = sizeof(machine), modelSize = sizeof(model);
            sysctlbyname("hw.machine", machine, &machineSize, NULL, 0);
            sysctlbyname("hw.model", model, &modelSize, NULL, 0);
            if (strncmp(machine, "HomeAccessory17,", 16) != 0
                && strcmp(model, "J490AP") != 0 && strcmp(model, "J491AP") != 0) {
                NSLog(@"HomeView setup maintenance requires a HomeAccessory17 guest.");
                return 1;
            }
        }
        NSString *name = homeView ? @"HomeView" : @"HomePod";
        // HomeView's SetupAssistant checks this override before its normal
        // SetupDone gate, in both NeedsToRun and HasCompletedInitialRun.
        // Keep actual setup choices intact; deselection restores only this key.
        NSArray<NSString *> *keys = homeView ? @[@"ForceNoBuddy"] : VPHomePodSetupKeys();
        NSString *directory = @"/var/mobile/Library/Application Support/vphone";
        NSURL *journal = [NSURL fileURLWithPath:[directory stringByAppendingPathComponent:[name stringByAppendingString:@"SetupOriginal.plist"]]];
        NSDictionary *policy = [NSDictionary dictionaryWithContentsOfFile:[NSString stringWithFormat:@"/usr/share/vphone/%@Setup.plist", name]];
        BOOL enabled = [policy[@"Enabled"] isEqual:@YES];
        BOOL hadJournal = [NSFileManager.defaultManager fileExistsAtPath:journal.path];
        if (!enabled && !hadJournal) return 0;

        void *framework = dlopen("/System/Library/PrivateFrameworks/SetupAssistant.framework/SetupAssistant", RTLD_NOW);
        void (*prepare)(void) = framework ? dlsym(framework, "BYSetupAssistantPrepareLaunchSentinel") : NULL;
        BOOL (*needsSetup)(void) = framework ? dlsym(framework, "BYSetupAssistantNeedsToRun") : NULL;
        BOOL (*completed)(void) = framework ? dlsym(framework, "BYSetupAssistantHasCompletedInitialRun") : NULL;
        CFStringRef *finishedNotification = framework ? dlsym(framework, "BYSetupAssistantFinishedDarwinNotification") : NULL;
        NSError *error = nil;
        BOOL success = NO;
        if (!prepare || !needsSetup || !completed || !finishedNotification || !*finishedNotification) {
            error = [NSError errorWithDomain:@"com.vphone.homepod-setup" code:2
                                    userInfo:@{NSLocalizedDescriptionKey: @"Donor SetupAssistant completion APIs are unavailable."}];
        } else {
            CFStringRef domain = CFSTR("com.apple.purplebuddy");
            CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
            NSMutableDictionary *current = [NSMutableDictionary dictionary];
            for (NSString *key in keys) {
                id value = CFBridgingRelease(CFPreferencesCopyValue((__bridge CFStringRef)key, domain,
                    kCFPreferencesCurrentUser, kCFPreferencesAnyHost));
                if (value) current[key] = value;
            }
            success = VPSetupUpdateKeys(keys, enabled, journal, current, ^(NSString *key, id value) {
                CFPreferencesSetValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)value, domain,
                    kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
            }, ^BOOL {
                return CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
            }, &error);
            if (success) {
                // The stock function publishes the setup state notification and
                // prepares/clears the semaphore. SoundBoard then uses its own
                // setup-gated initialization; do not fake a HomeKit home here.
                BOOL setupDone = CFPreferencesGetAppBooleanValue(CFSTR("SetupDone"), domain, NULL);
                BOOL allSteps = CFPreferencesGetAppBooleanValue(CFSTR("SetupFinishedAllSteps"), domain, NULL);
                BOOL forceNoBuddy = CFPreferencesGetAppBooleanValue(CFSTR("ForceNoBuddy"), domain, NULL);
                BOOL expectedNeedsSetup = enabled ? NO : !setupDone && !forceNoBuddy;
                BOOL expectedCompleted = enabled ? YES : allSteps || forceNoBuddy;
                success = VPHomePodSetupPrepare(enabled, expectedNeedsSetup, expectedCompleted,
                    ^BOOL { return needsSetup(); }, ^BOOL { return completed(); }, ^{ prepare(); }, ^BOOL {
                    // Prepare already publishes when creating the sentinel.
                    // Only replay an existing sentinel's event, using the
                    // donor export rather than duplicating its notification.
                    char name[512];
                    return CFStringGetCString(*finishedNotification, name, sizeof(name), kCFStringEncodingUTF8)
                        && notify_post(name) == NOTIFY_STATUS_OK;
                }, &error);
                if (success) {
                    if (enabled && !homeView) {
                        // A pending HPSetup session owns separate assistant/
                        // voice-trigger assertions; native _setupFinished does
                        // not tear that process down, so finish it gracefully.
                        void *processLibrary = dlopen("/usr/lib/libproc.dylib", RTLD_NOW);
                        VPHomePodSetupProcessAPI api = {
                            .listPIDs = processLibrary ? dlsym(processLibrary, "proc_listpids") : NULL,
                            .processPath = processLibrary ? dlsym(processLibrary, "proc_pidpath") : NULL,
                            .signalProcess = kill,
                        };
                        success = VPHomePodSetupStopProcesses(api, getuid(), 50, ^{
                            NSDate *until = [NSDate dateWithTimeIntervalSinceNow:0.1];
                            [NSRunLoop.currentRunLoop runUntilDate:until];
                            NSTimeInterval remaining = until.timeIntervalSinceNow;
                            if (remaining > 0) [NSThread sleepForTimeInterval:remaining];
                        }, &error);
                    } else if (!enabled) {
                        // Keep the inverse through the native sentinel transition,
                        // including failures that need a later launchd retry.
                        success = [NSFileManager.defaultManager removeItemAtURL:journal error:&error];
                    }
                }
            }
        }
        [NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES
                                               attributes:@{NSFilePosixPermissions: @0700} error:NULL];
        NSMutableDictionary *status = [@{@"Enabled": @(enabled), @"Succeeded": @(success), @"Updated": NSDate.date} mutableCopy];
        if (needsSetup) status[@"NeedsSetup"] = @(needsSetup());
        if (completed) status[@"CompletedInitialRun"] = @(completed());
        if (error) status[@"Error"] = error.localizedDescription;
        [status writeToFile:[directory stringByAppendingPathComponent:[name stringByAppendingString:@"SetupStatus.plist"]] atomically:YES];
        NSLog(@"%@ setup maintenance: %@", name, status);
        return success ? 0 : 1;
    }
}
