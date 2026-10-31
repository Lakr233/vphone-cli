#import "HomePodSetupState.h"
#import "HomePodSetupProcesses.h"
#include <assert.h>
#include <errno.h>
#include <signal.h>
#include <string.h>

#define CHECK(condition) do { if (!(condition)) { NSLog(@"Failed at line %d: %s", __LINE__, #condition); abort(); } } while (0)

// mobile's processes: an unrelated one, airplayd, a look-alike outside
// /usr/libexec, tvairplayd and mediaremoted.
static const pid_t pids[] = {7, 120, 121, 122, 123};
static NSMutableArray<NSNumber *> *signalled;

static int listPIDs(uint32_t type, uint32_t user, void *buffer, int capacity) {
    assert(type == 4 && user == 501);
    if (!buffer) return sizeof(pids);
    assert(capacity >= (int)sizeof(pids));
    memcpy(buffer, pids, sizeof(pids));
    return sizeof(pids);
}
static int processPath(int pid, void *buffer, uint32_t capacity) {
    const char *path = "/usr/bin/unrelated";
    if (pid == 120) path = "/usr/libexec/airplayd";
    if (pid == 121) path = "/tmp/usr/libexec/airplayd";
    if (pid == 122) path = "/usr/libexec/tvairplayd";
    if (pid == 123) path = "/System/Library/PrivateFrameworks/MediaRemote.framework/Support/mediaremoted";
    assert(strlen(path) + 1 < capacity);
    strcpy(buffer, path);
    return (int)strlen(path);
}
static int signalProcess(pid_t pid, int signal) {
    assert(signal == SIGTERM);
    [signalled addObject:@(pid)];
    return 0;
}

int main(void) {
    @autoreleasepool {
        // The VM override round-trips through the journal like the setup keys.
        NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        NSURL *journal = [NSURL fileURLWithPath:[path stringByAppendingPathComponent:@"state/airplay.plist"]];
        NSMutableDictionary *preferences = [@{@"Unrelated": @"unchanged"} mutableCopy];
        void (^set)(NSString *, id) = ^(NSString *key, id value) {
            if (value) preferences[key] = value;
            else [preferences removeObjectForKey:key];
        };
        NSDictionary *values = @{@"useWiFiAndAWDLOnVirtualMachine": @1};
        NSError *error = nil;
        CHECK([VPHomePodAirPlayKeys() isEqual:@[@"useWiFiAndAWDLOnVirtualMachine"]]);
        CHECK(VPHomePodPreferenceUpdate(VPHomePodAirPlayKeys(), values, YES, journal, preferences, set, ^BOOL { return YES; }, &error));
        CHECK([preferences[@"useWiFiAndAWDLOnVirtualMachine"] isEqual:@1]);
        CHECK([preferences[@"Unrelated"] isEqual:@"unchanged"]);
        CHECK(VPHomePodPreferenceUpdate(VPHomePodAirPlayKeys(), values, NO, journal, preferences, set, ^BOOL { return YES; }, &error));
        CHECK(preferences[@"useWiFiAndAWDLOnVirtualMachine"] == nil); // It was absent before.
        // A setup journal cannot be replayed as an AirPlay one.
        [NSFileManager.defaultManager removeItemAtURL:journal error:NULL];
        CHECK(VPHomePodSetupUpdate(YES, journal, preferences, set, ^BOOL { return YES; }, &error));
        CHECK(!VPHomePodPreferenceUpdate(VPHomePodAirPlayKeys(), values, NO, journal, preferences, set, ^BOOL { return YES; }, &error));

        // Only mobile's exact AirPlay daemons get one SIGTERM.
        signalled = [NSMutableArray array];
        VPHomePodSetupProcessAPI api = {.listPIDs = listPIDs, .processPath = processPath, .signalProcess = signalProcess};
        NSUInteger restarted = 0;
        CHECK(VPHomePodRestartProcesses(api, 501, VPHomePodAirPlayExecutables(), &restarted, &error));
        CHECK(restarted == 3);
        CHECK([signalled isEqual:(@[@120, @122, @123])]);
        CHECK(!VPHomePodRestartProcesses(api, 0, VPHomePodAirPlayExecutables(), &restarted, &error));
        [NSFileManager.defaultManager removeItemAtPath:path error:NULL];
        NSLog(@"HomePod AirPlay preference and restart tests passed");
    }
    return 0;
}
