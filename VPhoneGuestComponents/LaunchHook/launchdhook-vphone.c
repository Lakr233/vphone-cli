#include "../Shared/InjectionEnvironment.h"
#include "../Shared/JetsamLimits.h"
#include "../Shared/RootHideDylibSignature.h"
#include "../Shared/RootHideLoaderLinks.h"
#include "../Shared/VPhoneX1Spawn.h"
#include "VPhoneX1Exception.h"
#include <fcntl.h>
#include <stdint.h>
#include <limits.h>
#include <spawn.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

// vphoned installs RootHide under this one name (`roothideRoot`).
#define VP_ROOTHIDE_ROOT "/private/var/containers/Bundle/Application/.jbroot-000114514191980C"

static char vpBootRoot[PATH_MAX];

static void vpLogInjection(const char *event, const char *path, int status) {
    int fd = open("/var/mobile/Library/Caches/vphone-launchdhook-injection.log",
                  O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0644);
    if (fd < 0)
        return;
    dprintf(fd, "%s path=%s status=%d\n", event, path ? path : "<null>", status);
    close(fd);
}

static void vpLogSpawn(const char *event, const char *path, pid_t child, int status) {
    int fd = open("/var/mobile/Library/Caches/vphone-launchdhook-spawn.log",
                  O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0644);
    if (fd < 0)
        return;
    dprintf(fd, "event=%s child=%d path=%s status=%d\n", event, child,
            path ? path : "<null>", status);
    close(fd);
}

static int vpIsAppProgram(const char *path) {
    if (!path || !strstr(path, ".app/"))
        return 0;
    return strncmp(path, "/Applications/", sizeof("/Applications/") - 1) == 0 ||
           strncmp(path, "/var/containers/Bundle/Application/",
                   sizeof("/var/containers/Bundle/Application/") - 1) == 0 ||
           strncmp(path, "/private/var/containers/Bundle/Application/",
                   sizeof("/private/var/containers/Bundle/Application/") - 1) == 0;
}

static int vpIsBootstrapProgram(const char *path) {
    if (!path)
        return 0;
    if (strncmp(path, "/var/jb/", 8) == 0)
        return 1;
    const char *root = vpBootRoot;
    if (strncmp(root, "/private/var/", 13) == 0 && strncmp(path, "/var/", 5) == 0) {
        root += 8; // /private/var/... and /var/... name the same directory.
    }
    size_t length = strlen(root);
    return length && strncmp(path, root, length) == 0 && path[length] == '/';
}

// Neither bootstrap exists on the first boot, and one may be installed while
// launchd runs, so spawns look again until a root appears.
static int vpFindJBRoot(char root[PATH_MAX]) {
    static const char *const roots[] = {"/var/jb", VP_ROOTHIDE_ROOT};
    for (size_t index = 0; index < sizeof(roots) / sizeof(roots[0]); index++) {
        char library[PATH_MAX];
        struct stat info;
        snprintf(library, sizeof(library), "%s/usr/lib", roots[index]);
        if (stat(library, &info) == 0 && S_ISDIR(info.st_mode) && realpath(roots[index], root))
            return 1;
    }
    root[0] = '\0';
    return 0;
}

