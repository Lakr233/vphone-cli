// The inserted libraries live under a directory of the test's own, which the
// Makefile names, so the selection can be checked with every one installed.
#ifndef VP_TEST_LIBRARY_DIR
#define VP_TEST_LIBRARY_DIR "/tmp/vphone-injection-environment-tests"
#endif
#define VP_MIS_FIX VP_TEST_LIBRARY_DIR "/libmisfix.dylib"
#define VP_BATTERY_HEALTH_FIX VP_TEST_LIBRARY_DIR "/libbatteryhealthfix.dylib"
#define VP_DEVICEHUB_FIX VP_TEST_LIBRARY_DIR "/libdevicehubfix.dylib"
#define VP_DEVICE_NAME VP_TEST_LIBRARY_DIR "/libdevicename.dylib"

#include "../Shared/InjectionEnvironment.h"
#include "../Shared/AttitudeProcess.h"
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/stat.h>

#define EXTRA "/usr/lib/extra.dylib"

static const char *value(char *const env[], const char *name) { return vpEnvValue(env, name); }

static size_t count(char *const env[]) {
    size_t total = 0;
    while (env[total])
        total++;
    return total;
}

// A spawn with no DYLD_INSERT_LIBRARIES gets both, SystemHook first.
static void insertsBoth(void) {
    char *env[] = {"HOME=/var/mobile", NULL};
    VPInjectionEnvironment result = vpInsertHooks(env, NULL, EXTRA);
    assert(result.values);
    assert(count(result.values) == 2);
    assert(strcmp(value(result.values, "DYLD_INSERT_LIBRARIES"), VP_SYSTEM_HOOK ":" EXTRA) == 0);
    vpFreeEnvironment(&result);
}

// The environment already names SystemHook — launchd passes its own to a job
// it starts directly — and the extra library must still be added.
static void addsExtraBesideAnExistingHook(void) {
    char *env[] = {"DYLD_INSERT_LIBRARIES=" VP_SYSTEM_HOOK, "HOME=/var/mobile", NULL};
    VPInjectionEnvironment result = vpInsertHooks(env, NULL, EXTRA);
    assert(result.values);
    assert(count(result.values) == 2);
    assert(strcmp(value(result.values, "DYLD_INSERT_LIBRARIES"), EXTRA ":" VP_SYSTEM_HOOK) == 0);
    vpFreeEnvironment(&result);
}

static void leavesACompleteEnvironmentAlone(void) {
    char *env[] = {"DYLD_INSERT_LIBRARIES=" VP_SYSTEM_HOOK ":" EXTRA, NULL};
    VPInjectionEnvironment result = vpInsertHooks(env, NULL, EXTRA);
    assert(!result.values);
    vpFreeEnvironment(&result);
}

static void namesTheMISFixTargets(void) {
    assert(vpIsMISFixTarget("/usr/libexec/installd"));
    assert(vpIsMISFixTarget("/usr/libexec/misagent"));
    assert(vpIsMISFixTarget("/usr/libexec/lockdownd"));
    assert(vpIsMISFixTarget("/usr/libexec/remoted"));
    assert(vpIsMISFixTarget("/System/Library/CoreServices/SpringBoard.app/SpringBoard"));
    assert(!vpIsMISFixTarget("/usr/libexec/xpcproxy"));
    assert(!vpIsMISFixTarget("/usr/libexec/installdx"));
    assert(!vpIsMISFixTarget(NULL));
}

static void namesTheBatteryHealthFixTarget(void) {
    assert(vpIsBatteryHealthFixTarget("/Applications/Preferences.app/Preferences"));
    assert(!vpIsBatteryHealthFixTarget("/Applications/Preferences.app/PreferencesX"));
    assert(!vpIsBatteryHealthFixTarget("/System/Library/CoreServices/SpringBoard.app/SpringBoard"));
    assert(!vpIsBatteryHealthFixTarget(NULL));
    // The two hooks never compete for one process's single extra slot.
    assert(!vpIsMISFixTarget("/Applications/Preferences.app/Preferences"));
    assert(!vpInsertedLibraryFor(NULL));
}

