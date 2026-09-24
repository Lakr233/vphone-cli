#include "../Shared/InjectionEnvironment.h"
#include <crt_externs.h>
#include <fcntl.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <spawn.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

static int vpInXPCProxy;

static void vpLogSpawn(const char *path, const char *decision) {
    int fd = open("/var/mobile/Library/Caches/vphone-systemhook-spawn.log",
                  O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0644);
    if (fd < 0) return;
    dprintf(fd, "pid=%d path=%s decision=%s\n", getpid(), path ? path : "<null>", decision);
    close(fd);
}

static int vpSpawnP(pid_t *restrict pid, const char *restrict path, const posix_spawn_file_actions_t *restrict actions,
                    const posix_spawnattr_t *restrict attributes, char *const argv[restrict],
                    char *const envp[restrict]) {
    if (!vpInXPCProxy)
        return posix_spawnp(pid, path, actions, attributes, argv, envp);
    if (!path || vpInjectionDisabled(envp)) {
        vpLogSpawn(path, "disabled");
        return posix_spawnp(pid, path, actions, attributes, argv, envp);
    }
    VPInjectionEnvironment injected = vpInsertHook(envp);
    vpLogSpawn(path, injected.values ? "inserted" : "unchanged");
    int status = posix_spawnp(pid, path, actions, attributes, argv, injected.values ? injected.values : envp);
    vpFreeEnvironment(&injected);
    return status;
}

// xpcproxy needs this bridge because launchd only spawns the proxy, not its target.
__attribute__((constructor)) static void vpLogProcess(void) {
    char path[PATH_MAX];
    uint32_t length = sizeof(path);
    if (_NSGetExecutablePath(path, &length) != 0)
        return;
    vpInXPCProxy = strcmp(path, "/usr/libexec/xpcproxy") == 0;

    int fd = open("/var/mobile/Library/Caches/vphone-systemhook.log", O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0644);
    if (fd < 0)
        return;
    char **arguments = *_NSGetArgv();
    dprintf(fd, "pid=%d path=%s label=%s\n", getpid(), path,
            vpInXPCProxy && arguments && arguments[1] ? arguments[1] : "-");
    close(fd);
}

int vphone_systemhook_version(void) { return 1; }

__attribute__((used, section("__DATA,__interpose"))) static const struct {
    const void *replacement;
    const void *replacee;
} vpInterpose[] = {
    {(const void *)vpSpawnP, (const void *)posix_spawnp},
};
