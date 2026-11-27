#ifndef VPHONE_INJECTION_ENVIRONMENT_H
#define VPHONE_INJECTION_ENVIRONMENT_H

#include <crt_externs.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define VP_SYSTEM_HOOK "/usr/lib/SystemHook-vphone.dylib"

// The MIS hook. Inserted only into the processes that evaluate a code
// signature or a provisioning profile — see `vpIsMISFixTarget` below —
// rather than carried by every spawn. This insertion is the only way it gets
// there: no guest binary carries a load command for it.
//
// The inserted libraries' paths can be predefined, so the host tests can point
// them at files of their own; the guest builds use these.
#ifndef VP_MIS_FIX
#define VP_MIS_FIX "/usr/lib/libmisfix.dylib"
#endif

static int vpPathHasSuffix(const char *path, const char *suffix) {
    size_t length = path ? strlen(path) : 0;
    size_t want = strlen(suffix);
    return length >= want && strcmp(path + length - want, suffix) == 0;
}

// The processes that evaluate a code signature or a provisioning profile, and
// so the ones that have to agree about what device this is and what signatures
// are acceptable, plus the two that tell the host which device this is.
// Everything else spawns without libmisfix.
//
//   installd    runs `+[MICodeSigningVerifier
//               _validateSignatureAndCopyInfoForURL:withOptions:error:]`, which
//               is in MobileInstallation and calls libmis. This is the install.
//   misagent    installs the embedded profile and checks ProvisionedDevices.
//   SpringBoard asks MIS again at launch; without the hook an installed app is
//               refused there with 0xE8008026.
//   lockdownd   answers lockdown `GetValue UniqueDeviceID` (usbmuxd clients).
//   remoted     puts `UniqueDeviceID` in the RSD handshake (CoreDevice, Xcode).
//               These two get the MobileGestalt override only; the MIS detours
//               stand down in them (`MISFixProcessOnlyNeedsIdentity`).
//
// Both spawn hooks ask this, because the targets do not share a parent:
// installd and misagent are started through xpcproxy, which carries
// SystemHook, and SpringBoard (`POSIXSpawnType` App) is started by launchd
// itself, which carries only the launchd hook. Asking in one of them alone is
// what left SpringBoard without libmisfix.
//
// Matched on the end of the path so a bootstrap or cryptex copy of the same
// binary is caught too.
static int vpIsMISFixTarget(const char *path) {
    if (!path)
        return 0;
    return vpPathHasSuffix(path, "/usr/libexec/installd") ||
           vpPathHasSuffix(path, "/usr/libexec/misagent") ||
           vpPathHasSuffix(path, "/usr/libexec/lockdownd") ||
           vpPathHasSuffix(path, "/usr/libexec/remoted") ||
           vpPathHasSuffix(path, "/SpringBoard.app/SpringBoard");
}

// The library to insert alongside SystemHook for `path`, or NULL. NULL as well
// when the dylib is not installed, so a guest without it never gets a
// DYLD_INSERT_LIBRARIES entry naming a missing file.
static const char *vpMISFixFor(const char *path) {
    return vpIsMISFixTarget(path) && access(VP_MIS_FIX, R_OK) == 0 ? VP_MIS_FIX : NULL;
}

// The battery health hook, which fills in the health half of the internal
// battery's power source description; see
// BatteryHealthFix/libbatteryhealthfix.c. Inserted rather than loaded by
// SystemHook because it interposes: the table has to be in place before
// BatteryUsageUI.bundle is bound.
#ifndef VP_BATTERY_HEALTH_FIX
#define VP_BATTERY_HEALTH_FIX "/usr/lib/libbatteryhealthfix.dylib"
#endif

// Settings, the one process that shows Battery Health. Asked by both spawn
// hooks, like the MIS targets, so it holds whichever of them starts the app.
static int vpIsBatteryHealthFixTarget(const char *path) {
    return path && vpPathHasSuffix(path, "/Preferences.app/Preferences");
}

static const char *vpBatteryHealthFixFor(const char *path) {
    return vpIsBatteryHealthFixTarget(path) && access(VP_BATTERY_HEALTH_FIX, R_OK) == 0
               ? VP_BATTERY_HEALTH_FIX
               : NULL;
}

