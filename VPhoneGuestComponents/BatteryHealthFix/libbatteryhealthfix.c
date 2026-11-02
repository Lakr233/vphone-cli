// libbatteryhealthfix.c — give Settings the battery health record a real
// battery's power source carries, so Battery Health stops loading forever.
//
// The guest's battery is Virtualization.framework's synthetic power source:
// charge and connectivity, nothing else. powerd publishes it as the internal
// battery, but the health half of the description comes from AppleSmartBattery
// (`BatteryData`, one `AppleSmartBatteryPack` per pack), which no VM has.
// Measured on iOS 27.0 (24A435): the description's one `BatteryPacks` entry
// holds only `PackID`, `Cycle count` and `Transport Type`, with no
// `BatteryHealth`; there is no `Battery Service State` or `Maximum Capacity
// Percent`; and thermalmonitord leaves the age-aware mitigation state at 0.
// Settings → Battery → Battery Health & Charging reads all of them:
//
//   iOS 27.0 (24A435): -[BatteryHealthUIController specifiers] asks
//   -[BatteryHealthUIInformation batteryDataUnavailable], which answers YES
//   while +getManagementState is 0 (the notify state of
//   com.apple.thermalmonitor.ageAwareMitigationState) or no pack parses: a
//   pack without `Battery Service Flags` and `Battery Service State` is
//   dropped — or while the pack's genuineness is unknown, which it is
//   whenever HasBatteryModuleAuth says yes and AppleBatteryAuth is absent.
//   The controller then shows `startSpinner`'s global spinner and re-asks on
//   a timer, forever: the spinner the user sees above the two charging
//   switches.
//
//   iPadOS 26.6.2 (23G90): +[BatteryUIResourceClass batteryDataUnavailable]
//   makes the same checks against the flat `Battery Service State` and
//   `Maximum Capacity Percent` keys of IOPSCopyPowerSourcesByType's array.
//
// Both read the description through IOPSCopyPowerSourcesInfo,
// IOPSCopyPowerSourcesByType or IOPSCopyPowerSourcesByTypePrecise, the state
// through notify_register_check and notify_get_state, and the capability
// through MGGetBoolAnswer. This interposes those, plus notify_cancel to keep
// track of tokens, and answers as a new, healthy battery without battery
// authentication would: service state 0 (normal), no service flags, 100%
// maximum capacity, no cycles, first used when the guest's data volume was
// created, and a mitigation state of 2, "supporting normal peak performance".
// powerd's packs are kept and completed (one is made if there are none), and
// a key the description already has is never replaced, so a base whose powerd
// learns to fill these in wins.
//
// The interposes reach the callers that matter because BatteryUsageUI.bundle
// is a standalone Mach-O, not a shared-cache image: dyld binds its imports
// through the interposing table. (Cache-to-cache calls are not rebound; see
// MISFix/MISFixSignature.c.) The spawn hooks insert this into Settings only —
// `vpIsBatteryHealthFixTarget` in Shared/InjectionEnvironment.h — so no other
// process sees a battery it does not have.

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <fcntl.h>
#include <notify.h>
#include <os/lock.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

// IOKit's power source API; the iPhoneOS SDK ships IOKit.tbd and IOKitLib.h
// but not IOKit/ps/IOPowerSources.h.
extern CFTypeRef IOPSCopyPowerSourcesInfo(void);
extern CFTypeRef IOPSCopyPowerSourcesByType(int type);
// Older bases expose ByType but not Precise. A strong import prevents dyld
// from starting Settings, before any optional battery UI is requested.
extern IOReturn IOPSCopyPowerSourcesByTypePrecise(int type, CFTypeRef *blob) __attribute__((weak_import));
extern Boolean MGGetBoolAnswer(CFStringRef question);

#define VP_MITIGATION_STATE_NAME "com.apple.thermalmonitor.ageAwareMitigationState"
// BatteryHealthUIController's states: 1 management applied, 2 normal peak
// performance, 3 management turned off by the user, 4 dynamic (CPMS).
#define VP_MITIGATION_STATE_NORMAL 2

// MARK: - Log

// Settings runs as mobile and owns this directory; the mode keeps a root
// writer of the same log from silencing later ones, as in SystemHook.
static void vpLog(const char *message) {
    int fd = open("/var/mobile/Library/Caches/vphone-batteryhealthfix.log",
                  O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0666);
    if (fd < 0)
        return;
    fchmod(fd, 0666);
    dprintf(fd, "pid=%d %s\n", getpid(), message);
    close(fd);
}