static int vpSpawnWith(VPX1SpawnFunction spawn, pid_t *restrict pid, const char *restrict path,
                       const posix_spawn_file_actions_t *restrict actions, const posix_spawnattr_t *restrict attributes,
                       char *const argv[restrict], char *const envp[restrict]) {
    if (!vpBootRoot[0] && vpFindJBRoot(vpBootRoot))
        vpLogInjection("bootstrap-root", vpBootRoot, 0);
    int bootstrapProgram = vpIsBootstrapProgram(path);
    int appProgram = vpIsAppProgram(path);
    if (bootstrapProgram || appProgram) {
        int linkStatus = vpEnsureRootHideLoaderLink(path, vpBootRoot);
        if (linkStatus || (path && strstr(path, "/.jbroot-")))
            vpLogInjection("loader-link", path, linkStatus);
    }
    if (vpBootRoot[0] && (bootstrapProgram || appProgram || (path && strcmp(path, "/usr/libexec/xpcproxy") == 0)))
        vpEnsureRootHideTweakSignatures(vpBootRoot);
    // Every process chain-loads SystemHook, including one started with tweaks
    // disabled: SystemHook itself honors DISABLE_TWEAKS and safe mode by not
    // loading ElleKit. Only launchd re-executing itself is left alone.
    if (!path || strcmp(path, "/sbin/launchd") == 0)
        return spawn(pid, path, actions, attributes, argv, envp);
    // launchd starts some jobs itself rather than through xpcproxy — SpringBoard
    // is one — so the MIS, battery health, DeviceHub and device name hooks
    // have to be decided here as well as in SystemHook.
    const VPInsertedLibraries libraries = vpInsertedLibrariesFor(path);
    VPInjectionEnvironment injected = vpInsertHooksFor(envp, vpBootRoot, &libraries);
    VPJetsamLimits limits = vpRaiseJetsamLimits(vpBootRoot, path, attributes, envp);
    int status = vpSpawnWithInheritedX1Port(
        spawn,
        pid,
        path,
        actions,
        attributes,
        argv,
        injected.values ? injected.values : envp
    );
    vpRestoreJetsamLimits(&limits);
    if (bootstrapProgram || appProgram || libraries.count || strcmp(path, "/usr/libexec/xpcproxy") == 0) {
        char event[128];
        if (!injected.values) {
            snprintf(event, sizeof(event), "unchanged");
        } else if (libraries.count) {
            char names[96];
            vpDescribeInsertedLibraries(&libraries, names, sizeof(names));
            snprintf(event, sizeof(event), "inserted%s", names);
        } else {
            snprintf(event, sizeof(event), "%s",
                     vpInjectionDisabled(envp) ? "inserted-tweaks-disabled" : "inserted");
        }
        vpLogInjection(event, path, status);
        vpLogSpawn(event, path, status == 0 && pid ? *pid : -1, status);
    }
    vpFreeEnvironment(&injected);
    return status;
}

static int vpSpawn(pid_t *restrict pid, const char *restrict path, const posix_spawn_file_actions_t *restrict actions,
                   const posix_spawnattr_t *restrict attributes, char *const argv[restrict],
                   char *const envp[restrict]) {
    return vpSpawnWith(posix_spawn, pid, path, actions, attributes, argv, envp);
}

// launchd starts jobs through posix_spawnp: xpcproxy, and each bootstrap
// LaunchDaemon such as sshd or ighostvtd when it elides the proxy. Without
// this none of them gets SystemHook.
static int vpSpawnP(pid_t *restrict pid, const char *restrict path, const posix_spawn_file_actions_t *restrict actions,
                    const posix_spawnattr_t *restrict attributes, char *const argv[restrict],
                    char *const envp[restrict]) {
    return vpSpawnWith(posix_spawnp, pid, path, actions, attributes, argv, envp);
}

// The bootstrap's LaunchDaemons are not imported here: vphoned loads them
// after boot under their own paths, as RootHide's jbctl does.
extern int memorystatus_control(uint32_t, int32_t, uint32_t, void *, size_t);

enum { VPSetJetsamHighWaterMark = 5, VPSetJetsamTaskLimit = 6 };

static int vpMemoryStatus(uint32_t command, int32_t pid, uint32_t flags, void *buffer, size_t size) {
    if (getpid() == 1 && command == VPSetJetsamTaskLimit && (pid == 1 || pid == 0)) {
        return 0;
    }
    return memorystatus_control(command, pid, flags, buffer, size);
}