static void namesTheDeviceHubFixTarget(void) {
    // The developer disk image is mounted under /System/Developer.
    assert(vpIsDeviceHubFixTarget("/System/Developer/usr/libexec/dtremotedisplayd"));
    assert(vpIsDeviceHubFixTarget("/usr/libexec/dtremotedisplayd"));
    assert(vpIsDeviceHubFixTarget("/usr/libexec/cryptexd"));
    assert(vpIsDeviceHubFixTarget("/System/Developer/usr/libexec/dtdeviceinfod"));
    assert(vpIsDeviceHubFixTarget("/usr/libexec/avconferenced"));
    assert(!vpIsDeviceHubFixTarget("/usr/libexec/dtdeviceinfodx"));
    assert(!vpIsDeviceHubFixTarget("/usr/libexec/cryptexdx"));
    assert(!vpIsDeviceHubFixTarget("/usr/libexec/avconferencedx"));
    assert(!vpIsDeviceHubFixTarget("/System/Developer/usr/libexec/dtremotedisplaydx"));
    assert(!vpIsDeviceHubFixTarget("/System/Developer/usr/libexec/remoted"));
    assert(!vpIsDeviceHubFixTarget(NULL));
    assert(!vpIsMISFixTarget("/System/Developer/usr/libexec/dtremotedisplayd"));
    assert(!vpIsMISFixTarget("/usr/libexec/cryptexd"));
    assert(!vpIsBatteryHealthFixTarget("/System/Developer/usr/libexec/dtremotedisplayd"));
}

static void namesTheDeviceNameTargets(void) {
    assert(vpIsDeviceNameTarget("/usr/libexec/configd"));
    assert(vpIsDeviceNameTarget("/usr/libexec/lockdownd"));
    assert(!vpIsDeviceNameTarget("/usr/libexec/configdx"));
    assert(!vpIsDeviceNameTarget("/usr/libexec/lockdowndx"));
    assert(!vpIsDeviceNameTarget("/usr/libexec/configd/"));
    assert(!vpIsDeviceNameTarget("/usr/sbin/configd"));
    assert(!vpIsDeviceNameTarget("/usr/libexec/remoted"));
    assert(!vpIsDeviceNameTarget("/usr/libexec/installd"));
    assert(!vpIsDeviceNameTarget("configd"));
    assert(!vpIsDeviceNameTarget(NULL));
    // configd is nobody else's target; lockdownd is libmisfix's too.
    assert(!vpIsMISFixTarget("/usr/libexec/configd"));
    assert(!vpIsBatteryHealthFixTarget("/usr/libexec/configd"));
    assert(!vpIsDeviceHubFixTarget("/usr/libexec/configd"));
    assert(vpIsMISFixTarget("/usr/libexec/lockdownd"));
}

static void installLibraries(void) {
    if (mkdir(VP_TEST_LIBRARY_DIR, 0755) != 0)
        assert(errno == EEXIST);
    const char *const paths[] = {VP_MIS_FIX, VP_BATTERY_HEALTH_FIX, VP_DEVICEHUB_FIX, VP_DEVICE_NAME};
    for (size_t index = 0; index < sizeof(paths) / sizeof(paths[0]); index++) {
        int fd = open(paths[index], O_WRONLY | O_CREAT | O_TRUNC, 0644);
        assert(fd >= 0);
        close(fd);
    }
}