// One line per kind of answer per process, not one per query: Settings asks
// on every specifier reload.
static void vpLogOnce(atomic_int *logged, const char *message) {
    if (atomic_exchange(logged, 1) == 0)
        vpLog(message);
}

// MARK: - Description

static void vpSetNumber(CFMutableDictionaryRef dictionary, CFStringRef key, int value) {
    if (CFDictionaryContainsKey(dictionary, key))
        return;
    CFNumberRef number = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &value);
    if (!number)
        return;
    CFDictionarySetValue(dictionary, key, number);
    CFRelease(number);
}

static void vpSetValue(CFMutableDictionaryRef dictionary, CFStringRef key, CFTypeRef value) {
    if (value && !CFDictionaryContainsKey(dictionary, key))
        CFDictionarySetValue(dictionary, key, value);
}

static CFMutableDictionaryRef vpCreateMutableDictionary(void) {
    return CFDictionaryCreateMutable(kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks,
                                     &kCFTypeDictionaryValueCallBacks);
}

// The health numbers BatteryUsageUI reads, at the description's top level
// (iOS 26) and in each pack's `BatteryHealth` (iOS 27).
static void vpSetHealth(CFMutableDictionaryRef dictionary) {
    vpSetNumber(dictionary, CFSTR("Battery Service State"), 0);
    vpSetNumber(dictionary, CFSTR("Battery Service Flags"), 0);
    vpSetNumber(dictionary, CFSTR("Maximum Capacity Percent"), 100);
}

// When the guest's data volume was created, which is when it was restored:
// the closest thing a VM has to a battery's first use.
static CFDateRef vpCreateFirstUseDate(void) {
    struct stat info;
    CFAbsoluteTime time = stat("/private/var/mobile", &info) == 0 && info.st_birthtimespec.tv_sec > 0
                              ? (CFAbsoluteTime)info.st_birthtimespec.tv_sec - kCFAbsoluteTimeIntervalSince1970
                              : CFAbsoluteTimeGetCurrent();
    return CFDateCreate(kCFAllocatorDefault, time);
}

// A pack as BatteryUsageUI reads it: powerd's own keys (on 27.0 `PackID`,
// `Cycle count` and `Transport Type`) kept, and the ones that come from
// AppleSmartBatteryPack added. NULL `existing` makes the one pack a
// description without any gets.
static CFDictionaryRef vpCreatePack(CFTypeRef existing) {
    CFMutableDictionaryRef pack = existing && CFGetTypeID(existing) == CFDictionaryGetTypeID()
                                      ? CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, existing)
                                      : vpCreateMutableDictionary();
    CFMutableDictionaryRef health = vpCreateMutableDictionary();
    CFDateRef firstUse = vpCreateFirstUseDate();
    if (pack && health) {
        vpSetNumber(pack, CFSTR("PackID"), 0);
        vpSetNumber(pack, CFSTR("Cycle count"), 0);
        vpSetValue(pack, CFSTR("Date of manufacture"), firstUse);
        vpSetValue(pack, CFSTR("Date of first use"), firstUse);
        vpSetHealth(health);
        vpSetValue(pack, CFSTR("BatteryHealth"), health);
    }
    if (health)
        CFRelease(health);
    if (firstUse)
        CFRelease(firstUse);
    return pack;
}

static int vpIsInternalBattery(CFTypeRef value) {
    if (!value || CFGetTypeID(value) != CFDictionaryGetTypeID())
        return 0;
    CFTypeRef type = CFDictionaryGetValue((CFDictionaryRef)value, CFSTR("Type"));
    return type && CFGetTypeID(type) == CFStringGetTypeID() &&
           CFEqual(type, CFSTR("InternalBattery"));
}

static CFArrayRef vpPacks(CFDictionaryRef description) {
    CFTypeRef packs = CFDictionaryGetValue(description, CFSTR("BatteryPacks"));
    return packs && CFGetTypeID(packs) == CFArrayGetTypeID() ? packs : NULL;
}

