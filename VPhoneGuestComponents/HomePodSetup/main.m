// Run as mobile by launchd: the donor SoundBoard and AirPlay read current-user values,
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

static NSString *const VPStateDirectory = @"/var/mobile/Library/Application Support/vphone";

// The setup completion: SetupAssistant's two keys, its native sentinel, and the
// end of a pending HPSetup session.
static BOOL VPRunSetup(BOOL homeView) {
    @autoreleasepool {
        NSString *name = homeView ? @"HomeView" : @"HomePod";
        // HomeView's SetupAssistant checks this override before its normal
        // SetupDone gate, in both NeedsToRun and HasCompletedInitialRun.
        // Keep actual setup choices intact; deselection restores only this key.
        NSArray<NSString *> *keys = homeView ? @[@"ForceNoBuddy"] : VPHomePodSetupKeys();
        NSString *directory = VPStateDirectory;
        NSURL *journal = [NSURL fileURLWithPath:[directory stringByAppendingPathComponent:[name stringByAppendingString:@"SetupOriginal.plist"]]];
        NSDictionary *policy = [NSDictionary dictionaryWithContentsOfFile:[NSString stringWithFormat:@"/usr/share/vphone/%@Setup.plist", name]];
        BOOL enabled = [policy[@"Enabled"] isEqual:@YES];
        BOOL hadJournal = [NSFileManager.defaultManager fileExistsAtPath:journal.path];
        if (!enabled && !hadJournal) return YES;

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
        NSMutableDictionary *status = [@{@"Enabled": @(enabled), @"Succeeded": @(success), @"Updated": NSDate.date} mutableCopy];
        if (needsSetup) status[@"NeedsSetup"] = @(needsSetup());
        if (completed) status[@"CompletedInitialRun"] = @(completed());
        if (error) status[@"Error"] = error.localizedDescription;
        [status writeToFile:[directory stringByAppendingPathComponent:[name stringByAppendingString:@"SetupStatus.plist"]] atomically:YES];
        NSLog(@"%@ setup maintenance: %@", name, status);
        return success;
    }
}

// AirPlay's own VM override, useWiFiAndAWDLOnVirtualMachine in mobile's
// com.apple.airplay. AirPlaySupport reads it once per process, so the AirPlay
// daemons restart only when this run changed the value.
static BOOL VPRunAirPlay(void) {
    @autoreleasepool {
        NSString *directory = VPStateDirectory;
        NSURL *journal = [NSURL fileURLWithPath:[directory stringByAppendingPathComponent:@"HomePodAirPlayOriginal.plist"]];
        NSDictionary *policy = [NSDictionary dictionaryWithContentsOfFile:@"/usr/share/vphone/HomePodAirPlay.plist"];
        BOOL enabled = [policy[@"Enabled"] isEqual:@YES];
        BOOL hadJournal = [NSFileManager.defaultManager fileExistsAtPath:journal.path];
        if (!enabled && !hadJournal) return YES;

        CFStringRef domain = CFSTR("com.apple.airplay");
        CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
        NSMutableDictionary *current = [NSMutableDictionary dictionary];
        for (NSString *key in VPHomePodAirPlayKeys()) {
            id value = CFBridgingRelease(CFPreferencesCopyValue((__bridge CFStringRef)key, domain,
                kCFPreferencesCurrentUser, kCFPreferencesAnyHost));
            if (value) current[key] = value;
        }
        NSMutableDictionary *values = [NSMutableDictionary dictionary];
        for (NSString *key in VPHomePodAirPlayKeys()) values[key] = @1;
        NSError *error = nil;
        BOOL success = VPHomePodPreferenceUpdate(VPHomePodAirPlayKeys(), values, enabled, journal, current,
            ^(NSString *key, id value) {
                CFPreferencesSetValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)value, domain,
                    kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
            }, ^BOOL {
                return CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
            }, &error);
        BOOL changed = NO;
        NSUInteger restarted = 0;
        if (success) {
            for (NSString *key in VPHomePodAirPlayKeys()) {
                id now = CFBridgingRelease(CFPreferencesCopyValue((__bridge CFStringRef)key, domain,
                    kCFPreferencesCurrentUser, kCFPreferencesAnyHost));
                if (!(now == current[key] || [now isEqual:current[key]])) changed = YES;
            }
            if (changed) {
                void *processLibrary = dlopen("/usr/lib/libproc.dylib", RTLD_NOW);
                VPHomePodSetupProcessAPI api = {
                    .listPIDs = processLibrary ? dlsym(processLibrary, "proc_listpids") : NULL,
                    .processPath = processLibrary ? dlsym(processLibrary, "proc_pidpath") : NULL,
                    .signalProcess = kill,
                };
                success = VPHomePodRestartProcesses(api, getuid(), VPHomePodAirPlayExecutables(), &restarted, &error);
            }
            // The journal goes only once the restored value is in place.
            if (success && !enabled) success = [NSFileManager.defaultManager removeItemAtURL:journal error:&error];
        }
        NSMutableDictionary *status = [@{@"Enabled": @(enabled), @"Succeeded": @(success), @"Changed": @(changed),
                                         @"Restarted": @(restarted), @"Updated": NSDate.date} mutableCopy];
        if (error) status[@"Error"] = error.localizedDescription;
        [status writeToFile:[directory stringByAppendingPathComponent:@"HomePodAirPlayStatus.plist"] atomically:YES];
        NSLog(@"HomePod AirPlay maintenance: %@", status);
        return success;
    }
}

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
        // Both journals live here and are written before any preference, so
        // the directory must exist before either half runs.
        [NSFileManager.defaultManager createDirectoryAtPath:VPStateDirectory withIntermediateDirectories:YES
                                               attributes:@{NSFilePosixPermissions: @0700} error:NULL];
        // Independent: a failure of one is retried by launchd without
        // leaving the other undone.
        // The AirPlay override is a HomePod patch; HomeView runs setup only.
        if (homeView) return VPRunSetup(YES) ? 0 : 1;
        BOOL setup = VPRunSetup(NO);
        BOOL airPlay = VPRunAirPlay();
        return setup && airPlay ? 0 : 1;
    }
}