// With every library installed, each process gets its own, and lockdownd gets
// two: libmisfix first, as before, then libdevicename.
static void selectsEveryLibraryOfATarget(void) {
    installLibraries();
    VPInsertedLibraries lockdownd = vpInsertedLibrariesFor("/usr/libexec/lockdownd");
    assert(lockdownd.count == 2);
    assert(strcmp(lockdownd.paths[0], VP_MIS_FIX) == 0);
    assert(strcmp(lockdownd.paths[1], VP_DEVICE_NAME) == 0);
    assert(strcmp(vpInsertedLibraryFor("/usr/libexec/lockdownd"), VP_MIS_FIX) == 0);

    VPInsertedLibraries configd = vpInsertedLibrariesFor("/usr/libexec/configd");
    assert(configd.count == 1);
    assert(strcmp(configd.paths[0], VP_DEVICE_NAME) == 0);

    VPInsertedLibraries installd = vpInsertedLibrariesFor("/usr/libexec/installd");
    assert(installd.count == 1 && strcmp(installd.paths[0], VP_MIS_FIX) == 0);
    VPInsertedLibraries settings = vpInsertedLibrariesFor("/Applications/Preferences.app/Preferences");
    assert(settings.count == 1 && strcmp(settings.paths[0], VP_BATTERY_HEALTH_FIX) == 0);
    VPInsertedLibraries cryptexd = vpInsertedLibrariesFor("/usr/libexec/cryptexd");
    assert(cryptexd.count == 1 && strcmp(cryptexd.paths[0], VP_DEVICEHUB_FIX) == 0);
    assert(vpInsertedLibrariesFor("/usr/libexec/xpcproxy").count == 0);
    assert(vpInsertedLibrariesFor(NULL).count == 0);

    char names[96];
    vpDescribeInsertedLibraries(&lockdownd, names, sizeof(names));
    assert(strcmp(names, "+misfix+devicename") == 0);
    vpDescribeInsertedLibraries(&settings, names, sizeof(names));
    assert(strcmp(names, "+batteryhealthfix") == 0);
    vpDescribeInsertedLibraries(&(VPInsertedLibraries){{0}, 0}, names, sizeof(names));
    assert(strcmp(names, "") == 0);

    // A missing library is left out, and the other still goes in.
    assert(unlink(VP_DEVICE_NAME) == 0);
    lockdownd = vpInsertedLibrariesFor("/usr/libexec/lockdownd");
    assert(lockdownd.count == 1 && strcmp(lockdownd.paths[0], VP_MIS_FIX) == 0);
    assert(vpInsertedLibrariesFor("/usr/libexec/configd").count == 0);
}

// lockdownd's two libraries go in after SystemHook, in order.
static void insertsSeveralLibraries(void) {
    char *env[] = {"HOME=/var/root", NULL};
    const VPInsertedLibraries libraries = {{VP_MIS_FIX, VP_DEVICE_NAME}, 2};
    VPInjectionEnvironment result = vpInsertHooksFor(env, NULL, &libraries);
    assert(result.values);
    assert(count(result.values) == 2);
    assert(strcmp(value(result.values, "DYLD_INSERT_LIBRARIES"),
                  VP_SYSTEM_HOOK ":" VP_MIS_FIX ":" VP_DEVICE_NAME) == 0);
    vpFreeEnvironment(&result);
}

// An environment that already carries SystemHook and libmisfix — launchd's
// own, or one from before libdevicename existed — gains only the missing one.
static void addsOnlyTheMissingLibrary(void) {
    char *env[] = {"DYLD_INSERT_LIBRARIES=" VP_SYSTEM_HOOK ":" VP_MIS_FIX, NULL};
    const VPInsertedLibraries libraries = {{VP_MIS_FIX, VP_DEVICE_NAME}, 2};
    VPInjectionEnvironment result = vpInsertHooksFor(env, NULL, &libraries);
    assert(result.values);
    assert(count(result.values) == 1);
    assert(strcmp(value(result.values, "DYLD_INSERT_LIBRARIES"),
                  VP_DEVICE_NAME ":" VP_SYSTEM_HOOK ":" VP_MIS_FIX) == 0);
    vpFreeEnvironment(&result);

    char *complete[] = {"DYLD_INSERT_LIBRARIES=" VP_SYSTEM_HOOK ":" VP_MIS_FIX ":" VP_DEVICE_NAME, NULL};
    result = vpInsertHooksFor(complete, NULL, &libraries);
    assert(!result.values);
    vpFreeEnvironment(&result);
}