// An internal battery without the service state at its top level, without a
// pack, or with a pack that has no `BatteryHealth`. A real battery's
// description has all three, and is left alone.
static int vpNeedsHealth(CFTypeRef value) {
    if (!vpIsInternalBattery(value))
        return 0;
    CFDictionaryRef description = value;
    if (!CFDictionaryContainsKey(description, CFSTR("Battery Service State")))
        return 1;
    CFArrayRef packs = vpPacks(description);
    if (!packs || CFArrayGetCount(packs) == 0)
        return 1;
    for (CFIndex index = 0; index < CFArrayGetCount(packs); index++) {
        CFTypeRef pack = CFArrayGetValueAtIndex(packs, index);
        if (!pack || CFGetTypeID(pack) != CFDictionaryGetTypeID() ||
            !CFDictionaryContainsKey(pack, CFSTR("BatteryHealth")))
            return 1;
    }
    return 0;
}

static CFDictionaryRef vpCreateDescriptionWithHealth(CFDictionaryRef description) {
    CFMutableDictionaryRef copy = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, description);
    CFMutableArrayRef packs = CFArrayCreateMutable(kCFAllocatorDefault, 0, &kCFTypeArrayCallBacks);
    if (!copy || !packs) {
        if (copy)
            CFRelease(copy);
        if (packs)
            CFRelease(packs);
        return NULL;
    }
    CFArrayRef existing = vpPacks(description);
    CFIndex count = existing ? CFArrayGetCount(existing) : 0;
    for (CFIndex index = 0; index < (count ? count : 1); index++) {
        CFDictionaryRef pack = vpCreatePack(count ? CFArrayGetValueAtIndex(existing, index) : NULL);
        if (pack) {
            CFArrayAppendValue(packs, pack);
            CFRelease(pack);
        }
    }
    vpSetHealth(copy);
    vpSetNumber(copy, CFSTR("Cycle count"), 0);
    CFDictionarySetValue(copy, CFSTR("BatteryPacks"), packs);
    CFRelease(packs);
    return copy;
}

// A power source blob is an array of description dictionaries; IOKit finds a
// description by membership in that array, so a copy whose battery entry is
// replaced is still self-consistent for IOPSCopyPowerSourcesList and
// IOPSGetPowerSourceDescription. Takes the caller's reference to `blob` and
// returns one; anything that is not that shape comes back untouched.
static CFTypeRef vpBlobWithHealth(CFTypeRef blob) {
    static atomic_int logged;
    if (!blob || CFGetTypeID(blob) != CFArrayGetTypeID())
        return blob;
    CFArrayRef sources = blob;
    CFIndex count = CFArrayGetCount(sources);
    CFMutableArrayRef copy = NULL;
    for (CFIndex index = 0; index < count; index++) {
        CFTypeRef source = CFArrayGetValueAtIndex(sources, index);
        if (!vpNeedsHealth(source))
            continue;
        CFDictionaryRef description = vpCreateDescriptionWithHealth(source);
        if (!description)
            continue;
        if (!copy)
            copy = CFArrayCreateMutableCopy(kCFAllocatorDefault, count, sources);
        if (copy)
            CFArraySetValueAtIndex(copy, index, description);
        CFRelease(description);
    }
    if (!copy)
        return blob;
    vpLogOnce(&logged, "internal battery description given a healthy pack");
    CFRelease(blob);
    return copy;
}

static CFTypeRef vpCopyPowerSourcesInfo(void) {
    return vpBlobWithHealth(IOPSCopyPowerSourcesInfo());
}

static CFTypeRef vpCopyPowerSourcesByType(int type) {
    return vpBlobWithHealth(IOPSCopyPowerSourcesByType(type));
}

static IOReturn vpCopyPowerSourcesByTypePrecise(int type, CFTypeRef *blob) {
    if (!IOPSCopyPowerSourcesByTypePrecise) {
        if (!blob) return kIOReturnBadArgument;
        *blob = vpCopyPowerSourcesByType(type);
        return *blob ? kIOReturnSuccess : kIOReturnNoMemory;
    }
    IOReturn status = IOPSCopyPowerSourcesByTypePrecise(type, blob);
    if (blob && *blob)
        *blob = vpBlobWithHealth(*blob);
    return status;
}

// MARK: - Mitigation state

// Tokens notify_register_check handed out for the mitigation state, so
// notify_get_state can tell them apart. BatteryUsageUI registers, reads and
// cancels each time, and notifyd reuses a cancelled token for another name, so
// notify_cancel takes a token back out.
#define VP_TOKEN_SLOTS 8
static os_unfair_lock vpTokenLock = OS_UNFAIR_LOCK_INIT;
static int vpMitigationTokens[VP_TOKEN_SLOTS];
static int vpMitigationTokenCount;

