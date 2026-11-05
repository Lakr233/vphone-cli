#include "../Shared/InjectionEnvironment.h"
#include "../Shared/AttitudeProcess.h"
#include "../Shared/JetsamLimits.h"
#include "../Shared/RootHideLoaderLinks.h"
#include "../Shared/VPhoneX1Spawn.h"
#include <crt_externs.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static int vpInXPCProxy;
static int vpInBootstrap;
extern void vpInstallSurfaceAdapter(void);
extern void vpInstallIOS18GPUTransport(void);

static int vpIsBootstrapPath(const char *path, const char *root) {
    if (path && strncmp(path, "/var/jb/", 8) == 0)
        return 1;
    if (path && root && strncmp(root, "/private/var/", 13) == 0 &&
        strncmp(path, "/var/", 5) == 0)
        root += 8;
    size_t length = root ? strlen(root) : 0;
    return path && length && strncmp(path, root, length) == 0 && path[length] == '/';
}

static int vpIsAppPath(const char *path) {
    return path && path[0] == '/' && strstr(path, ".app/") != NULL;
}

// The camera daemon hook serves every camera client, so the daemon is a
// target even though it is neither an app nor a bootstrap executable.
static int vpIsCameraDaemon(const char *path) {
    static const char suffix[] = "/usr/libexec/cameracaptured";
    size_t length = path ? strlen(path) : 0;
    return length >= sizeof(suffix) - 1 && strcmp(path + length - (sizeof(suffix) - 1), suffix) == 0;
}

static int vpIsMotionDaemon(const char *path) {
    return vpPathHasSuffix(path, "/usr/libexec/backboardd");
}

static int vpIsInjectionTarget(const char *path) {
    if (!path)
        return 0;
    const char *root = getenv("VPHONE_JB_ROOT");
    return vpIsBootstrapPath(path, root) || vpIsAppPath(path) || vpIsCameraDaemon(path) || vpIsMotionDaemon(path) ||
           (vpInBootstrap && path[0] != '/');
}

// Every process loads this hook, root or not, so its logs must be writable by
// all of them. The first writer is always a root xpcproxy, and a file it
// creates 0644 silently drops every line from a mobile process — SpringBoard
// and every app looked as though they never carried the hook. The owner makes
// it world-writable on each open; for anyone else fchmod fails harmlessly.
static int vpOpenLog(const char *name) {
    char path[PATH_MAX];
    int used = snprintf(path, sizeof(path), "/var/mobile/Library/Caches/%s", name);
    int fd = used > 0 && (size_t)used < sizeof(path)
                 ? open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0666)
                 : -1;
    if (fd >= 0) {
        fchmod(fd, 0666);
        return fd;
    }
    const char *home = getenv("CFFIXED_USER_HOME");
    if (!home)
        home = getenv("HOME");
    if (!home)
        return -1;
    used = snprintf(path, sizeof(path), "%s/Library/Caches/%s", home, name);
    return used > 0 && (size_t)used < sizeof(path)
               ? open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0644)
               : -1;
}

static void vpLogSpawn(const char *path, const char *decision) {
    int fd = vpOpenLog("vphone-systemhook-spawn.log");
    if (fd < 0)
        return;
    dprintf(fd, "pid=%d path=%s decision=%s\n", getpid(), path ? path : "<null>", decision);
    close(fd);
}

static void vpPrepareLoaderLink(const char *path) {
    const char *root = getenv("VPHONE_JB_ROOT");
    int status = vpEnsureRootHideLoaderLink(path, root);
    if (!status && (!path || !strstr(path, "/.jbroot-")))
        return;
    int fd = vpOpenLog("vphone-systemhook-spawn.log");
    if (fd >= 0) {
        dprintf(fd, "pid=%d path=%s loader_link_errno=%d\n", getpid(), path ? path : "<null>", status);
        close(fd);
    }
}