// The DeviceHub hook, which lets Xcode's device viewer stream the guest's
// screen; see DeviceHubFix/libdevicehubfix.c. Inserted because its
// interposes have to be in place when the target's imports are bound.
#ifndef VP_DEVICEHUB_FIX
#define VP_DEVICEHUB_FIX "/usr/lib/libdevicehubfix.dylib"
#endif

// cryptexd, which stages and grafts the developer disk image, the DDI's
// display server, and avconferenced, which captures and encodes the stream.
// The DDI is mounted under /System/Developer, so the suffixes are matched like
// the other targets.
static int vpIsDeviceHubFixTarget(const char *path) {
    return path && (vpPathHasSuffix(path, "/usr/libexec/cryptexd") ||
                    vpPathHasSuffix(path, "/usr/libexec/dtremotedisplayd") ||
                    vpPathHasSuffix(path, "/usr/libexec/dtdeviceinfod") ||
                    vpPathHasSuffix(path, "/usr/libexec/avconferenced"));
}

static const char *vpDeviceHubFixFor(const char *path) {
    return vpIsDeviceHubFixTarget(path) && access(VP_DEVICEHUB_FIX, R_OK) == 0 ? VP_DEVICEHUB_FIX : NULL;
}

// The device name hook, which pins the name the host chose; see
// DeviceName/libdevicename.c. Inserted because it interposes the
// SystemConfiguration imports of the two processes below, which have to be
// rebound before either runs.
#ifndef VP_DEVICE_NAME
#define VP_DEVICE_NAME "/usr/lib/libdevicename.dylib"
#endif

// configd publishes the name into the dynamic store, and lockdownd is where a
// host or Settings renames the device. lockdownd also takes libmisfix, so it
// is the one process that gets two libraries.
static int vpIsDeviceNameTarget(const char *path) {
    return path && (vpPathHasSuffix(path, "/usr/libexec/configd") ||
                    vpPathHasSuffix(path, "/usr/libexec/lockdownd"));
}

static const char *vpDeviceNameFor(const char *path) {
    return vpIsDeviceNameTarget(path) && access(VP_DEVICE_NAME, R_OK) == 0 ? VP_DEVICE_NAME : NULL;
}

// The most libraries one process takes beside SystemHook.
#define VP_INSERTED_LIBRARIES_MAX 4

typedef struct {
    const char *paths[VP_INSERTED_LIBRARIES_MAX];
    size_t count;
} VPInsertedLibraries;

// The libraries the spawn hooks insert beside SystemHook for `path`, in
// insertion order. Each is listed only when it is installed. The MIS, battery
// health and DeviceHub targets do not overlap; the device name targets overlap
// the MIS ones at lockdownd, which gets libmisfix and then libdevicename.
static VPInsertedLibraries vpInsertedLibrariesFor(const char *path) {
    VPInsertedLibraries result = {{0}, 0};
    const char *const candidates[] = {
        vpMISFixFor(path),
        vpBatteryHealthFixFor(path),
        vpDeviceHubFixFor(path),
        vpDeviceNameFor(path),
    };
    for (size_t index = 0; index < sizeof(candidates) / sizeof(candidates[0]); index++) {
        if (candidates[index] && result.count < VP_INSERTED_LIBRARIES_MAX)
            result.paths[result.count++] = candidates[index];
    }
    return result;
}

// The first of those libraries, or NULL.
static const char *vpInsertedLibraryFor(const char *path) {
    VPInsertedLibraries libraries = vpInsertedLibrariesFor(path);
    return libraries.count ? libraries.paths[0] : NULL;
}

// "+misfix+devicename" for the libraries' file names, for the spawn logs:
// "/usr/lib/libmisfix.dylib" is logged as "+misfix", as it always was.
static void vpDescribeInsertedLibraries(const VPInsertedLibraries *libraries, char *buffer, size_t size) {
    if (!size)
        return;
    buffer[0] = '\0';
    size_t used = 0;
    for (size_t index = 0; libraries && index < libraries->count; index++) {
        const char *name = strrchr(libraries->paths[index], '/');
        name = name ? name + 1 : libraries->paths[index];
        if (strncmp(name, "lib", 3) == 0)
            name += 3;
        size_t length = strlen(name);
        if (length > 6 && strcmp(name + length - 6, ".dylib") == 0)
            length -= 6;
        int written = snprintf(buffer + used, size - used, "+%.*s", (int)length, name);
        if (written < 0 || (size_t)written >= size - used)
            return;
        used += (size_t)written;
    }
}