static void vpRememberToken(int token) {
    os_unfair_lock_lock(&vpTokenLock);
    if (vpMitigationTokenCount < VP_TOKEN_SLOTS)
        vpMitigationTokens[vpMitigationTokenCount++] = token;
    os_unfair_lock_unlock(&vpTokenLock);
}

// Whether `token` is one of the remembered ones; `forget` also drops it.
static int vpIsMitigationToken(int token, int forget) {
    int found = 0;
    os_unfair_lock_lock(&vpTokenLock);
    for (int index = 0; index < vpMitigationTokenCount; index++) {
        if (vpMitigationTokens[index] != token)
            continue;
        found = 1;
        if (forget)
            vpMitigationTokens[index] = vpMitigationTokens[--vpMitigationTokenCount];
        break;
    }
    os_unfair_lock_unlock(&vpTokenLock);
    return found;
}

static uint32_t vpNotifyRegisterCheck(const char *name, int *token) {
    uint32_t status = notify_register_check(name, token);
    if (status == NOTIFY_STATUS_OK && token && name && strcmp(name, VP_MITIGATION_STATE_NAME) == 0)
        vpRememberToken(*token);
    return status;
}

static uint32_t vpNotifyGetState(int token, uint64_t *state) {
    static atomic_int logged;
    uint32_t status = notify_get_state(token, state);
    if (status == NOTIFY_STATUS_OK && state && *state == 0 && vpIsMitigationToken(token, 0)) {
        *state = VP_MITIGATION_STATE_NORMAL;
        vpLogOnce(&logged, "age-aware mitigation state 0 answered as 2 (normal peak performance)");
    }
    return status;
}

static uint32_t vpNotifyCancel(int token) {
    vpIsMitigationToken(token, 1);
    return notify_cancel(token);
}

// MARK: - Battery authentication

// MobileGestalt's HasBatteryModuleAuth, as BatteryUsageUI asks it
// (+[PLGestaltUtilities hasBatteryModuleAuth] on 27.0, the same key on 26.6.2).
#define VP_BATTERY_MODULE_AUTH CFSTR("D6/BMDrlb8V3WSiqL8gL+w")

static int vpHasBatteryAuthService;
static pthread_once_t vpBatteryAuthOnce = PTHREAD_ONCE_INIT;

static void vpLookUpBatteryAuthService(void) {
    io_service_t service = IOServiceGetMatchingService(MACH_PORT_NULL, IOServiceMatching("AppleBatteryAuth"));
    vpHasBatteryAuthService = service != IO_OBJECT_NULL;
    if (service != IO_OBJECT_NULL)
        IOObjectRelease(service);
}

// The guest's device identity says its battery authenticates itself, but no
// VM has the AppleBatteryAuth service that answers. Asked for a pack's
// genuineness, BatteryUsageUI then gets no authentication data and reports
// the status as unknown (-1), which batteryDataUnavailable also counts as
// "keep loading" (measured on 27.0: the answer is 1, 24 times per visit).
// Without the service the answer is no, as on a device with no battery
// authentication, and the pack counts as genuine; with it, nothing changes.
static Boolean vpGetBoolAnswer(CFStringRef question) {
    static atomic_int logged;
    Boolean answer = MGGetBoolAnswer(question);
    if (!answer || !question || !CFEqual(question, VP_BATTERY_MODULE_AUTH))
        return answer;
    pthread_once(&vpBatteryAuthOnce, vpLookUpBatteryAuthService);
    if (vpHasBatteryAuthService)
        return answer;
    vpLogOnce(&logged, "HasBatteryModuleAuth answered no: no AppleBatteryAuth service");
    return false;
}

int vphone_batteryhealthfix_version(void) { return 1; }

__attribute__((used, section("__DATA,__interpose"))) static const struct {
    const void *replacement;
    const void *replacee;
} vpInterpose[] = {
    {(const void *)vpCopyPowerSourcesInfo, (const void *)IOPSCopyPowerSourcesInfo},
    {(const void *)vpCopyPowerSourcesByType, (const void *)IOPSCopyPowerSourcesByType},
    {(const void *)vpCopyPowerSourcesByTypePrecise, (const void *)IOPSCopyPowerSourcesByTypePrecise},
    {(const void *)vpNotifyRegisterCheck, (const void *)notify_register_check},
    {(const void *)vpNotifyGetState, (const void *)notify_get_state},
    {(const void *)vpNotifyCancel, (const void *)notify_cancel},
    {(const void *)vpGetBoolAnswer, (const void *)MGGetBoolAnswer},
};