// Every child chain-loads SystemHook, whatever its environment says: a shell
// or sshd that rebuilds its child's environment would otherwise drop it.
// DISABLE_TWEAKS and safe mode are honored in the child's constructor, which
// then skips ElleKit. Only bootstrap, app and camera targets are logged and
// get their loader links prepared.
static VPInjectionEnvironment vpPrepareChild(const char *path, char *const envp[], const char *kind) {
    const VPInsertedLibraries libraries = vpInsertedLibrariesFor(path);
    VPInjectionEnvironment injected = vpInsertHooksFor(envp, getenv("VPHONE_JB_ROOT"), &libraries);
    if (vpIsInjectionTarget(path) || vpIsMISFixTarget(path) || vpIsDeviceHubFixTarget(path) ||
        vpIsDeviceNameTarget(path)) {
        vpPrepareLoaderLink(path);
        char names[96];
        vpDescribeInsertedLibraries(&libraries, names, sizeof(names));
        char decision[160];
        snprintf(decision, sizeof(decision), "%s%s%s%s", kind, !injected.values ? "unchanged" : "inserted",
                 names, vpInjectionDisabled(envp) ? "-tweaks-disabled" : "");
        vpLogSpawn(path, decision);
    }
    return injected;
}

static int vpSpawnP(pid_t *restrict pid, const char *restrict path, const posix_spawn_file_actions_t *restrict actions,
                    const posix_spawnattr_t *restrict attributes, char *const argv[restrict],
                    char *const envp[restrict]) {
    VPInjectionEnvironment injected = vpPrepareChild(path, envp, "");
    VPJetsamLimits limits = vpRaiseJetsamLimits(getenv("VPHONE_JB_ROOT"), path, attributes, envp);
    int status = vpSpawnWithInheritedX1Port(
        posix_spawnp, pid, path, actions, attributes, argv,
        injected.values ? injected.values : envp
    );
    vpRestoreJetsamLimits(&limits);
    vpFreeEnvironment(&injected);
    return status;
}

static int vpSpawn(pid_t *restrict pid, const char *restrict path, const posix_spawn_file_actions_t *restrict actions,
                   const posix_spawnattr_t *restrict attributes, char *const argv[restrict],
                   char *const envp[restrict]) {
    VPInjectionEnvironment injected = vpPrepareChild(path, envp, "");
    VPJetsamLimits limits = vpRaiseJetsamLimits(getenv("VPHONE_JB_ROOT"), path, attributes, envp);
    int status = vpSpawnWithInheritedX1Port(
        posix_spawn, pid, path, actions, attributes, argv,
        injected.values ? injected.values : envp
    );
    vpRestoreJetsamLimits(&limits);
    vpFreeEnvironment(&injected);
    return status;
}

static int vpExecve(const char *path, char *const argv[], char *const envp[]) {
    VPInjectionEnvironment injected = vpPrepareChild(path, envp, "exec-");
    int status = execve(path, argv, injected.values ? injected.values : envp);
    int savedErrno = errno;
    vpFreeEnvironment(&injected);
    errno = savedErrno;
    return status;
}

// cfw install and the environment update place the camera hooks in /usr/lib.
// They need no tweak loader: each installs its own Objective-C hooks.
#define VP_CAMERA_DAEMON_HOOK "/usr/lib/libvcamcaptured.dylib"
#define VP_CAMERA_APP_HOOK "/usr/lib/libcamfix.dylib"
#define VP_GYROSCOPE_HOOK "/usr/lib/libvphonegyro.dylib"
#define VP_ACCELEROMETER_HOOK "/usr/lib/libvphoneaccelerometer.dylib"
#define VP_HINGE_HOOK "/usr/lib/libvphonehinge.dylib"
#define VP_FOLD_GUARD "/usr/lib/libvphonefoldguard.dylib"
// The Duo's inner display: published by backboardd, resolved and shown by
// SpringBoard. See FoldDisplay/libvphonefolddisplay.m.
#define VP_FOLD_DISPLAY "/usr/lib/libvphonefolddisplay.dylib"
#define VP_ATTITUDE_HOOK "/usr/lib/libvphoneattitude.dylib"
#define VP_AVFOUNDATION "/System/Library/Frameworks/AVFoundation.framework/AVFoundation"
// The haptics fix rides the same route and needs no loader of its own. See
// HapticsFix/libhapticsfix.c for what it answers and why SpringBoard is the
// target.
#define VP_HAPTICS_FIX "/usr/lib/libhapticsfix.dylib"
// The Settings follow-up-group hider. Rides the same dlopen route; it swizzles
// (Preferences' classes are in the shared cache, so interposing would not reach
// them) and hides the CoreFollowUp suggestion/upsell groups. See
// PrefsFix/libprefsfix.m.
#define VP_PREFS_FIX "/usr/lib/libprefsfix.dylib"
// The sign-in suppressor. Loaded into every app (not daemons) and swizzles the
// in-process Apple-ID / iCloud / store sign-in presentation controllers so no
// app can present a sign-in sheet. Self-gates on each class being present.
// See SignInFix/libsigninfix.m.
#define VP_SIGNIN_FIX "/usr/lib/libsigninfix.dylib"