// Control Center's volume slider on an iOS 27 guest looks up
// `com.apple.mediaexperience.avvolumeclient.xpc`. launchd (the bootstrap
// server) asks the sandbox whether the requesting client — SpringBoard — may
// look the name up, through sandbox_check_by_audit_token(client_token,
// "mach-lookup", SANDBOX_FILTER_GLOBAL_NAME, name). The service is new in
// iOS 27; SpringBoard's platform profile, baked into the cloudOS 26.4 kernel
// the guest boots, predates it and has no rule for it, so the check is denied
// (`Protobox: SpringBoard deny(1) mach-lookup …avvolumeclient.xpc`) and the
// slider stays inert. The profile cannot be recompiled and the exception
// entitlement does not reach a platform profile; see
// Research/Guest/ios27_cc_volume_sandbox.md.
//
// This allows that one lookup of that one name and forwards every other check
// untouched. launchd's calls to this function all pass zero or one variadic
// argument (audited across all 21 call sites in the guest's /sbin/launchd), so
// reading one and forwarding it reconstructs each call faithfully; the name
// filters (2, 3) always carry a valid name string, which is the only case the
// string compare runs in.
#define VP_AVVOLUME_SERVICE "com.apple.mediaexperience.avvolumeclient.xpc"

enum {
    VPSandboxFilterGlobalName = 2,
    VPSandboxFilterLocalName = 3,
};

typedef struct {
    unsigned int val[8];
} vp_audit_token_t;

extern int sandbox_check_by_audit_token(vp_audit_token_t token, const char *operation,
                                        unsigned int filter, ...);

static void vpLogVolumeAllow(const char *name) {
    int fd = open("/var/mobile/Library/Caches/vphone-launchdhook-sandbox.log",
                  O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0644);
    if (fd < 0)
        return;
    dprintf(fd, "allow mach-lookup %s\n", name ? name : "<null>");
    close(fd);
}

#include "InstallCoordinationPersona.h"

static int vpSandboxCheckByAuditToken(vp_audit_token_t token, const char *operation,
                                      unsigned int filter, ...) {
    va_list arguments;
    va_start(arguments, filter);
    const void *first = va_arg(arguments, const void *);
    va_end(arguments);
    // Only the name filters are read as a string; everything else forwards the
    // bits untouched without dereferencing them.
    if (operation && (filter == VPSandboxFilterGlobalName || filter == VPSandboxFilterLocalName) &&
        first && strcmp(operation, "mach-lookup") == 0 &&
        strcmp((const char *)first, VP_AVVOLUME_SERVICE) == 0) {
        vpLogVolumeAllow((const char *)first);
        return 0;
    }
    if (vpInstallProxyPersonaAllowed(token, operation, filter, first)) {
        vpLogVolumeAllow((const char *)first);
        return 0;
    }
    return sandbox_check_by_audit_token(token, operation, filter, first);
}

__attribute__((constructor)) static void vpLaunchHookInit(void) {
    vp_x1_exception_install();
    if (getpid() != 1)
        return;
    // The firmware panic-guard patch does not remove a limit already on PID 1.
    memorystatus_control(VPSetJetsamTaskLimit, 1, (uint32_t)-1, NULL, 0);
    memorystatus_control(VPSetJetsamHighWaterMark, 1, (uint32_t)-1, NULL, 0);
}

// This image is loaded by launchd's LC_LOAD_WEAK_DYLIB. Interposing spawn here
// keeps the injection chain available before ElleKit is installed. SystemHook
// owns xpcproxy's exec and loads ElleKit's TweakLoader when it appears.
__attribute__((used, section("__DATA,__interpose"))) static const struct {
    const void *replacement;
    const void *replacee;
} vpInterpose[] = {
    {(const void *)vpSpawn, (const void *)posix_spawn},
    {(const void *)vpSpawnP, (const void *)posix_spawnp},
    {(const void *)vpSetSpawnExceptionPortsPreservingX1, (const void *)posix_spawnattr_setexceptionports_np},
    {(const void *)vpMemoryStatus, (const void *)memorystatus_control},
    {(const void *)vpSandboxCheckByAuditToken, (const void *)sandbox_check_by_audit_token},
};
