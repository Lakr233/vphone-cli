#include "../Shared/InjectionEnvironment.h"
#include "../Shared/RootHideLoaderLinks.h"
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
#include <unistd.h>

static int vpInXPCProxy;
static int vpInBootstrap;

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

static int vpIsInjectionTarget(const char *path) {
    if (!path)
        return 0;
    const char *root = getenv("VPHONE_JB_ROOT");
    return vpIsBootstrapPath(path, root) || vpIsAppPath(path) || vpIsCameraDaemon(path) ||
           (vpInBootstrap && path[0] != '/');
}

static int vpOpenLog(const char *name) {
    char path[PATH_MAX];
    int used = snprintf(path, sizeof(path), "/var/mobile/Library/Caches/%s", name);
    int fd = used > 0 && (size_t)used < sizeof(path)
                 ? open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0644)
                 : -1;
    if (fd >= 0)
        return fd;
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

static int vpSpawnP(pid_t *restrict pid, const char *restrict path, const posix_spawn_file_actions_t *restrict actions,
                    const posix_spawnattr_t *restrict attributes, char *const argv[restrict],
                    char *const envp[restrict]) {
    if (!vpIsInjectionTarget(path))
        return posix_spawnp(pid, path, actions, attributes, argv, envp);
    vpPrepareLoaderLink(path);
    if (vpInjectionDisabled(envp)) {
        vpLogSpawn(path, "disabled");
        return posix_spawnp(pid, path, actions, attributes, argv, envp);
    }
    VPInjectionEnvironment injected = vpInsertHook(envp, getenv("VPHONE_JB_ROOT"));
    vpLogSpawn(path, injected.values ? "inserted" : "unchanged");
    int status = posix_spawnp(pid, path, actions, attributes, argv, injected.values ? injected.values : envp);
    vpFreeEnvironment(&injected);
    return status;
}

static int vpSpawn(pid_t *restrict pid, const char *restrict path, const posix_spawn_file_actions_t *restrict actions,
                   const posix_spawnattr_t *restrict attributes, char *const argv[restrict],
                   char *const envp[restrict]) {
    if (!vpIsInjectionTarget(path))
        return posix_spawn(pid, path, actions, attributes, argv, envp);
    vpPrepareLoaderLink(path);
    if (vpInjectionDisabled(envp)) {
        vpLogSpawn(path, "disabled");
        return posix_spawn(pid, path, actions, attributes, argv, envp);
    }
    VPInjectionEnvironment injected = vpInsertHook(envp, getenv("VPHONE_JB_ROOT"));
    vpLogSpawn(path, injected.values ? "inserted" : "unchanged");
    int status = posix_spawn(pid, path, actions, attributes, argv, injected.values ? injected.values : envp);
    vpFreeEnvironment(&injected);
    return status;
}

static int vpExecve(const char *path, char *const argv[], char *const envp[]) {
    if (!vpIsInjectionTarget(path))
        return execve(path, argv, envp);
    vpPrepareLoaderLink(path);
    if (vpInjectionDisabled(envp)) {
        vpLogSpawn(path, "exec-disabled");
        return execve(path, argv, envp);
    }
    VPInjectionEnvironment injected = vpInsertHook(envp, getenv("VPHONE_JB_ROOT"));
    vpLogSpawn(path, injected.values ? "exec-inserted" : "exec-unchanged");
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
#define VP_AVFOUNDATION "/System/Library/Frameworks/AVFoundation.framework/AVFoundation"

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
    char path[PATH_MAX];
    uint32_t length = sizeof(path);
    if (_NSGetExecutablePath(path, &length) != 0)
        return;
    vpInXPCProxy = strcmp(path, "/usr/libexec/xpcproxy") == 0;
    vpInBootstrap = vpIsBootstrapPath(path, getenv("VPHONE_JB_ROOT"));

    int fd = vpOpenLog("vphone-systemhook.log");
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
    if (!vpInBootstrap && !vpIsAppPath(path))
        return;
    if (vpIsAppPath(path) && dlopen(VP_AVFOUNDATION, RTLD_LAZY | RTLD_NOLOAD))
        vpLoadLibrary("camera-hook", VP_CAMERA_APP_HOOK);
    const char *root = getenv("VPHONE_JB_ROOT");
    if (!root || !*root)
        root = "/var/jb";
    char loader[PATH_MAX];
    int used = snprintf(loader, sizeof(loader), "%s/usr/lib/TweakLoader.dylib", root);
    if (used <= 0 || (size_t)used >= sizeof(loader))
        return;
    vpLoadLibrary("tweakloader", loader);
}

int vphone_systemhook_version(void) { return 1; }

__attribute__((used, section("__DATA,__interpose"))) static const struct {
    const void *replacement;
    const void *replacee;
} vpInterpose[] = {
    {(const void *)vpSpawnP, (const void *)posix_spawnp},
    {(const void *)vpSpawn, (const void *)posix_spawn},
    {(const void *)vpExecve, (const void *)execve},
};