// The one UIKit process measured creating a CHHapticEngine without first
// asking CoreHaptics whether the hardware exists. Suffix-matched, like the
// MIS targets, so it holds however launchd names the binary.
static int vpIsSpringBoard(const char *path) {
    return vpPathHasSuffix(path, "/SpringBoard.app/SpringBoard");
}

// Settings. Suffix-matched like the other targets.
static int vpIsPreferences(const char *path) {
    return vpPathHasSuffix(path, "/Preferences.app/Preferences");
}

// A missing library is expected and stays quiet; anything else is logged.
static void vpLoadLibrary(const char *kind, const char *library) {
    if (access(library, R_OK) != 0) {
        int accessError = errno;
        if (accessError == ENOENT)
            return;
        int fd = vpOpenLog("vphone-systemhook.log");
        if (fd >= 0) {
            dprintf(fd, "pid=%d %s=%s access_errno=%d\n", getpid(), kind, library, accessError);
            close(fd);
        }
        return;
    }
    void *loaded = dlopen(library, RTLD_NOW | RTLD_LOCAL);
    int fd = vpOpenLog("vphone-systemhook.log");
    if (fd >= 0) {
        const char *error = loaded ? NULL : dlerror();
        dprintf(fd, "pid=%d %s=%s result=%s\n", getpid(), kind, library,
                loaded ? "loaded" : error ? error : "unknown error");
        close(fd);
    }
}

