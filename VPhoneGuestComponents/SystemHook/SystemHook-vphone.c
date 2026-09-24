#include <fcntl.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <stdio.h>
#include <unistd.h>

// Diagnostic only: confirm which processes actually load SystemHook.
__attribute__((constructor))
static void vpLogProcess(void) {
    char path[PATH_MAX];
    uint32_t length = sizeof(path);
    if (_NSGetExecutablePath(path, &length) != 0) return;

    int fd = open("/var/mobile/Library/Caches/vphone-systemhook.log",
                  O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0644);
    if (fd < 0) return;
    dprintf(fd, "pid=%d path=%s\n", getpid(), path);
    close(fd);
}

int vphone_systemhook_version(void) { return 1; }