typedef struct {
    char **values;
    char *hook;
    char *root;
} VPInjectionEnvironment;

static const char *vpEnvValue(char *const env[], const char *name) {
    if (!env)
        return NULL;
    size_t length = strlen(name);
    for (size_t i = 0; env[i]; i++) {
        if (strncmp(env[i], name, length) == 0 && env[i][length] == '=')
            return env[i] + length + 1;
    }
    return NULL;
}

static int vpEnvIsOne(char *const env[], const char *name) {
    const char *value = vpEnvValue(env, name);
    return value && strcmp(value, "1") == 0;
}

static int vpInjectionDisabled(char *const env[]) {
    return vpEnvIsOne(env, "DISABLE_TWEAKS") || vpEnvIsOne(env, "_SafeMode") || vpEnvIsOne(env, "_MSSafeMode");
}

// Whether `library` is already one of the colon-separated entries in `paths`.
static int vpListHasPath(const char *paths, const char *library) {
    if (!paths || !library)
        return 0;
    const size_t length = strlen(library);
    for (const char *start = paths; *start;) {
        const char *end = strchr(start, ':');
        size_t count = end ? (size_t)(end - start) : strlen(start);
        if (count == length && strncmp(start, library, count) == 0)
            return 1;
        if (!end)
            break;
        start = end + 1;
    }
    return 0;
}

static int vpHasHook(const char *paths) {
    return vpListHasPath(paths, VP_SYSTEM_HOOK);
}

// Keep the bootstrap path with the injected hooks across xpcproxy's new envp.
//
// `extras` are `extraCount` libraries to insert alongside the system hook, in
// order; NULL and empty entries are skipped. Only the ones not already listed
// are added, so this is safe to run over an environment that has been through
// here before.
static VPInjectionEnvironment vpInsertHookLibraries(char *const env[], const char *root,
                                                    const char *const extras[], size_t extraCount) {
    VPInjectionEnvironment result = {0};
    size_t count = 0;
    size_t dyld = (size_t)-1;
    size_t jbRoot = (size_t)-1;
    if (env) {
        while (count < 4096 && env[count]) {
            if (strncmp(env[count], "DYLD_INSERT_LIBRARIES=", 22) == 0)
                dyld = count;
            if (strncmp(env[count], "VPHONE_JB_ROOT=", 15) == 0)
                jbRoot = count;
            count++;
        }
        if (count == 4096)
            return result;
    }
    const char *existing = dyld == (size_t)-1 ? NULL : env[dyld] + 22;
    int addHook = !vpListHasPath(existing, VP_SYSTEM_HOOK);
    // The extras still missing, without repeats, in the caller's order.
    const char *adding[VP_INSERTED_LIBRARIES_MAX];
    size_t addCount = 0;
    for (size_t index = 0; extras && index < extraCount && addCount < VP_INSERTED_LIBRARIES_MAX; index++) {
        const char *extra = extras[index];
        if (!extra || !*extra || strcmp(extra, VP_SYSTEM_HOOK) == 0 || vpListHasPath(existing, extra))
            continue;
        int repeated = 0;
        for (size_t earlier = 0; earlier < addCount; earlier++)
            repeated = repeated || strcmp(adding[earlier], extra) == 0;
        if (!repeated)
            adding[addCount++] = extra;
    }
    int addExtra = addCount > 0;
    int addRoot = root && *root &&
                  (jbRoot == (size_t)-1 || strcmp(env[jbRoot] + 15, root) != 0);
    if (!addHook && !addExtra && !addRoot)
        return result;
    if (addHook || addExtra) {
        size_t size = strlen("DYLD_INSERT_LIBRARIES=") + 1;
        if (addHook)
            size += strlen(VP_SYSTEM_HOOK) + 1;
        for (size_t index = 0; index < addCount; index++)
            size += strlen(adding[index]) + 1;
        if (existing && *existing)
            size += strlen(existing) + 1;
        result.hook = malloc(size);
        if (!result.hook)
            return result;
        // The inserted libraries go first, before whatever the caller already
        // had, so their interposes are in place before anything else loads.
        int written = snprintf(result.hook, size, "DYLD_INSERT_LIBRARIES=");
        int listed = 0;
        if (addHook) {
            written += snprintf(result.hook + written, size - (size_t)written, "%s", VP_SYSTEM_HOOK);
            listed = 1;
        }
        for (size_t index = 0; index < addCount; index++) {
            written += snprintf(result.hook + written, size - (size_t)written, "%s%s",
                                listed ? ":" : "", adding[index]);
            listed = 1;
        }
        if (existing && *existing)
            snprintf(result.hook + written, size - (size_t)written, ":%s", existing);
    }
    if (addRoot) {
        size_t size = strlen("VPHONE_JB_ROOT=") + strlen(root) + 1;
        result.root = malloc(size);
        if (!result.root) {
            free(result.hook);
            return (VPInjectionEnvironment){0};
        }
        snprintf(result.root, size, "VPHONE_JB_ROOT=%s", root);
    }
    // Either addition rewrites the whole DYLD_INSERT_LIBRARIES entry, so an
    // environment that already names SystemHook still gets the extra library.
    const int addLibraries = addHook || addExtra;
    result.values = calloc(count + (addLibraries && dyld == (size_t)-1) +
                               (addRoot && jbRoot == (size_t)-1) + 1, sizeof(char *));
    if (!result.values) {
        free(result.hook);
        free(result.root);
        return (VPInjectionEnvironment){0};
    }
    for (size_t i = 0; i < count; i++)
        result.values[i] = addLibraries && i == dyld ? result.hook :
                           addRoot && i == jbRoot ? result.root : env[i];
    if (addLibraries && dyld == (size_t)-1)
        result.values[count++] = result.hook;
    if (addRoot && jbRoot == (size_t)-1)
        result.values[count] = result.root;
    return result;
}