// xpcproxy needs this bridge because launchd only spawns the proxy, not its target.
__attribute__((constructor)) static void vpLogProcess(void) {
    vpInstallSurfaceAdapter();
    vpInstallIOS18GPUTransport();
    // Request cross-boot reuse at constructor entry: libCoreFSCache normally
    // invalidates Metal caches when the boot session changes. Preserve an
    // explicit environment setting. See Research/Guest/gpu_acceleration.md.
    if (access("/usr/lib/vphone-metal-cache-reuse", F_OK) == 0) {
        setenv("FS_CACHE_REUSE_ON_REBOOT", "1", 0);
    }
    // The paravirtual GPU does not preserve IOSurface attachment yInvert.
    // Select AppleMetalGLRenderer's native viewport/scissor alternative before
    // an EAGLContext exists, preserving an explicit application setting.
    if (access("/usr/lib/vphone-gles-upper-left", F_OK) == 0) {
        setenv("AGX_GL_VIEWPORT_INVERT_CONFIG", "UPPER_LEFT", 0);
    }

    char path[PATH_MAX];
    uint32_t length = sizeof(path);
    if (_NSGetExecutablePath(path, &length) != 0)
        return;
    vpInXPCProxy = strcmp(path, "/usr/libexec/xpcproxy") == 0;
    vpInBootstrap = vpIsBootstrapPath(path, getenv("VPHONE_JB_ROOT"));

    // Every process loads this hook; only the ones it acts on are logged.
    int fd = vpInXPCProxy || vpInBootstrap || vpIsAppPath(path) || vpIsCameraDaemon(path) || vpIsMotionDaemon(path)
                 ? vpOpenLog("vphone-systemhook.log")
                 : -1;
    if (fd >= 0) {
        char **arguments = *_NSGetArgv();
        dprintf(fd, "pid=%d path=%s label=%s root=%s\n", getpid(), path,
                vpInXPCProxy && arguments && arguments[1] ? arguments[1] : "-",
                getenv("VPHONE_JB_ROOT") ? getenv("VPHONE_JB_ROOT") : "<absent>");
        close(fd);
    }

    if (vpInXPCProxy || getpid() == 1 || vpInjectionDisabled(*_NSGetEnviron()))
        return;
    const char *name = strrchr(path, '/');
    name = name ? name + 1 : path;
    if (strcmp(name, "vphoned") == 0 || strcmp(name, "logd") == 0 ||
        strcmp(name, "notifyd") == 0 || strcmp(name, "usermanagerd") == 0)
        return;
    if (vpIsCameraDaemon(path)) {
        vpLoadLibrary("camera-hook", VP_CAMERA_DAEMON_HOOK);
        return;
    }
    if (vpIsMotionDaemon(path)) {
        vpLoadLibrary("gyroscope-hook", VP_GYROSCOPE_HOOK);
        vpLoadLibrary("accelerometer-hook", VP_ACCELEROMETER_HOOK);
        vpLoadLibrary("hinge-hook", VP_HINGE_HOOK);
        vpLoadLibrary("fold-display", VP_FOLD_DISPLAY);
        return;
    }
    // SpringBoard needs the haptics swizzle before UIKit first asks for an
    // engine, even though attitude simulation excludes this system UI app.
    if (vpIsSpringBoard(path)) {
        vpLoadLibrary("haptics-fix", VP_HAPTICS_FIX);
        vpLoadLibrary("accelerometer-hook", VP_ACCELEROMETER_HOOK);
        // Inert without the foldable product identity; with it, the guard
        // keeps the secure-indicator raise from crash-looping SpringBoard.
        vpLoadLibrary("fold-guard", VP_FOLD_GUARD);
        vpLoadLibrary("fold-display", VP_FOLD_DISPLAY);
    }
    // Loaded before the app gate too: the swizzle must be in place before
    // Settings builds its follow-up section.
    if (vpIsPreferences(path))
        vpLoadLibrary("prefs-fix", VP_PREFS_FIX);
    if (!vpInBootstrap && !vpIsAppPath(path))
        return;
    // Every app gets the sign-in suppressor; it self-gates on the sign-in
    // presentation classes being present (daemons are excluded by the app gate
    // above, so background AuthKit auth is untouched).
    if (vpIsAppPath(path))
        vpLoadLibrary("signin-fix", VP_SIGNIN_FIX);
    if (vpIsAppPath(path) && vpAttitudeAllowsProcess(path))
        vpLoadLibrary("attitude-hook", VP_ATTITUDE_HOOK);
    if (vpIsAppPath(path) && dlopen(VP_AVFOUNDATION, RTLD_LAZY | RTLD_NOLOAD))
        vpLoadLibrary("camera-hook", VP_CAMERA_APP_HOOK);
    const char *root = getenv("VPHONE_JB_ROOT");
    if (!root || !*root)
        root = "/var/jb";
    char loader[PATH_MAX];
    int used = snprintf(loader, sizeof(loader), "%s/usr/lib/TweakLoader.dylib", root);
    if (used <= 0 || (size_t)used >= sizeof(loader))
        return;
    // dlopen is not a spawn: link TweakLoader's dependency directories, such
    // as usr/lib/ellekit, before dyld looks for them.
    vpEnsureRootHideLoaderLink(loader, root);
    vpLoadLibrary("tweakloader", loader);
}

int vphone_systemhook_version(void) { return 1; }

__attribute__((used, section("__DATA,__interpose"))) static const struct {
    const void *replacement;
    const void *replacee;
} vpInterpose[] = {
    {(const void *)vpSpawnP, (const void *)posix_spawnp},
    {(const void *)vpSpawn, (const void *)posix_spawn},
    {(const void *)vpSetSpawnExceptionPortsPreservingX1, (const void *)posix_spawnattr_setexceptionports_np},
    {(const void *)vpExecve, (const void *)execve},
};