// Repeats, empty entries and SystemHook itself are not listed twice.
static void skipsRepeatedLibraries(void) {
    char *env[] = {NULL};
    const char *const extras[] = {VP_MIS_FIX, "", NULL, VP_MIS_FIX, VP_SYSTEM_HOOK, VP_DEVICE_NAME};
    VPInjectionEnvironment result = vpInsertHookLibraries(env, NULL, extras, sizeof(extras) / sizeof(extras[0]));
    assert(result.values);
    assert(strcmp(value(result.values, "DYLD_INSERT_LIBRARIES"),
                  VP_SYSTEM_HOOK ":" VP_MIS_FIX ":" VP_DEVICE_NAME) == 0);
    vpFreeEnvironment(&result);
}

// The process's own environment loses both variables, root survives where the
// hooks read it, and a child built from that scrubbed environment still gets
// both: the chain of injection must not end at the first spawn.
static void scrubsOwnEnvironmentAndKeepsTheChain(void) {
    assert(setenv("VPHONE_JB_ROOT", "/private/var/jb", 1) == 0);
    assert(setenv("DYLD_INSERT_LIBRARIES", VP_SYSTEM_HOOK, 1) == 0);
    assert(setenv("HOME", "/var/mobile", 1) == 0);
    vpScrubInjectionEnvironment();
    assert(getenv("VPHONE_JB_ROOT") == NULL);
    assert(getenv("DYLD_INSERT_LIBRARIES") == NULL);
    assert(strcmp(getenv("HOME"), "/var/mobile") == 0);
    for (char **e = *_NSGetEnviron(); *e; e++)
        assert(strncmp(*e, "VPHONE_JB_ROOT=", 15) != 0 && strncmp(*e, "DYLD_INSERT_LIBRARIES=", 22) != 0);
    assert(strcmp(vpJailbreakRoot(), "/private/var/jb") == 0);
    assert(vpJailbreakRoot() == vpJailbreakRoot());
    char *child[] = {"HOME=/var/mobile", NULL};
    VPInjectionEnvironment result = vpInsertHooks(child, vpJailbreakRoot(), NULL);
    assert(strcmp(value(result.values, "DYLD_INSERT_LIBRARIES"), VP_SYSTEM_HOOK) == 0);
    assert(strcmp(value(result.values, "VPHONE_JB_ROOT"), "/private/var/jb") == 0);
    vpFreeEnvironment(&result);
    // Scrubbing again, with nothing left, is harmless.
    vpScrubInjectionEnvironment();
    assert(getenv("HOME") != NULL);
}

int main(void) {
    assert(!vpAttitudeAllowsProcess(NULL));
    assert(!vpAttitudeAllowsProcess("SpringBoard.app/SpringBoard"));
    assert(!vpAttitudeAllowsProcess("/System/Library/CoreServices/SpringBoard.app/SpringBoard"));
    assert(!vpAttitudeAllowsProcess("/private/System/Library/CoreServices/AccessibilityUIServer.app/AccessibilityUIServer"));
    assert(!vpAttitudeAllowsProcess("/var/jb/Applications/SpringBoard.app/SpringBoard"));
    assert(vpAttitudeAllowsProcess("/Applications/Preferences.app/Preferences"));
    assert(vpAttitudeAllowsProcess("/private/var/containers/Bundle/Application/UUID/Motion.app/Motion"));
    insertsBoth();
    addsExtraBesideAnExistingHook();
    leavesACompleteEnvironmentAlone();
    namesTheMISFixTargets();
    namesTheBatteryHealthFixTarget();
    namesTheDeviceHubFixTarget();
    namesTheDeviceNameTargets();
    selectsEveryLibraryOfATarget();
    insertsSeveralLibraries();
    addsOnlyTheMissingLibrary();
    skipsRepeatedLibraries();
    scrubsOwnEnvironmentAndKeepsTheChain();
    puts("InjectionEnvironmentTests: ok");
    return 0;
}