// One extra library, or none when `extra` is NULL.
static VPInjectionEnvironment vpInsertHooks(char *const env[], const char *root, const char *extra) {
    const char *const extras[] = {extra};
    return vpInsertHookLibraries(env, root, extras, extra ? 1 : 0);
}

// The libraries `vpInsertedLibrariesFor` chose.
static VPInjectionEnvironment vpInsertHooksFor(char *const env[], const char *root,
                                               const VPInsertedLibraries *libraries) {
    return vpInsertHookLibraries(env, root, libraries ? libraries->paths : NULL,
                                 libraries ? libraries->count : 0);
}

static void vpFreeEnvironment(VPInjectionEnvironment *environment) {
    free(environment->values);
    free(environment->hook);
    free(environment->root);
}

// The root, on its own: the environment that named it is scrubbed below, and
// getenv would hand back the very string the scrub zeroes.
static char *vpJailbreakRootStorage;

static const char *vpJailbreakRoot(void) {
    if (!vpJailbreakRootStorage)
        vpJailbreakRootStorage = strdup(getenv("VPHONE_JB_ROOT"));
    return vpJailbreakRootStorage;
}

// Hide the injection from this process. getenv, NSProcessInfo.environment and
// sysctl(KERN_PROCARGS2) all read the same strings on the exec stack (the
// sysctl copies the stack, not a kernel copy), so both are covered by zeroing
// the strings and dropping the entries. DYLD_INSERT_LIBRARIES must exist when
// dyld binds this library, which is why this runs in a constructor and not
// before; children still get both, since the spawn hooks add them back.
static void vpScrubInjectionEnvironment(void) {
    (void)vpJailbreakRoot();
    char **env = *_NSGetEnviron();
    size_t kept = 0;
    for (size_t i = 0; env[i]; i++) {
        if (strncmp(env[i], "VPHONE_JB_ROOT=", 15) == 0 || strncmp(env[i], "DYLD_INSERT_LIBRARIES=", 22) == 0) {
            // Through a volatile pointer, so the zeroing is not dead-store-eliminated.
            for (volatile char *c = env[i]; *c; c++)
                *c = 0;
            continue;
        }
        env[kept++] = env[i];
    }
    for (size_t i = kept; env[i]; i++)
        env[i] = NULL;
}

#endif
